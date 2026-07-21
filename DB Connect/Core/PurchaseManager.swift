import Observation
import StoreKit

/// Owns the App Store entitlement that removes the one-connection limit.
///
/// The product must be configured as a non-consumable in App Store Connect. StoreKit keeps that
/// purchase restorable across the user's devices; no separate receipt flag is persisted locally.
@MainActor
@Observable
final class PurchaseManager {
    static let unlimitedConnectionsProductID = "de.holgerkrupp.DBConnect.pro"

    /// Matches the development escape hatch used by SymbolBuilder and IconBuilder. Shipping
    /// builds never set this environment variable.
    static let paywallDisabled =
        ProcessInfo.processInfo.environment["DBCONNECT_NO_PAYWALL"] == "1"

    private(set) var product: Product?
    private(set) var isUnlocked = false
    private(set) var isLoading = true
    private(set) var isPurchasing = false
    private(set) var errorMessage: String?

    private var transactionListener: Task<Void, Never>?

    init() {
        guard !Self.paywallDisabled else {
            isUnlocked = true
            isLoading = false
            return
        }

        transactionListener = Task { [weak self] in
            for await result in Transaction.updates {
                guard let self else { return }

                if case .verified(let transaction) = result,
                    transaction.productID == Self.unlimitedConnectionsProductID
                {
                    await transaction.finish()
                }
                await self.refreshEntitlement()
            }
        }

        Task { await prepare() }
    }

    var priceText: String? { product?.displayPrice }

    /// Loads both sides independently: a missing network product must not hide a locally cached
    /// entitlement from somebody who already paid.
    func prepare() async {
        isLoading = true
        errorMessage = nil

        async let productLoad: Void = loadProduct()
        async let entitlementLoad: Void = refreshEntitlement()
        _ = await (productLoad, entitlementLoad)

        isLoading = false
    }

    @discardableResult
    func purchase() async -> Bool {
        if isUnlocked { return true }

        errorMessage = nil
        if product == nil {
            await loadProduct()
        }
        guard let product else {
            errorMessage = "The purchase is temporarily unavailable. Please try again later."
            return false
        }

        isPurchasing = true
        defer { isPurchasing = false }

        do {
            switch try await product.purchase() {
            case .success(let verification):
                let transaction = try verified(verification)
                guard transaction.productID == Self.unlimitedConnectionsProductID else {
                    throw PurchaseError.unexpectedProduct
                }
                await transaction.finish()
                await refreshEntitlement()
                return isUnlocked
            case .pending:
                errorMessage =
                    "The purchase is pending approval. Unlimited connections will unlock automatically when it completes."
                return false
            case .userCancelled:
                return false
            @unknown default:
                return false
            }
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func restore() async -> Bool {
        errorMessage = nil
        isPurchasing = true
        defer { isPurchasing = false }

        do {
            try await AppStore.sync()
            await refreshEntitlement()
            if !isUnlocked {
                errorMessage =
                    "No previous Unlimited Connections purchase was found for this Apple Account."
            }
            return isUnlocked
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func loadProduct() async {
        do {
            product = try await Product.products(
                for: [Self.unlimitedConnectionsProductID]
            ).first
        } catch {
            // An existing entitlement can still be read from the signed receipt while offline.
            product = nil
            if !isUnlocked { errorMessage = error.localizedDescription }
        }
    }

    private func refreshEntitlement() async {
        var ownsProduct = false

        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result,
                transaction.productID == Self.unlimitedConnectionsProductID,
                transaction.revocationDate == nil
            else { continue }
            ownsProduct = true
            break
        }

        isUnlocked = ownsProduct
    }

    private func verified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .verified(let value): value
        case .unverified: throw PurchaseError.failedVerification
        }
    }
}

private enum PurchaseError: LocalizedError {
    case failedVerification
    case unexpectedProduct

    var errorDescription: String? {
        switch self {
        case .failedVerification:
            "The App Store could not verify this purchase."
        case .unexpectedProduct:
            "The App Store returned an unexpected purchase."
        }
    }
}
