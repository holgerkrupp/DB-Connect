import SwiftUI

/// Read-only result grid.
///
/// On macOS and iPad this wants to become a `Table` with sortable, resizable columns; phase 1
/// uses one horizontally scrolling grid so a single implementation covers iPhone too, where
/// `Table` collapses to its first column anyway.
struct ResultGridView: View {
    let columns: [ColumnDescriptor]
    let rows: [[SQLValue]]
    let hasMore: Bool
    var loadMore: () -> Void = {}
    /// Set when the table is editable; nil leaves rows inert.
    var onSelectRow: ((Int) -> Void)?
    /// Rows with uncommitted edits, highlighted so pending work is never invisible.
    var dirtyRows: Set<Int> = []

    private let minColumnWidth: CGFloat = 90
    private let maxColumnWidth: CGFloat = 260

    var body: some View {
        if columns.isEmpty {
            ContentUnavailableView("No Results", systemImage: "tablecells")
        } else {
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    headerRow
                    Divider().gridCellUnsizedAxes(.horizontal)

                    ForEach(rows.indices, id: \.self) { rowIndex in
                        if onSelectRow != nil {
                            dataRow(rows[rowIndex], at: rowIndex, striped: rowIndex.isMultiple(of: 2))
                        } else {
                            dataRow(rows[rowIndex], striped: rowIndex.isMultiple(of: 2))
                        }
                    }

                    if hasMore {
                        loadMoreRow
                    }
                }
                .padding(.bottom)
            }
            .font(.callout.monospaced())
        }
    }

    private var headerRow: some View {
        GridRow {
            ForEach(columns) { column in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        if column.isPrimaryKey {
                            Image(systemName: "key.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(.orange)
                        }
                        Text(column.name).fontWeight(.semibold)
                    }
                    Text(column.declaredType.isEmpty ? " " : column.declaredType.lowercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(minWidth: minColumnWidth, maxWidth: maxColumnWidth, alignment: .leading)
            }
        }
        .background(.quaternary.opacity(0.5))
    }

    private func dataRow(_ row: [SQLValue], striped: Bool) -> some View {
        GridRow {
            ForEach(row.indices, id: \.self) { index in
                cell(row[index])
            }
        }
        .background(background(striped: striped, isDirty: false))
    }

    private func dataRow(_ row: [SQLValue], at index: Int, striped: Bool) -> some View {
        let isDirty = dirtyRows.contains(index)
        return GridRow {
            ForEach(row.indices, id: \.self) { column in
                cell(row[column])
            }
        }
        .background(background(striped: striped, isDirty: isDirty))
        .contentShape(.rect)
        .onTapGesture(count: 2) { onSelectRow?(index) }
    }

    private func background(striped: Bool, isDirty: Bool) -> AnyShapeStyle {
        if isDirty { return AnyShapeStyle(.orange.opacity(0.22)) }
        return striped ? AnyShapeStyle(.quaternary.opacity(0.25)) : AnyShapeStyle(.clear)
    }

    private func cell(_ value: SQLValue) -> some View {
        Text(value.displayText)
            .foregroundStyle(value.isNull ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.primary))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .frame(minWidth: minColumnWidth, maxWidth: maxColumnWidth, alignment: .leading)
            .textSelection(.enabled)
    }

    private var loadMoreRow: some View {
        GridRow {
            Button("Load More…", action: loadMore)
                .buttonStyle(.borderless)
                .padding(8)
                .gridCellColumns(columns.count)
                // Fires when the user scrolls the sentinel into view, so paging feels automatic.
                .onAppear(perform: loadMore)
        }
    }
}
