import SwiftUI

/// Page navigation for a table: position, size, and a jump-to-row field.
struct PagerView: View {
    let offset: Int
    let pageSize: Int
    let loadedRows: Int
    /// Nil when the driver could not count — the UI then avoids implying a known total.
    let totalRows: Int?
    /// Supplied by the paged query itself, so Next still works when COUNT is unavailable.
    let hasMore: Bool
    let isLoading: Bool

    let onJump: (Int) -> Void
    let onChangePageSize: (Int) -> Void

    @State private var jumpText = ""
    @State private var showsJumpPrompt = false
    @FocusState private var jumpFocused: Bool
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private static let pageSizes = [50, 100, 200, 500, 1000]

    private var isLastPage: Bool {
        if let totalRows { return offset + pageSize >= totalRows }
        return !hasMore
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                compactPager
            } else {
                HStack(spacing: 10) {
                    pageButtons
                    pageStatus
                    Spacer()
                    jumpControls
                }
            }
        }
        .bottomBar()
        .alert("Go to Row", isPresented: $showsJumpPrompt) {
            TextField("Row number", text: $jumpText)
            #if os(iOS)
                .keyboardType(.numberPad)
            #endif
            Button("Cancel", role: .cancel) { jumpText = "" }
            Button("Go", action: jump)
                .disabled(Int(jumpText.trimmingCharacters(in: .whitespaces)) == nil)
        } message: {
            Text("Enter a row number to open the page containing it.")
        }
    }

    /// Phone paging stays on one system bottom-bar row. The less frequent commands live in a
    /// menu instead of forcing four tiny arrows and a text field onto the screen at once.
    private var compactPager: some View {
        HStack(spacing: 8) {
            Button("Previous page", systemImage: "chevron.left") {
                onJump(max(0, offset - pageSize))
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .disabled(offset == 0)

            pageStatus
                .frame(minWidth: 76)

            Button("Next page", systemImage: "chevron.right") {
                onJump(offset + pageSize)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .disabled(isLastPage)

            Spacer(minLength: 0)

            compactPageMenu
                .buttonStyle(.glass)
        }
    }

    private var compactPageMenu: some View {
        Menu {
            Button("Go to Row…", systemImage: "number") {
                jumpText = ""
                showsJumpPrompt = true
            }

            Divider()

            Button("First Page", systemImage: "chevron.left.to.line") {
                onJump(0)
            }
            .disabled(offset == 0)

            Button("Last Page", systemImage: "chevron.right.to.line") {
                guard let totalRows, totalRows > 0 else { return }
                onJump(max(0, ((totalRows - 1) / pageSize) * pageSize))
            }
            .disabled(totalRows == nil || isLastPage)

            Divider()

            Picker("Rows per Page", selection: Binding(
                get: { pageSize },
                set: { onChangePageSize($0) }
            )) {
                ForEach(Self.pageSizes, id: \.self) { size in
                    Text("\(size) rows").tag(size)
                }
            }
        } label: {
            Text(pageSize.formatted())
                .monospacedDigit()
        }
        .accessibilityLabel("\(pageSize) rows per page")
    }

    private var pageButtons: some View {
        ControlGroup {
            Button("First page", systemImage: "chevron.left.to.line") {
                onJump(0)
            }
            .labelStyle(.iconOnly)
            .disabled(offset == 0)
            .help("First page")

            Button("Previous page", systemImage: "chevron.left") {
                onJump(max(0, offset - pageSize))
            }
            .labelStyle(.iconOnly)
            .disabled(offset == 0)
            .help("Previous page")

            Button("Next page", systemImage: "chevron.right") {
                onJump(offset + pageSize)
            }
            .labelStyle(.iconOnly)
            .disabled(isLastPage)
            .help("Next page")

            Button("Last page", systemImage: "chevron.right.to.line") {
                // Land on the final whole page rather than a partial one past the end.
                guard let totalRows, totalRows > 0 else { return }
                onJump(max(0, ((totalRows - 1) / pageSize) * pageSize))
            }
            .labelStyle(.iconOnly)
            .disabled(totalRows == nil || isLastPage)
            .help(totalRows == nil ? "Unknown total" : "Last page")
        }
    }

    private var pageStatus: some View {
        HStack(spacing: 10) {
            Text(positionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if isLoading {
                DatabaseLoadingIndicator(size: 11)
            }
        }
    }

    private var jumpControls: some View {
        HStack(spacing: 8) {
            TextField("Go to row", text: $jumpText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 100)
                .focused($jumpFocused)
                .onSubmit(jump)
            #if os(iOS)
                .keyboardType(.numberPad)
            #endif

            Picker("Page size", selection: Binding(
                get: { pageSize },
                set: { onChangePageSize($0) }
            )) {
                ForEach(Self.pageSizes, id: \.self) { size in
                    Text("\(size) rows").tag(size)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 110)
        }
    }

    private var positionText: String {
        guard loadedRows > 0 else {
            return totalRows == 0 ? "No rows" : "—"
        }
        let first = offset + 1
        let last = offset + loadedRows
        if let totalRows {
            return "\(first)–\(last) of \(totalRows.formatted())"
        }
        return "\(first)–\(last)"
    }

    /// Jump to a 1-based row number, snapped to the start of the page containing it.
    private func jump() {
        guard let target = Int(jumpText.trimmingCharacters(in: .whitespaces)), target > 0 else {
            jumpText = ""
            return
        }
        let bounded = totalRows.map { min(target, $0) } ?? target
        onJump(((bounded - 1) / pageSize) * pageSize)
        jumpText = ""
        jumpFocused = false
    }
}
