import SwiftUI

/// Table picker + paged result grid for one open session.
struct TableBrowserView: View {
    let session: any DatabaseSession
    let connection: Connection
    let tables: [TableDescriptor]
    @Binding var selectedTable: TableDescriptor?
    @Binding var workspaceMode: WorkspaceMode
    var showsWorkspaceModePicker = false
    /// False when a table list column is on screen, which would make this picker a duplicate.
    var showsTablePicker = true
    var onConnectionLost: (() -> Void)? = nil

    @State private var result: ResultSet?
    @State private var rows: [[SQLValue]] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    // Explicit paging: one page is held in memory at a time, so browsing a large table costs
    // the same as a small one.
    @State private var offset = 0
    @State private var pageSize = 200
    @State private var totalRows: Int?

    // Query shaping: sort, per-column filters and free-text search.
    // `Table` owns the sort UI, so its comparators are the source of truth and `sort` is
    // derived from them for the query.
    @State private var sortOrder: [ColumnSortComparator] = []
    @State private var filters: [ColumnFilter] = []
    @State private var searchText = ""
    @State private var editingFilter: ColumnFilter?

    // Editing state. Changes accumulate here and reach the database only on Apply.
    @State private var pending: [RowMutation] = []
    @State private var editingRow: EditingRow?
    @State private var editingCell: EditableCell?
    @State private var editingText = ""
    @State private var showsReview = false
    @State private var previewStatements: [String] = []
    @State private var commitError: String?
    @State private var columnWidths: [String: CGFloat] = [:]
    @State private var rowHeight: CGFloat = 30
    @State private var wrapCells = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// Identifies which row the editor sheet is showing.
    private struct EditingRow: Identifiable {
        let id = UUID()
        let values: [String: SQLValue]
        let isInsert: Bool
    }

    var body: some View {
        VStack(spacing: 0) {
            if tables.isEmpty {
                ContentUnavailableView(
                    "Empty Database",
                    systemImage: "tablecells",
                    description: Text("This database contains no tables.")
                )
            } else {
                header
                if !filters.isEmpty {
                    filterChips
                }
                Divider()
                content
            }
        }
        .safeAreaBar(edge: .bottom) {
            if !tables.isEmpty {
                PagerView(
                    offset: offset,
                    pageSize: pageSize,
                    loadedRows: rows.count,
                    totalRows: totalRows,
                    hasMore: result?.hasMore == true,
                    isLoading: isLoading,
                    onJump: { newOffset in
                        guard newOffset != offset else { return }
                        offset = newOffset
                        Task { await loadPage(at: newOffset) }
                    },
                    onChangePageSize: { size in
                        guard size != pageSize else { return }
                        pageSize = size
                        offset = 0
                        Task { await loadPage(at: 0, pageSize: size) }
                    }
                )
            }
        }
        .searchable(text: $searchText, prompt: "Search all columns")
        .task(id: selectedTable?.id) {
            // A new table invalidates sort and filters that referenced the old columns.
            sortOrder = []
            filters = []
            searchText = ""
            offset = 0
            columnWidths = [:]
            editingCell = nil
            editingText = ""
            await loadPage()
        }
        .task(id: tables.map(\.id)) {
            guard selectedTable.map({ selected in
                tables.contains { $0.id == selected.id }
            }) != true else { return }
            selectedTable = tables.first
        }
        .task(id: searchText) {
            // Debounce: typing should not fire a query per keystroke.
            guard !searchText.isEmpty || result != nil else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            offset = 0
            await loadPage()
        }
        .task(id: filters) { offset = 0; await loadPage() }
        .task(id: sortOrder) { offset = 0; await loadPage() }
        .sheet(item: $editingFilter) { filter in
            FilterEditorView(
                filter: filter,
                columns: filterColumns
            ) { updated in
                if let index = filters.firstIndex(where: { $0.id == updated.id }) {
                    filters[index] = updated
                } else {
                    filters.append(updated)
                }
            }
        }
        .sheet(item: $editingRow) { editing in
            if let table = activeTable {
                RowEditorView(
                    table: table,
                    original: editing.values,
                    isInsert: editing.isInsert
                ) { mutation in
                    stage(mutation, against: editing.values)
                }
            }
        }
        .sheet(isPresented: $showsReview) {
            PendingChangesView(
                mutations: pending,
                statements: previewStatements,
                isAtomic: session.capabilities.supportsTransactions,
                onCommit: { Task { await applyPending() } },
                onDiscard: { mutation in pending.removeAll { $0.id == mutation.id } }
            )
        }
        .alert("Could Not Apply Changes", isPresented: $commitError.isPresent()) {
            Button("OK") { commitError = nil }
        } message: {
            Text(commitError ?? "")
        }
        .toolbar {
            if horizontalSizeClass != .compact {
                ToolbarItem(placement: .secondaryAction) { displayMenu }
                ToolbarItem(placement: .secondaryAction) { filterMenu }
                if isEditable {
                    ToolbarItemGroup(placement: .primaryAction) {
                        rowEditingControls
                    }
                }
            }
        }
        .focusedSceneValue(\.browserActions, BrowserActions(
            refresh: { Task { await loadPage() } },
            addRow: isEditable ? { editingRow = EditingRow(values: [:], isInsert: true) } : nil,
            reviewChanges: pending.isEmpty ? nil : { prepareReview() },
            pendingCount: pending.count
        ))
    }

