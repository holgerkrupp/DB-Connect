import SwiftUI

/// A sort descriptor for a result column. The database does the sorting, so this only records
/// which column and direction the header is showing — see `TableBrowserView`, which turns it
/// into an `ORDER BY` and re-queries.
nonisolated struct ColumnSortComparator: Hashable {
    let column: String
    var order: SortOrder = .forward
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
    /// Row indices with uncommitted edits, marked so pending work is never invisible.
    var dirtyRows: Set<Int> = []
    var onSelectRow: ((Int) -> Void)?

    private let markerWidth: CGFloat = 22
    private let rowHeight: CGFloat = 30

    var body: some View {
        if columns.isEmpty {
            ContentUnavailableView("No Results", systemImage: "tablecells")
        } else {
            let widths = columnWidths()
            let totalWidth = markerWidth + widths.reduce(0, +)

            ScrollView([.horizontal, .vertical]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows.indices, id: \.self) { index in
                            dataRow(at: index, widths: widths)
                                .frame(width: totalWidth, height: rowHeight, alignment: .leading)
                            Divider()
                        }
                    } header: {
                        headerRow(widths: widths)
                            .frame(width: totalWidth, alignment: .leading)
                            .background(.bar)
                    }
                }
            }
            .font(.callout.monospaced())
        }
    }

    /// Estimate a width per column from its header and a sample of values. Only a sample is
    /// measured — walking every row would undo the laziness of the scroll view.
    private func columnWidths() -> [CGFloat] {
        columns.enumerated().map { index, column in
            var longest = column.name.count + (column.isPrimaryKey ? 2 : 0)
            for row in rows.prefix(40) where row.indices.contains(index) {
                longest = max(longest, min(row[index].displayText.count, 40))
            }
            return min(max(CGFloat(longest) * 8 + 24, 80), 280)
        }
    }

    private func headerRow(widths: [CGFloat]) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: markerWidth)
            ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
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
                    .frame(width: widths[index], alignment: .leading)
                    .padding(.vertical, 7)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("Sort by \(column.name)")
            }
        }
        .overlay(alignment: .bottom) { Divider() }
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
            .frame(width: markerWidth)

            ForEach(widths.indices, id: \.self) { column in
                let value = row.indices.contains(column) ? row[column] : SQLValue.null
                Text(value.displayText)
                    .foregroundStyle(value.isNull ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6)
                    .frame(width: widths[column], alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .background(index.isMultiple(of: 2) ? AnyShapeStyle(.quaternary.opacity(0.2)) : AnyShapeStyle(.clear))
        .contentShape(.rect)
        .onTapGesture { onSelectRow?(index) }
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
