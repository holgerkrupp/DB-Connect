import AuthenticationServices
import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Native browser authentication for Vault's OIDC auth method. The coordinator is deliberately
/// small: VaultHTTPClient obtains the authorization URL and exchanges the callback, while this
/// type owns ASWebAuthenticationSession, presentation, and immediate Task cancellation.
@MainActor
final class VaultOIDCAuthenticationCoordinator: NSObject, VaultOIDCAuthenticator, ASWebAuthenticationPresentationContextProviding {
    private let api: any VaultOIDCAuthAPI
    private let redirectURI: URL
    private let presentationAnchorProvider: @MainActor () -> ASPresentationAnchor
    private var activeSession: ASWebAuthenticationSession?
    private var activeContinuation: CheckedContinuation<VaultToken, Error>?
    private var activeRequest: VaultOIDCAuthorizationRequest?
    private var wasCancelled = false

    init(
        api: any VaultOIDCAuthAPI,
        redirectURI: URL,
        presentationAnchorProvider: @escaping @MainActor () -> ASPresentationAnchor
    ) throws {
        guard let scheme = redirectURI.scheme, !scheme.isEmpty,
              redirectURI.user == nil, redirectURI.password == nil,
              redirectURI.query == nil, redirectURI.fragment == nil else {
            throw VaultError.invalidConfiguration("OIDC redirect URI must have a scheme and no credentials, query, or fragment.")
        }
        self.api = api
        self.redirectURI = redirectURI
        self.presentationAnchorProvider = presentationAnchorProvider
        super.init()
    }

    /// Starts one browser flow. A second flow is rejected so callback state cannot be mixed
    /// between accounts. Cancelling the caller's task immediately cancels ASWebAuthenticationSession.
    nonisolated func authenticate(configuration: VaultAuthenticationConfiguration) async throws -> VaultToken {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { @MainActor [weak self] in
                    guard let self else {
                        continuation.resume(throwing: VaultError.cancelled)
                        return
                    }
                    self.begin(configuration: configuration, continuation: continuation)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        presentationAnchorProvider()
    }

    private func begin(
        configuration: VaultAuthenticationConfiguration,
        continuation: CheckedContinuation<VaultToken, Error>
    ) {
        guard activeContinuation == nil else {
            continuation.resume(throwing: VaultError.invalidConfiguration("A Vault OIDC sign-in is already in progress."))
            return
        }
        wasCancelled = false
        activeContinuation = continuation
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try Task.checkCancellation()
                let request = try await api.authorizationRequest(
                    configuration: configuration,
                    redirectURI: redirectURI,
                    clientNonce: UUID().uuidString
                )
                guard !wasCancelled else { return }
                activeRequest = request
                guard let callbackScheme = redirectURI.scheme else {
                    throw VaultError.invalidConfiguration("OIDC redirect URI has no callback scheme.")
                }
                let session = ASWebAuthenticationSession(
                    url: request.authorizationURL,
                    callbackURLScheme: callbackScheme
                ) { [weak self] callbackURL, error in
                    Task { @MainActor [weak self] in
                        await self?.finish(configuration: configuration, callbackURL: callbackURL, error: error)
                    }
                }
                session.presentationContextProvider = self
                session.prefersEphemeralWebBrowserSession = true
                activeSession = session
                guard session.start() else {
                    throw VaultError.transport("The system browser could not start the Vault sign-in.")
                }
            } catch is CancellationError {
                finish(with: .failure(VaultError.cancelled))
            } catch {
                finish(with: .failure(error))
            }
        }
    }

    private func finish(
        configuration: VaultAuthenticationConfiguration,
        callbackURL: URL?,
        error: Error?
    ) async {
        if let error {
            if let webError = error as? ASWebAuthenticationSessionError,
               webError.code == .canceledLogin {
                finish(with: .failure(VaultError.cancelled))
            } else {
                finish(with: .failure(VaultError.transport(error.localizedDescription)))
            }
            return
        }
        guard let callbackURL, let request = activeRequest else {
            finish(with: .failure(VaultError.invalidResponse("Vault OIDC did not return a callback.")))
            return
        }
        do {
            let token = try await api.exchangeCallback(
                configuration: configuration,
                request: request,
                callbackURL: callbackURL,
                now: .now
            )
            finish(with: .success(token))
        } catch {
            finish(with: .failure(error))
        }
    }

    private func cancel() {
        wasCancelled = true
        activeSession?.cancel()
        finish(with: .failure(VaultError.cancelled))
    }

    private func finish(with result: Result<VaultToken, Error>) {
        activeSession = nil
        activeRequest = nil
        let continuation = activeContinuation
        activeContinuation = nil
        continuation?.resume(with: result)
    }
}