    /// Editing needs three things to line up: the connection isn't read-only, the driver can
    /// write, and the table has a key we can target.
    private var isEditable: Bool {
        guard !connection.isReadOnly, session.capabilities.canEditRows else { return false }
        return activeTable?.isEditable == true
    }

    /// A menu-style picker can briefly display its first item while its optional binding is nil.
    /// Resolve that same visible table so nearby actions never disagree with what the user sees.
    private var activeTable: TableDescriptor? {
        if let selectedTable,
           tables.contains(where: { $0.id == selectedTable.id }) {
            return selectedTable
        }
        return tables.first
    }

    /// Introspection normally supplies these. If it momentarily does not, the loaded result still
    /// has enough column metadata to offer filtering for the table already on screen.
    private var filterColumns: [ColumnDescriptor] {
        let described = activeTable?.columns ?? []
        return described.isEmpty ? (result?.columns ?? []) : described
    }

    private var displayedRows: [[SQLValue]] {
        guard let result else { return rows }
        let updates = Dictionary(uniqueKeysWithValues: pending.compactMap { mutation -> (String, [String: SQLValue])? in
            guard mutation.kind == .update else { return nil }
            return (mutation.keyDescription, mutation.values)
        })

        return rows.indices.map { index in
            var values = rows[index]
            guard let table = activeTable else { return values }
            let key = RowMutation.delete(primaryKey: primaryKeyValues(at: index, table: table)).keyDescription
            guard let changes = updates[key] else { return values }
            for (columnName, value) in changes {
                if let position = result.columns.firstIndex(where: { $0.name == columnName }),
                   values.indices.contains(position) {
                    values[position] = value
                }
            }
            return values
        }
    }

    private var dirtyRowIndices: Set<Int> {
        guard let table = activeTable else { return [] }
        let keys = Set(pending.filter { $0.kind != .insert }.map(\.keyDescription))
        guard !keys.isEmpty else { return [] }

        return Set(rows.indices.filter { index in
            keys.contains(RowMutation.delete(primaryKey: primaryKeyValues(at: index, table: table)).keyDescription)
        })
    }

    private func primaryKeyValues(at index: Int, table: TableDescriptor) -> [String: SQLValue] {
        guard let result, rows.indices.contains(index) else { return [:] }
        var values: [String: SQLValue] = [:]
        for column in table.primaryKey {
            if let position = result.columns.firstIndex(where: { $0.name == column }),
               rows[index].indices.contains(position) {
                values[column] = rows[index][position]
            }
        }
        return values
    }

