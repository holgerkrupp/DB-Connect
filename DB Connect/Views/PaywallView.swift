import SwiftUI

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss

    let purchaseManager: PurchaseManager

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "server.rack")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                    .padding(.top, 28)

                Text("Unlock DB Connect Pro")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)

                Text("Your first connection is free. Add a second server or connection by unlocking Pro.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)

                VStack(alignment: .leading, spacing: 10) {
                    feature(
                        "infinity", "Unlimited connections",
                        "Keep every database and server you use in one place.")
                    feature(
                        "cylinder.split.1x2", "Every database type",
                        "Use SQLite, MySQL, PostgreSQL, and Supabase connections.")
                    feature(
                        "checkmark.icloud", "Available on your devices",
                        "Restore Pro with the same Apple Account.")
                    feature(
                        "creditcard", "One-time purchase",
                        "No subscription. Buy it once and keep it.")
                }
                .frame(maxWidth: 340)

                VStack(alignment: .leading, spacing: 4) {
                    Label("Always free", systemImage: "checkmark.circle")
                        .font(.caption.weight(.medium))
                    Text("Your first connection and all of its database tools remain available without Pro.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: 340, alignment: .leading)

                if let errorMessage = purchaseManager.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 340)
                }

                VStack(spacing: 8) {
                    Button(action: purchase) {
                        Group {
                            if purchaseManager.isPurchasing {
                                DatabaseLoadingIndicator(size: 14)
                            } else {
                                Text(purchaseButtonTitle)
                            }
                        }
                        .frame(maxWidth: 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(purchaseManager.isLoading || purchaseManager.isPurchasing)

                    Button("Restore Purchases", action: restore)
                        #if os(macOS)
                            .buttonStyle(.link)
                        #endif
                        .disabled(purchaseManager.isPurchasing)

                    Button("Not Now") { dismiss() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
                .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
        #if os(macOS)
            .frame(width: 420)
            .frame(minHeight: 610)
        #else
            .padding(.horizontal, 24)
            .frame(maxWidth: 420)
        #endif
        .task {
            if purchaseManager.product == nil && !purchaseManager.isLoading {
                await purchaseManager.prepare()
            }
            closeIfUnlocked()
        }
        .onChange(of: purchaseManager.isUnlocked) { _, _ in closeIfUnlocked() }
    }

    private var purchaseButtonTitle: String {
        if let price = purchaseManager.priceText {
            "Unlock for \(price)"
        } else if purchaseManager.isLoading {
            "Loading…"
        } else {
            "Unlock Unlimited Connections"
        }
    }

    private func purchase() {
        Task {
            if await purchaseManager.purchase() { dismiss() }
        }
    }

    private func restore() {
        Task {
            if await purchaseManager.restore() { dismiss() }
        }
    }

    private func closeIfUnlocked() {
        if purchaseManager.isUnlocked { dismiss() }
    }

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).fontWeight(.medium)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
