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
        HStack(spacing: 10) {
            Group {
                Button {
                    onJump(0)
                } label: {
                    Image(systemName: "chevron.left.to.line")
                }
                .disabled(offset == 0)
                .help("First page")

                Button {
                    onJump(max(0, offset - pageSize))
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(offset == 0)
                .help("Previous page")

                Button {
                    onJump(offset + pageSize)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(isLastPage)
                .help("Next page")

                Button {
                    // Land on the final whole page rather than a partial one past the end.
                    guard let totalRows, totalRows > 0 else { return }
                    onJump(max(0, ((totalRows - 1) / pageSize) * pageSize))
                } label: {
                    Image(systemName: "chevron.right.to.line")
                }
                .disabled(totalRows == nil || isLastPage)
                .help(totalRows == nil ? "Unknown total" : "Last page")
            }
            .buttonStyle(.borderless)

            Divider().frame(height: 14)

            Text(positionText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            if isLoading {
                ProgressView().controlSize(.mini)
            }

            Spacer()

            HStack(spacing: 4) {
                Text("Go to row").font(.caption).foregroundStyle(.secondary)
                TextField("", text: $jumpText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .focused($jumpFocused)
                    .onSubmit(jump)
                #if os(iOS)
                    .keyboardType(.numberPad)
                #endif
            }

            Picker("", selection: Binding(
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
        .bottomBar()
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