    private func rowDictionary(at index: Int) -> [String: SQLValue] {
        rowDictionary(at: index, from: displayedRows)
    }

    private func rowDictionary(at index: Int, from sourceRows: [[SQLValue]]) -> [String: SQLValue] {
        guard let result, sourceRows.indices.contains(index) else { return [:] }
        var values: [String: SQLValue] = [:]
        for (position, column) in result.columns.enumerated() where sourceRows[index].indices.contains(position) {
            values[column.name] = sourceRows[index][position]
        }
        return values
    }

    private func stage(_ mutation: RowMutation, against original: [String: SQLValue] = [:]) {
        switch mutation.kind {
        case .insert:
            pending.append(mutation)
        case .delete:
            pending.removeAll { $0.kind == .update && $0.primaryKey == mutation.primaryKey }
            pending.append(mutation)
        case .update:
            let normalized = mutation.values.filter { original[$0.key] != $0.value }
            if let index = pending.firstIndex(where: { $0.kind == .update && $0.primaryKey == mutation.primaryKey }) {
                var merged = pending[index].values
                for (column, value) in normalized {
                    merged[column] = value
                }
                for column in Array(merged.keys) where original[column] == merged[column] {
                    merged.removeValue(forKey: column)
                }
                if merged.isEmpty {
                    pending.remove(at: index)
                } else {
                    pending[index] = .update(primaryKey: mutation.primaryKey, values: merged)
                }
            } else if !normalized.isEmpty {
                pending.append(.update(primaryKey: mutation.primaryKey, values: normalized))
            }
        }
    }

    private func prepareReview() {
        guard let table = activeTable else { return }
        do {
            previewStatements = try session.preview(pending, to: table)
            showsReview = true
        } catch {
            commitError = error.localizedDescription
        }
    }

    private func applyPending() async {
        guard let table = activeTable else { return }
        do {
            _ = try await session.apply(pending, to: table)
            pending.removeAll()
            showsReview = false
            offset = 0
            await loadPage()
        } catch {
            showsReview = false
            commitError = error.localizedDescription
        }
    }

    @ViewBuilder
    private var header: some View {
        if horizontalSizeClass == .compact {
            compactHeader
        } else {
            regularHeader
        }
    }

    /// On a phone, the table title needs the full row. Putting the mode picker beside it made
    /// long names wrap into a narrow column and obscured the current selection.
    private var compactHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                compactTableSelection

                Spacer(minLength: 4)

                if let result {
                    Text(statusText(result))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
            }

            HStack(spacing: 8) {
                if showsWorkspaceModePicker {
                    WorkspaceModePicker(selection: $workspaceMode, compact: true)
                }

                Spacer(minLength: 0)

                if isEditable {
                    Button("Add Row", systemImage: "plus") {
                        editingRow = EditingRow(values: [:], isInsert: true)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                }

                refreshButton
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)

                filterMenu
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)

