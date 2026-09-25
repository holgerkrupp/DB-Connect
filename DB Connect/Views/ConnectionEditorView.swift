import SwiftUI

/// Reusable connection editor surface.
///
/// The editor is intentionally independent of the navigation route that presents it. The
/// existing connection sheet uses this view, while future inspectors or document workflows can
/// embed the same editor without duplicating the connection form. Persistence remains in the
/// sheet's form coordinator so Keychain and SwiftData writes stay in one place.
struct ConnectionEditorView: View {
    let purchaseManager: PurchaseManager
    var existing: Connection?

    var body: some View {
        ConnectionFormView(purchaseManager: purchaseManager, existing: existing)
    }
}
