import SwiftUI

/// One row of a result set, addressable by its position in the page.
nonisolated struct ResultRow: Identifiable, Hashable {
    /// Index within the current page — stable for as long as the page is displayed.
    let id: Int
    let values: [SQLValue]

    func value(at index: Int) -> SQLValue {
        values.indices.contains(index) ? values[index] : .null
    }
}

/// Sorting is done by the database, not in the view.
///
/// `Table` insists on a `SortComparator` to drive its header indicators, but comparing rows
/// locally would only reorder the current page — which is wrong, since a page is a window onto
/// a much larger result. So `compare` deliberately does nothing, and the view reacts to
/// `sortOrder` changing by re-querying the server with a new ORDER BY.
nonisolated struct ColumnSortComparator: SortComparator, Hashable {
    typealias Compared = ResultRow

    let column: String
    var order: SortOrder = .forward

    func compare(_ lhs: ResultRow, _ rhs: ResultRow) -> ComparisonResult {
        .orderedSame
    }
}

/// Result grid built on SwiftUI's `Table`.
///
/// `Table` is lazy, and gives resizable, reorderable columns and native sort indicators for
/// free. On compact iPhone width it collapses to a single column, so that case falls back to a
/// row list that opens a detail view — a twelve-column table is unusable on a phone anyway.
struct ResultTableView: View {
    let columns: [ColumnDescriptor]
    let rows: [[SQLValue]]
    @Binding var sortOrder: [ColumnSortComparator]
    /// Row indices with uncommitted edits, marked so pending work is never invisible.
    var dirtyRows: Set<Int> = []
    var onSelectRow: ((Int) -> Void)?

    @State private var selection: ResultRow.ID?

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    private var tableRows: [ResultRow] {
        rows.enumerated().map { ResultRow(id: $0.offset, values: $0.element) }
    }

    var body: some View {
        if columns.isEmpty {
            ContentUnavailableView("No Results", systemImage: "tablecells")
        } else {
            #if os(iOS)
            if sizeClass == .compact {
                compactList
            } else {
                table
            }
            #else
            table
            #endif
        }
    }

    private var table: some View {
        Table(of: ResultRow.self, selection: $selection, sortOrder: $sortOrder) {
            // A narrow marker column: Table gives no way to style a whole row, so pending
            // edits are shown here rather than as a row tint.
            TableColumn("") { row in
                if dirtyRows.contains(row.id) {
                    Image(systemName: "pencil.circle.fill")
                        .foregroundStyle(.orange)
                        .help("This row has unsaved changes")
                }
            }
            .width(18)

            TableColumnForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                TableColumn(header(for: column), sortUsing: ColumnSortComparator(column: column.name)) { row in
                    let value = row.value(at: index)
                    Text(value.displayText)
                        .foregroundStyle(value.isNull ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                        .lineLimit(1)
                        .help(value.displayText)
                }
                .width(min: 60, ideal: idealWidth(for: column, at: index))
            }
        } rows: {
            ForEach(tableRows) { row in
                TableRow(row)
            }
        }
        .monospacedDigit()
        .contextMenu(forSelectionType: ResultRow.ID.self) { ids in
            if let id = ids.first, onSelectRow != nil {
                Button("Edit Row…", systemImage: "pencil") { onSelectRow?(id) }
            }
        } primaryAction: { ids in
            // Double-click (macOS) / double-tap opens the editor.
            if let id = ids.first { onSelectRow?(id) }
        }
    }

    /// A key icon in the header marks primary keys, as the old grid did.
    private func header(for column: ColumnDescriptor) -> String {
        column.isPrimaryKey ? "🔑 \(column.name)" : column.name
    }

    /// Estimate a starting width from the header and a sample of values. Only a sample is
    /// measured — walking every row would undo the laziness `Table` provides.
    private func idealWidth(for column: ColumnDescriptor, at index: Int) -> CGFloat {
        var longest = column.name.count + (column.isPrimaryKey ? 2 : 0)
        for row in rows.prefix(40) where row.indices.contains(index) {
            longest = max(longest, min(row[index].displayText.count, 40))
        }
        return min(max(CGFloat(longest) * 8 + 24, 80), 280)
    }

    #if os(iOS)
    /// iPhone: `Table` would show only the first column, so show a summary per row instead.
    private var compactList: some View {
        List(tableRows) { row in
            Button {
                onSelectRow?(row.id)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(primarySummary(for: row))
                            .font(.headline)
                            .lineLimit(1)
                        if dirtyRows.contains(row.id) {
                            Image(systemName: "pencil.circle.fill").foregroundStyle(.orange)
                        }
                    }
                    Text(secondarySummary(for: row))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
    }

    /// Lead with the primary key when there is one — it is what identifies the row.
    private func primarySummary(for row: ResultRow) -> String {
        if let keyIndex = columns.firstIndex(where: \.isPrimaryKey) {
            return "\(columns[keyIndex].name): \(row.value(at: keyIndex).displayText)"
        }
        return row.value(at: 0).displayText
    }

    private func secondarySummary(for row: ResultRow) -> String {
        columns.enumerated()
            .filter { !$0.element.isPrimaryKey }
            .prefix(4)
            .map { "\($0.element.name): \(row.value(at: $0.offset).displayText)" }
            .joined(separator: " · ")
    }
    #endif
}