                displayMenu
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)

                if !pending.isEmpty {
                    Button {
                        prepareReview()
                    } label: {
                        Label("Review \(pending.count)", systemImage: "checklist")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glassProminent)
                    .tint(.orange)
                    .badge(pending.count)
                }
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var compactTableSelection: some View {
        if showsTablePicker {
            Picker("Table", selection: $selectedTable) {
                ForEach(tables) { table in
                    Label(table.name, systemImage: table.kind == .view ? "eye" : "tablecells")
                        .lineLimit(1)
                        .tag(Optional(table))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let table = activeTable {
            Label(table.name, systemImage: table.kind == .view ? "eye" : "tablecells")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var regularHeader: some View {
        HStack {
            if showsTablePicker {
                Picker("Table", selection: $selectedTable) {
                    ForEach(tables) { table in
                        Label(table.name, systemImage: table.kind == .view ? "eye" : "tablecells")
                            .tag(Optional(table))
                    }
                }
                .frame(maxWidth: 320, alignment: .leading)
            } else if let table = activeTable {
                // The list column owns selection, so the header just names what is shown.
                Label(table.name, systemImage: table.kind == .view ? "eye" : "tablecells")
                    .font(.headline)
            }

            if let table = activeTable, let reason = readOnlyReason(for: table) {
                Label(reason, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(reason)
            } else if isEditable {
                Text("Tap a cell to edit inline, or double-click a row for the full editor")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            if !pending.isEmpty {
                Button {
                    prepareReview()
                } label: {
                    Label("\(pending.count) unsaved", systemImage: "pencil.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.orange)
            }

            refreshButton

            if let result {
                Text(statusText(result))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var refreshButton: some View {
        Button("Refresh Table", systemImage: "arrow.clockwise") {
            Task { await loadPage() }
        }
        .disabled(isLoading)
        .help("Refresh table")
    }

    @ViewBuilder
    private var content: some View {
        if let errorMessage {
            ContentUnavailableView {
                Label("Query Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage)
            } actions: {
                Button("Retry") { Task { await loadPage() } }
            }
        } else if let result {
            ResultTableView(
                columns: result.columns,
                rows: displayedRows,
                sortOrder: $sortOrder,
                columnWidths: $columnWidths,
                editingCell: $editingCell,
                editingText: $editingText,
                rowHeight: rowHeight,
                wrapCells: wrapCells,
                dirtyRows: dirtyRowIndices,
                canEditCell: { index, column in
                    canEditCell(at: index, column: column)
                },
                onBeginEditingCell: { cell in
                    beginInlineEdit(cell)
                },
                onCommitEditingCell: {
                    commitInlineEdit()
                },
                onOpenRow: isEditable ? { index in
                    editingRow = EditingRow(values: rowDictionary(at: index), isInsert: false)
                } : nil
            )
        } else if isLoading {
            DatabaseLoadingView("Loading rows…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func readOnlyReason(for table: TableDescriptor) -> String? {
        if connection.isReadOnly { return "Connection is read-only" }
        return table.readOnlyReason
    }

    private func statusText(_ result: ResultSet) -> String {
        result.elapsed.formatted(.units(allowed: [.milliseconds], width: .narrow))
    }

    private var displayMenu: some View {
        Menu {
            Button {
                wrapCells.toggle()
            } label: {
                Label("Wrap Cell Text", systemImage: wrapCells ? "checkmark" : "text.justify.left")
            }

            Menu("Row Height") {
                ForEach([30, 52, 80, 120], id: \.self) { height in
                    Button {
                        rowHeight = CGFloat(height)
                    } label: {
                        Label(rowHeightTitle(CGFloat(height)), systemImage: rowHeight == CGFloat(height) ? "checkmark" : "circle")
                    }
                }
            }

            Button("Reset Column Widths") {
                columnWidths = [:]
            }
            .disabled(columnWidths.isEmpty)
        } label: {
            Label("Display", systemImage: "slider.horizontal.3")
        }
    }

    /// Translate the table's comparators into the query's ORDER BY.
    private var sort: [SortTerm] {
        sortOrder.map { SortTerm(column: $0.column, ascending: $0.order == .forward) }
    }

    /// Menu of columns to filter on. The old grid put this in a header context menu, which
    /// `Table` does not expose, so it lives with the table actions instead.
    private var filterMenu: some View {
        Menu {
            ForEach(filterColumns) { column in
                Menu(column.name) {
                    ForEach(FilterOperator.options(for: column)) { op in
                        Button(op.title) {
                            editingFilter = ColumnFilter(column: column.name, op: op)
                        }
                    }
                }
            }
        } label: {
            Label("Filter", systemImage: "line.3.horizontal.decrease.circle")
        }
        .disabled(filterColumns.isEmpty)
    }

    @ViewBuilder
    private var rowEditingControls: some View {
        Button("Add Row", systemImage: "plus") {
            editingRow = EditingRow(values: [:], isInsert: true)
        }
        Button {
            prepareReview()
        } label: {
            Label("Review \(pending.count)", systemImage: "checklist")
        }
        .disabled(pending.isEmpty)
        .badge(pending.count)
    }

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(filters) { filter in
                    Button {
                        editingFilter = filter
                    } label: {
                        HStack(spacing: 4) {
                            Text(filter.summary).lineLimit(1)
                            Button {
                                filters.removeAll { $0.id == filter.id }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.tint.opacity(0.15), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }

                Button("Clear All") { filters.removeAll() }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.bottom, 6)
        }
    }

    private func rowHeightTitle(_ height: CGFloat) -> String {
        switch height {
        case 30: "Compact"
        case 52: "Comfortable"
        case 80: "Tall"
        default: "Extra Tall"
        }
    }

    private func canEditCell(at rowIndex: Int, column: ColumnDescriptor) -> Bool {
        guard isEditable, column.supportsInlineEditing else { return false }
        guard let table = activeTable else { return false }
        return !primaryKeyValues(at: rowIndex, table: table).isEmpty
    }

    private func beginInlineEdit(_ cell: EditableCell) {
        guard let result,
              displayedRows.indices.contains(cell.rowIndex),
              let columnIndex = result.columns.firstIndex(where: { $0.name == cell.columnName }),
              displayedRows[cell.rowIndex].indices.contains(columnIndex) else { return }
        let value = displayedRows[cell.rowIndex][columnIndex]
        editingText = value.isNull ? "" : value.displayText
        editingCell = cell
    }

    private func commitInlineEdit() {
        guard let cell = editingCell,
              let table = activeTable,
              rows.indices.contains(cell.rowIndex),
              let column = filterColumns.first(where: { $0.name == cell.columnName }) else {
            editingCell = nil
            editingText = ""
            return
        }

        defer {
            editingCell = nil
            editingText = ""
        }

        let originalValues = rowDictionary(at: cell.rowIndex, from: rows)
        let originalValue = originalValues[column.name] ?? .null
        let originalText = originalValue.isNull ? "" : originalValue.displayText
        guard editingText != originalText else { return }

        let primaryKey = primaryKeyValues(at: cell.rowIndex, table: table)
        guard !primaryKey.isEmpty else { return }

        stage(
            .update(primaryKey: primaryKey, values: [column.name: column.bind(editingText)]),
            against: originalValues
        )
    }

    private func loadPage(at requestedOffset: Int? = nil, pageSize requestedPageSize: Int? = nil) async {
        guard let table = activeTable else { return }
        commitInlineEdit()
        // Pager actions pass their destination explicitly. Reading `@State` again in the new
        // asynchronous task can otherwise observe the previous render's offset on iOS.
        let queryOffset = requestedOffset ?? offset
        let queryPageSize = requestedPageSize ?? pageSize
        isLoading = true
        errorMessage = nil
        result = nil
        rows = []

        let request = RowRequest(
            table: table.name,
            schema: table.schema,
            sort: sort,
            filters: filters,
            search: searchText.isEmpty ? nil : searchText,
            limit: queryPageSize,
            offset: queryOffset
        )
        do {
            let page = try await session.fetch(request)
            result = page
            rows = page.rows

            // Count separately: it is a second round-trip, and a failure there (no permission,
            // slow table) should not stop the rows from being shown.
            totalRows = try? await session.count(request)

            // Filtering can leave the offset past the end of the new result — fall back to the
            // first page rather than showing a confusing empty grid.
            if page.rows.isEmpty && queryOffset > 0 {
                offset = 0
                await loadPage(at: 0, pageSize: queryPageSize)
                return
            }
        } catch {
            errorMessage = error.localizedDescription
            if isLikelyConnectionFailure(error) {
                onConnectionLost?()
            }
        }
        isLoading = false
    }

    private func isLikelyConnectionFailure(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("not connected")
            || message.contains("connection")
            || message.contains("socket")
            || message.contains("network")
            || message.contains("timed out")
            || message.contains("closed")
    }
}
