import SwiftUI

extension Binding {
    /// Drives a presentation from optional model state and clears that state when the system
    /// dismisses the presentation interactively (for example, by swiping down on iPhone).
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        SwiftUI.Binding<Bool>(
            get: { wrappedValue != nil },
            set: { isPresented in
                if !isPresented { wrappedValue = nil }
            }
        )
    }
}
