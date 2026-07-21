import SwiftUI

/// Page navigation for a table: position, size, and a jump-to-row field.
struct PagerView: View {
    let offset: Int
    let pageSize: Int
    let loadedRows: Int
    /// Nil when the driver could not count — the UI then avoids implying a known total.
    let totalRows: Int?
    let isLoading: Bool

    let onJump: (Int) -> Void
    let onChangePageSize: (Int) -> Void

    @State private var jumpText = ""
    @FocusState private var jumpFocused: Bool

    private static let pageSizes = [50, 100, 200, 500, 1000]

    private var isLastPage: Bool {
        if let totalRows { return offset + pageSize >= totalRows }
        return loadedRows < pageSize
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                pageButtons
                pageStatus
                Spacer()
                jumpControls
            }

            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    pageButtons
                    pageStatus
                    Spacer(minLength: 0)
                }
                jumpControls.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .bottomBar()
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

            if isLoading {
                ProgressView().controlSize(.mini)
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
