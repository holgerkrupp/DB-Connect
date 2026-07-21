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
    @State private var showsReview = false
    @State private var previewStatements: [String] = []
    @State private var commitError: String?

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
                if horizontalSizeClass == .compact {
                    compactTableControls
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
                    isLoading: isLoading,
                    onJump: { newOffset in
                        offset = newOffset
                        Task { await loadPage() }
                    },
                    onChangePageSize: { size in
                        pageSize = size
                        offset = 0
                        Task { await loadPage() }
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
                    pending.append(mutation)
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
        guard let result, rows.indices.contains(index) else { return [:] }
        var values: [String: SQLValue] = [:]
        for (position, column) in result.columns.enumerated() where rows[index].indices.contains(position) {
            values[column.name] = rows[index][position]
        }
        return values
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

    private var header: some View {
        HStack {
            if showsTablePicker {
                Picker("Table", selection: $selectedTable) {
                    ForEach(tables) { table in
                        Label(table.name, systemImage: table.kind == .view ? "eye" : "tablecells")
                            .tag(Optional(table))
                    }
                }
                .frame(
                    maxWidth: horizontalSizeClass == .compact ? 130 : 320,
                    alignment: .leading
                )
            } else if let table = activeTable {
                // The list column owns selection, so the header just names what is shown.
                Label(table.name, systemImage: table.kind == .view ? "eye" : "tablecells")
                    .font(.headline)
            }

            if horizontalSizeClass == .compact {
                if showsWorkspaceModePicker {
                    WorkspaceModePicker(selection: $workspaceMode, compact: true)
                }
            } else if let table = activeTable, let reason = readOnlyReason(for: table) {
                Label(reason, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(reason)
            } else if isEditable {
                Text("Double-click a row to edit")
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
                rows: rows,
                sortOrder: $sortOrder,
                dirtyRows: dirtyRowIndices,
                onSelectRow: isEditable ? { index in
                    editingRow = EditingRow(values: rowDictionary(at: index), isInsert: false)
                } : nil
            )
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func readOnlyReason(for table: TableDescriptor) -> String? {
        if connection.isReadOnly { return "Connection is read-only" }
        return table.readOnlyReason
    }

    private func statusText(_ result: ResultSet) -> String {
        result.elapsed.formatted(.units(allowed: [.milliseconds], width: .narrow))
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

    /// Compact layouts keep table-scoped actions next to the table instead of allowing the
    /// navigation bar to hide Filter in its automatic overflow menu.
    private var compactTableControls: some View {
        HStack {
            Spacer(minLength: 0)
            ControlGroup {
                if isEditable {
                    rowEditingControls
                }
                filterMenu
            }
            .labelStyle(.iconOnly)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
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

    private func loadPage() async {
        guard let table = activeTable else { return }
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
            limit: pageSize,
            offset: offset
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
            if page.rows.isEmpty && offset > 0 {
                offset = 0
                await loadPage()
                return
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
