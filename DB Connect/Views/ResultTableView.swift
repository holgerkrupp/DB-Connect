import SwiftUI

/// A sort descriptor for a result column. The database does the sorting, so this only records
/// which column and direction the header is showing — see `TableBrowserView`, which turns it
/// into an `ORDER BY` and re-queries.
nonisolated struct ColumnSortComparator: Hashable {
    let column: String
    var order: SortOrder = .forward
}

/// Identifies the one result cell that is currently being edited inline.
nonisolated struct EditableCell: Hashable {
    let rowIndex: Int
    let columnName: String
}

/// Spreadsheet-style result table used on every platform and size class.
///
/// It is a hand-built table rather than SwiftUI's `Table` on purpose. `Table` scrolls
/// horizontally on macOS and iPadOS but collapses to a single column at compact iPhone width —
/// so a single `Table`-based view cannot show a multi-column result on a narrow iPhone. This
/// implementation scrolls both axes identically everywhere, which is the behaviour we want.
///
/// Rendering is lazy: a `LazyVStack` inside a bidirectional `ScrollView` only builds the rows
/// on screen. That matters — the AttributeGraph crash that prompted paging came from a
/// *non*-lazy grid materialising every cell, and this must not reintroduce it.
struct ResultTableView: View {
    let columns: [ColumnDescriptor]
    let rows: [[SQLValue]]
    @Binding var sortOrder: [ColumnSortComparator]
    @Binding var columnWidths: [String: CGFloat]
    @Binding var editingCell: EditableCell?
    @Binding var editingText: String
    var rowHeight: CGFloat = 30
    var wrapCells = false
    /// Row indices with uncommitted edits, marked so pending work is never invisible.
    var dirtyRows: Set<Int> = []
    var canEditCell: ((Int, ColumnDescriptor) -> Bool)? = nil
    var onBeginEditingCell: ((EditableCell) -> Void)? = nil
    var onCommitEditingCell: (() -> Void)? = nil
    var onOpenRow: ((Int) -> Void)? = nil

    @FocusState private var focusedCell: EditableCell?
    @State private var resizeStartWidths: [String: CGFloat] = [:]

    private let markerWidth: CGFloat = 22
    private let minColumnWidth: CGFloat = 80
    private let maxColumnWidth: CGFloat = 520

    init(
        columns: [ColumnDescriptor],
        rows: [[SQLValue]],
        sortOrder: Binding<[ColumnSortComparator]>,
        columnWidths: Binding<[String: CGFloat]> = .constant([:]),
        editingCell: Binding<EditableCell?> = .constant(nil),
        editingText: Binding<String> = .constant(""),
        rowHeight: CGFloat = 30,
        wrapCells: Bool = false,
        dirtyRows: Set<Int> = [],
        canEditCell: ((Int, ColumnDescriptor) -> Bool)? = nil,
        onBeginEditingCell: ((EditableCell) -> Void)? = nil,
        onCommitEditingCell: (() -> Void)? = nil,
        onOpenRow: ((Int) -> Void)? = nil
    ) {
        self.columns = columns
        self.rows = rows
        _sortOrder = sortOrder
        _columnWidths = columnWidths
        _editingCell = editingCell
        _editingText = editingText
        self.rowHeight = rowHeight
        self.wrapCells = wrapCells
        self.dirtyRows = dirtyRows
        self.canEditCell = canEditCell
        self.onBeginEditingCell = onBeginEditingCell
        self.onCommitEditingCell = onCommitEditingCell
        self.onOpenRow = onOpenRow
    }

