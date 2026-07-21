import SwiftUI

/// Shared layout for controls hosted by `safeAreaBar` at the bottom of a column.
///
/// `safeAreaBar` lets SwiftUI supply the platform's scroll-edge treatment and Liquid Glass
/// behavior. This modifier intentionally adds no custom background or separator: those would
/// cover the system material and opt the app out of accessibility adaptations such as Reduce
/// Transparency.
enum BottomBarMetrics {
    static let minimumHeight = 44.0
    static let horizontalPadding = 12.0
}

private struct BottomBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .controlSize(.regular)
            .padding(.horizontal, BottomBarMetrics.horizontalPadding)
            .frame(minHeight: BottomBarMetrics.minimumHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// Align this view with the other bottom safe-area controls in the app.
    func bottomBar() -> some View {
        modifier(BottomBarModifier())
    }
}
