import SwiftUI

/// Shared chrome for the status strips that run along the bottom of each column.
///
/// The height is fixed rather than left to fall out of padding. The three bars hold very
/// different things — a label in the sidebar, a button in the table list, a text field and a
/// popup button in the pager — and their intrinsic heights disagree by several points. Sitting
/// side by side across the window, that reads as a misaligned window rather than as three
/// independently sized views, so they are pinned to one number here.
enum BottomBarMetrics {
    static let height = 30.0
    static let horizontalPadding = 10.0
}

private struct BottomBarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            // Small controls so a text field or popup button still fits the fixed height.
            .controlSize(.small)
            .padding(.horizontal, BottomBarMetrics.horizontalPadding)
            .frame(height: BottomBarMetrics.height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
            // Owned by the bar so every column gets the same separator, in the same place.
            .overlay(alignment: .top) { Divider() }
    }
}

extension View {
    /// Style this view as a column's bottom status bar.
    func bottomBar() -> some View {
        modifier(BottomBarModifier())
    }
}