    var body: some View {
        if columns.isEmpty {
            ContentUnavailableView("No Results", systemImage: "tablecells")
        } else {
            let widths = resolvedColumnWidths()
            let totalWidth = markerWidth + widths.reduce(0, +)

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows.indices, id: \.self) { index in
                            dataRow(at: index, widths: widths)
                                .frame(width: totalWidth, alignment: .leading)
                            Divider()
                        }
                    } header: {
                        headerRow(widths: widths)
                            .frame(width: totalWidth, alignment: .leading)
                            .background(.bar)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
            .font(.callout.monospaced())
            .onChange(of: editingCell) { _, newValue in
                focusedCell = newValue
            }
            .onChange(of: focusedCell) { _, newValue in
                guard editingCell != nil, newValue == nil else { return }
                onCommitEditingCell?()
            }
        }
    }

    /// Estimate a width per column from its header and a sample of values. Only a sample is
    /// measured — walking every row would undo the laziness of the scroll view.
    private func resolvedColumnWidths() -> [CGFloat] {
        columns.enumerated().map { index, column in
            columnWidths[column.name] ?? estimatedWidth(for: column, at: index)
        }
    }

    private func estimatedWidth(for column: ColumnDescriptor, at index: Int) -> CGFloat {
        var longest = column.name.count + (column.isPrimaryKey ? 2 : 0)
        for row in rows.prefix(40) where row.indices.contains(index) {
            longest = max(longest, min(row[index].displayText.count, 40))
        }
        return min(max(CGFloat(longest) * 8 + 24, minColumnWidth), 280)
    }

    private func headerRow(widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: markerWidth)
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                headerCell(for: column, at: index, width: widths[index])
            }
        }
        .overlay(alignment: .bottom) { Divider() }
    }

    private func headerCell(for column: ColumnDescriptor, at index: Int, width: CGFloat) -> some View {
        Button {
            toggleSort(column.name)
        } label: {
            HStack(spacing: 3) {
                if column.isPrimaryKey {
                    Image(systemName: "key.fill").font(.system(size: 8)).foregroundStyle(.orange)
                }
                Text(column.name).fontWeight(.semibold).lineLimit(1)
                if let ascending = sortDirection(for: column.name) {
                    Image(systemName: ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tint)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(width: width, alignment: .leading)
            .padding(.vertical, 7)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Sort by \(column.name)")
        .overlay(alignment: .trailing) {
            resizeHandle(for: column, fallbackWidth: width)
        }
    }

    private func resizeHandle(for column: ColumnDescriptor, fallbackWidth: CGFloat) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 10)
            .contentShape(.rect)
            .overlay(alignment: .center) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 3, height: 18)
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let startWidth = resizeStartWidths[column.name] ?? columnWidths[column.name] ?? fallbackWidth
                        resizeStartWidths[column.name] = startWidth
                        let updated = min(max(startWidth + value.translation.width, minColumnWidth), maxColumnWidth)
                        columnWidths[column.name] = updated
                    }
                    .onEnded { _ in
                        resizeStartWidths[column.name] = nil
                    }
            )
            .help("Drag to resize \(column.name)")
    }

    private func dataRow(at index: Int, widths: [CGFloat]) -> some View {
        let row = rows[index]
        return HStack(spacing: 0) {
            Group {
                if dirtyRows.contains(index) {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption2)
                        .help("This row has unsaved changes")
                } else {
                    Color.clear
                }
            }
            .frame(width: markerWidth, height: rowHeight)

            ForEach(Array(columns.enumerated()), id: \.element.id) { columnIndex, column in
                let value = row.indices.contains(columnIndex) ? row[columnIndex] : SQLValue.null
                let cell = EditableCell(rowIndex: index, columnName: column.name)
                tableCell(value, cell: cell, column: column, width: widths[columnIndex])
            }
        }
        .background(index.isMultiple(of: 2) ? AnyShapeStyle(.quaternary.opacity(0.2)) : AnyShapeStyle(.clear))
        .contentShape(.rect)
        .onTapGesture(count: 2) { onOpenRow?(index) }
    }

    @ViewBuilder
    private func tableCell(_ value: SQLValue, cell: EditableCell, column: ColumnDescriptor, width: CGFloat) -> some View {
        if editingCell == cell {
            inlineEditor(for: cell, column: column, width: width)
        } else {
            Text(value.displayText)
                .foregroundStyle(value.isNull ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                .lineLimit(lineLimit(for: column))
                .truncationMode(wrapCells ? .tail : .tail)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 6)
                .padding(.vertical, wrapCells ? 6 : 0)
                .frame(width: width, height: rowHeight, alignment: wrapCells ? .topLeading : .leading)
                .textSelection(.enabled)
                .help(value.displayText)
                .contentShape(.rect)
                .onTapGesture {
                    beginEditing(cell, rowIndex: cell.rowIndex, column: column)
                }
        }
    }

    @ViewBuilder
    private func inlineEditor(for cell: EditableCell, column: ColumnDescriptor, width: CGFloat) -> some View {
        let editor = TextField(
            column.name,
            text: $editingText,
            axis: usesMultilineEditor(for: column) ? .vertical : .horizontal
        )
            .textFieldStyle(.plain)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 6)
            .padding(.vertical, wrapCells || column.prefersMultilineEditor ? 6 : 0)
            .frame(width: width, height: rowHeight, alignment: .topLeading)
            .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .focused($focusedCell, equals: cell)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .onSubmit { onCommitEditingCell?() }
            .help("Press Return or click away to stage this edit")

        if usesMultilineEditor(for: column) {
            editor.lineLimit(1...max(1, lineLimit(for: column)))
        } else {
            editor.lineLimit(1)
        }
    }

    private func beginEditing(_ cell: EditableCell, rowIndex: Int, column: ColumnDescriptor) {
        guard canEditCell?(rowIndex, column) == true else { return }
        if editingCell != cell {
            onCommitEditingCell?()
        }
        onBeginEditingCell?(cell)
        focusedCell = cell
    }

    private func usesMultilineEditor(for column: ColumnDescriptor) -> Bool {
        wrapCells || column.prefersMultilineEditor
    }

    private func lineLimit(for column: ColumnDescriptor) -> Int {
        guard wrapCells || column.prefersMultilineEditor else { return 1 }
        return max(1, Int((rowHeight - 10) / 18))
    }

    private func sortDirection(for column: String) -> Bool? {
        sortOrder.first { $0.column == column }.map { $0.order == .forward }
    }

    /// Cycle a column through ascending → descending → unsorted.
    ///
    /// Single-column: multi-column sort is rarely what someone tapping a header wants, and the
    /// resulting state is hard to read at a glance.
    private func toggleSort(_ column: String) {
        if let current = sortOrder.first, current.column == column {
            sortOrder = current.order == .forward
            ? [ColumnSortComparator(column: column, order: .reverse)]
            : []
        } else {
            sortOrder = [ColumnSortComparator(column: column, order: .forward)]
        }
    }
}
