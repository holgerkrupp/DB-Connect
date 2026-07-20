import SwiftUI

/// Table picker + paged result grid for one open session.
struct TableBrowserView: View {
    let session: any DatabaseSession
    let connection: Connection
    let tables: [TableDescriptor]
    @Binding var selectedTable: TableDescriptor?

    @State private var result: ResultSet?
    @State private var rows: [[SQLValue]] = []
    @State private var request: RowRequest?
    @State private var isLoading = false
    @State private var errorMessage: String?

    // Editing state. Changes accumulate here and reach the database only on Apply.
    @State private var pending: [RowMutation] = []
    @State private var editingRow: EditingRow?
    @State private var showsReview = false
    @State private var previewStatements: [String] = []
    @State private var commitError: String?

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
                Divider()
                content
            }
        }
        .task(id: selectedTable?.id) { await loadFirstPage() }
        .sheet(item: $editingRow) { editing in
            if let table = selectedTable {
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
        .alert("Could Not Apply Changes", isPresented: .constant(commitError != nil)) {
            Button("OK") { commitError = nil }
        } message: {
            Text(commitError ?? "")
        }
        .toolbar {
            if isEditable {
                ToolbarItemGroup {
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
            }
        }
    }

    /// Editing needs three things to line up: the connection isn't read-only, the driver can
    /// write, and the table has a key we can target.
    private var isEditable: Bool {
        guard !connection.isReadOnly, session.capabilities.canEditRows else { return false }
        return selectedTable?.isEditable == true
    }

    private var dirtyRowIndices: Set<Int> {
        guard let table = selectedTable else { return [] }
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
        guard let table = selectedTable else { return }
        do {
            previewStatements = try session.preview(pending, to: table)
            showsReview = true
        } catch {
            commitError = error.localizedDescription
        }
    }

    private func applyPending() async {
        guard let table = selectedTable else { return }
        do {
            _ = try await session.apply(pending, to: table)
            pending.removeAll()
            showsReview = false
            await loadFirstPage()
        } catch {
            showsReview = false
            commitError = error.localizedDescription
        }
    }

    private var header: some View {
        HStack {
            Picker("Table", selection: $selectedTable) {
                ForEach(tables) { table in
                    Label(table.name, systemImage: table.kind == .view ? "eye" : "tablecells")
                        .tag(Optional(table))
                }
            }
            .frame(maxWidth: 320, alignment: .leading)

            if let table = selectedTable, let reason = readOnlyReason(for: table) {
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
                Button("Retry") { Task { await loadFirstPage() } }
            }
        } else if let result {
            ResultGridView(
                columns: result.columns,
                rows: rows,
                hasMore: result.hasMore,
                loadMore: { Task { await loadNextPage() } },
                onSelectRow: isEditable ? { index in
                    editingRow = EditingRow(values: rowDictionary(at: index), isInsert: false)
                } : nil,
                dirtyRows: dirtyRowIndices
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
        let count = "\(rows.count)\(result.hasMore ? "+" : "") rows"
        let ms = result.elapsed.formatted(.units(allowed: [.milliseconds], width: .narrow))
        return "\(count) · \(ms)"
    }

    private func loadFirstPage() async {
        guard let table = selectedTable else { return }
        isLoading = true
        errorMessage = nil
        result = nil
        rows = []

        let firstRequest = RowRequest(table: table.name, schema: table.schema)
        do {
            let page = try await session.fetch(firstRequest)
            request = firstRequest
            result = page
            rows = page.rows
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadNextPage() async {
        guard let current = request, result?.hasMore == true, !isLoading else { return }
        isLoading = true
        let next = current.nextPage()
        do {
            let page = try await session.fetch(next)
            request = next
            result = page
            rows.append(contentsOf: page.rows)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
