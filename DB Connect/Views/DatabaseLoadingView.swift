import SwiftUI

struct DatabaseLoadingIndicator: View {
    var size: CGFloat = 20

    var body: some View {
        HStack{
           
            Image("database")
                .symbolRenderingMode(.multicolor)
                .font(.system(size: size))
                .symbolEffect(.bounce, isActive: true)
                .accessibilityHidden(true)
           
            
        }
    }
}
#Preview {
    DatabaseLoadingIndicator()
}


struct DatabaseLoadingView: View {
    let title: String?
    var size: CGFloat = 28
    var spacing: CGFloat = 12

    init(_ title: String? = nil, size: CGFloat = 28, spacing: CGFloat = 12) {
        self.title = title
        self.size = size
        self.spacing = spacing
    }

    var body: some View {
        VStack(spacing: spacing) {
            DatabaseLoadingIndicator(size: size)
            if let title {
                Text(title)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title ?? "Loading")
    }
}
