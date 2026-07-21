import SwiftUI
import SwiftData

/// Ad-hoc SQL editor with results below and access to the connection's saved queries.
struct SQLConsoleView: View {
    let session: any DatabaseSession
    let connection: Connection
    /// Query text, results and cached schema, owned by the parent so they survive a switch to
    /// the table browser and back.
    @Bindable var draft: ConsoleDraft

    @Environment(\.modelContext) private var modelContext

    @State private var isRunning = false
    @State private var showsSavePrompt = false
    @State private var saveTitle = ""
    @State private var queryPendingDeletion: SavedQuery?

    @AppStorage(AppSettings.Key.identifierCorrection)
    private var correctionRaw = AppSettings.CorrectionMode.caseOnly.rawValue
    @AppStorage(AppSettings.Key.recordHistory) private var recordHistory = true

    private var correctionMode: AppSettings.CorrectionMode {
        AppSettings.CorrectionMode(rawValue: correctionRaw) ?? .caseOnly
    }

    var body: some View {
        VSplitLayout {
            VStack(spacing: 0) {
                editor
                suggestionBar
            }
        } bottom: {
            results
        }
        .task { await loadSchema() }
        .toolbar {
            ToolbarItemGroup {
                historyMenu
                savedQueriesMenu
                Button("Save Query", systemImage: "bookmark") {
                    saveTitle = ""
                    showsSavePrompt = true
                }
                .disabled(trimmedSQL.isEmpty)
                // The ⌘↩ shortcut lives on the Query menu item instead — binding it in both
                // places registers it twice and the menu item stops showing its key equivalent.
                Button("Run", systemImage: "play.fill") { run() }
                    .disabled(trimmedSQL.isEmpty || isRunning)
            }
        }
        .focusedSceneValue(\.consoleActions, ConsoleActions(
            run: { run() },
            canRun: !trimmedSQL.isEmpty && !isRunning,
            saveQuery: {
                saveTitle = ""
                showsSavePrompt = true
            },
            canSave: !trimmedSQL.isEmpty,
            clearEditor: {
                draft.sql = ""
                draft.correctionNotice = nil
            }
        ))
        .alert("Save Query", isPresented: $showsSavePrompt) {
            TextField("Title", text: $saveTitle)
            Button("Save") { saveQuery() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved queries are stored with this connection and will sync to your other devices.")
        }
        .confirmationDialog(
            "Delete “\(queryPendingDeletion?.title ?? "")”?",
            isPresented: .constant(queryPendingDeletion != nil),
            titleVisibility: .visible
        ) {
            Button("Delete Query", role: .destructive) {
                if let queryPendingDeletion { deleteQuery(queryPendingDeletion) }
                queryPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { queryPendingDeletion = nil }
        } message: {
            if let queryPendingDeletion {
                Text(deleteQueryMessage(for: queryPendingDeletion))
            }
        }
    }

    private var trimmedSQL: String {
        draft.sql.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var editor: some View {
        SQLEditorView(text: $draft.sql, tables: draft.schema)
    }

    private var identifierIssues: [SQLIdentifierCorrection.Issue] {
        SQLIdentifierCorrection.issues(in: draft.sql, tables: draft.schema)
    }

    /// Names the editor flagged that running will *not* fix on its own, each offered as a
    /// one-click fix. Auto-applied corrections are reported separately, after the run.
    @ViewBuilder
    private var suggestionBar: some View {
        let pending = identifierIssues.filter { !correctionMode.autoApplies($0.confidence) }
        if !pending.isEmpty || draft.correctionNotice != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let correctionNotice = draft.correctionNotice {
                    Label(correctionNotice, systemImage: "wand.and.sparkles")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(pending) { issue in
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(issue.confidence == .caseOnly ? .orange : .red)
                        Text(issue.explanation).font(.caption)
                        Button("Fix") { apply([issue]) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                        Spacer()
                    }
                }
                if pending.count > 1 {
                    Button("Fix All") { apply(pending) }
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary.opacity(0.2))
        }
    }

    private func apply(_ issues: [SQLIdentifierCorrection.Issue]) {
        draft.sql = SQLIdentifierCorrection.applying(issues, to: draft.sql)
    }

    /// One line: the statement, flattened and shortened, followed by how it turned out.
    private func menuTitle(for entry: QueryHistoryEntry) -> String {
        let flattened = entry.sql
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        let collapsed = flattened.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let shortened = collapsed.count > 60 ? collapsed.prefix(59) + "…" : collapsed[...]
        return "\(entry.succeeded ? "" : "⚠︎ ")\(shortened)  —  \(entry.summary)"
    }

    private var historyMenu: some View {
        Menu("History", systemImage: "clock.arrow.circlepath") {
            let entries = (connection.history ?? [])
                .filter { $0.database == draft.database }
                .sorted { $0.executedAt > $1.executedAt }

            if entries.isEmpty {
                Text("No history yet")
            }
            ForEach(entries.prefix(25)) { entry in
                // A menu item on macOS renders its title only — a second Text or an icon in a
                // Label is dropped — so the outcome has to live in the title string itself.
                Button(menuTitle(for: entry)) { draft.sql = entry.sql }
            }
            if !entries.isEmpty {
                Divider()
                Button("Clear History", systemImage: "trash", role: .destructive) {
                    for entry in entries { modelContext.delete(entry) }
                    try? modelContext.save()
                }
            }
        }
    }

    /// Loads table and column names for autocomplete. A failure here is silent on purpose:
    /// completion is an assist, and the console must stay usable on a connection whose account
    /// cannot read the catalog.
    ///
    /// Describing every table costs one query each, so the result is cached on the draft and
    /// reloaded only when the database changes — not on every switch back from the browser.
    private func loadSchema() async {
        let database = await session.currentDatabase ?? connection.database
        guard draft.needsSchema(for: database) else { return }
        guard let tables = try? await session.tables() else { return }
        var described: [TableDescriptor] = []
        for table in tables {
            if table.columns.isEmpty {
                described.append((try? await session.describe(table: table.name, schema: table.schema)) ?? table)
            } else {
                described.append(table)
            }
        }
        draft.setSchema(described, for: database)
    }

    @ViewBuilder
    private var results: some View {
        if isRunning {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = draft.errorMessage {
            ContentUnavailableView {
                Label("Query Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage).font(.body.monospaced())
            }
        } else if let executionSummary = draft.executionSummary {
            ContentUnavailableView {
                Label(executionSummary, systemImage: "checkmark.circle")
            }
        } else if let result = draft.result {
            VStack(spacing: 0) {
                if result.hasMore {
                    // The driver stopped at the safety cap; say so rather than quietly showing
                    // a partial answer as if it were complete.
                    Label(
                        "Showing the first \(QueryLimits.maxRows.formatted()) rows. Add a LIMIT to see a specific part of the result.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.1))
                }
                ResultTableView(
                    columns: result.columns,
                    rows: sortedRows(for: result),
                    sortOrder: $draft.sortOrder
                )
            }
        } else {
            ContentUnavailableView(
                "Run a Query",
                systemImage: "play.circle",
                description: Text("Results appear here. ⌘↩ runs the query.")
            )
        }
    }

    private var savedQueriesMenu: some View {
        Menu("Saved Queries", systemImage: "book") {
            let queries = (connection.savedQueries ?? []).sorted { $0.createdAt < $1.createdAt }
            if queries.isEmpty {
                Text("No saved queries")
            }
            // Primary action stays a single click: pick a query, get its SQL in the editor.
            ForEach(queries) { query in
                Button(query.title) { draft.sql = query.sql }
            }
            if !queries.isEmpty {
                Divider()
                Menu("Delete", systemImage: "trash") {
                    ForEach(queries) { query in
                        Button(query.title.isEmpty ? "Untitled" : query.title, role: .destructive) {
                            queryPendingDeletion = query
                        }
                    }
                }
            }
        }
    }

    /// How many monitors would go with a query if it were deleted — the cascade removes them,
    /// so the confirmation says so rather than letting it happen silently.
    private func deleteQueryMessage(for query: SavedQuery) -> String {
        let count = query.monitors?.count ?? 0
        return count == 0
            ? "This deletes the saved query. The database it queried is untouched."
            : "This also deletes \(count) monitor\(count == 1 ? "" : "s") that watch this query."
    }

    private func deleteQuery(_ query: SavedQuery) {
        modelContext.delete(query)
        try? modelContext.save()
    }

    /// SELECT-shaped statements go through `query` for a grid; everything else through
    /// `execute` for an affected-row count.
    private var isReadStatement: Bool {
        let head = trimmedSQL.prefix(10).uppercased()
        return ["SELECT", "PRAGMA", "WITH", "EXPLAIN"].contains { head.hasPrefix($0) }
    }

    private func run() {
        draft.correctionNotice = nil

        // Fix identifiers the settings allow us to fix, and say what changed. The corrected SQL
        // is written back into the editor rather than only being sent — running something the
        // user cannot see would make the next failure impossible to reason about.
        let fixable = identifierIssues.filter { correctionMode.autoApplies($0.confidence) }
        if !fixable.isEmpty {
            draft.sql = SQLIdentifierCorrection.applying(fixable, to: draft.sql)
            let changes = fixable.map { "\($0.written) → \($0.suggestion)" }.joined(separator: ", ")
            draft.correctionNotice = "Corrected \(changes)"
        }

        let executedSQL = trimmedSQL
        let statement = Statement(executedSQL)
        isRunning = true
        draft.errorMessage = nil
        draft.executionSummary = nil
        draft.result = nil

        Task {
            let started = ContinuousClock.now
            var rowCount: Int?
            var failure: String?

            do {
                if isReadStatement {
                    let resultSet = try await session.query(statement)
                    draft.result = resultSet
                    rowCount = resultSet.rows.count
                } else if connection.isReadOnly {
                    throw DatabaseError.readOnly(reason: "This connection is read-only.")
                } else {
                    let outcome = try await session.execute(statement)
                    rowCount = outcome.affectedRows
                    draft.executionSummary = "\(outcome.affectedRows) row\(outcome.affectedRows == 1 ? "" : "s") affected"
                }
            } catch {
                failure = error.localizedDescription
                draft.errorMessage = failure
            }
            isRunning = false

            if recordHistory {
                let elapsed = Double(started.duration(to: .now).components.seconds)
                    + Double(started.duration(to: .now).components.attoseconds) / 1e18
                QueryHistoryEntry.record(
                    sql: executedSQL,
                    database: draft.database,
                    succeeded: failure == nil,
                    rowCount: failure == nil ? rowCount : nil,
                    errorMessage: failure,
                    duration: elapsed,
                    connection: connection,
                    in: modelContext
                )
            }
        }
    }

    /// Sorts the returned page in memory. If the result was truncated at the row cap this is
    /// only a sort of the visible window — the truncation banner above the grid covers that.
    private func sortedRows(for result: ResultSet) -> [[SQLValue]] {
        guard let sort = draft.sortOrder.first,
              let index = result.columns.firstIndex(where: { $0.name == sort.column })
        else { return result.rows }
        return result.rows.sorted { lhs, rhs in
            let l = lhs.indices.contains(index) ? lhs[index] : .null
            let r = rhs.indices.contains(index) ? rhs[index] : .null
            let outcome = l.compare(to: r)
            return sort.order == .forward
                ? outcome == .orderedAscending
                : outcome == .orderedDescending
        }
    }

    private func saveQuery() {
        guard !saveTitle.isEmpty, !trimmedSQL.isEmpty else { return }
        let query = SavedQuery(title: saveTitle, sql: trimmedSQL)
        query.connection = connection
        // Record which database the query ran against, so a monitor on another device can select
        // it before running — a server-level connection has no database of its own to fall back on.
        query.database = draft.database
        modelContext.insert(query)
        try? modelContext.save()
    }
}

/// `VSplitView` exists only on macOS; iOS gets a fixed vertical split.
/// Lower bounds for the two panes. A separate type because a generic view cannot hold static
/// stored properties.
private enum SplitMetrics {
    static let minEditor = 80.0
    static let minResults = 120.0
}

struct VSplitLayout<Top: View, Bottom: View>: View {
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom

    init(@ViewBuilder top: @escaping () -> Top, @ViewBuilder bottom: @escaping () -> Bottom) {
        self.top = top
        self.bottom = bottom
    }

    /// Editor height in points, remembered across launches and mode switches.
    ///
    /// `VSplitView` was used here before, but it splits its panes evenly and ignores an ideal
    /// height, which left the editor taking half the window when most statements are a few
    /// lines long. An explicit divider also means the position survives leaving the console,
    /// which `VSplitView` could not.
    @AppStorage("console.editorHeight") private var editorHeight = 140.0
    @State private var dragStartHeight: Double?

    var body: some View {
        GeometryReader { proxy in
            let maxEditor = max(SplitMetrics.minEditor, proxy.size.height - SplitMetrics.minResults)
            let height = min(max(editorHeight, SplitMetrics.minEditor), maxEditor)

            VStack(spacing: 0) {
                top().frame(height: height)
                divider(maxEditor: maxEditor)
                bottom().frame(maxHeight: .infinity)
            }
        }
    }

    private func divider(maxEditor: Double) -> some View {
        Divider()
            // A one-pixel line is too small a drag target, so widen the hit area without
            // changing how the divider looks.
            .padding(.vertical, 3)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartHeight ?? editorHeight
                        dragStartHeight = start
                        editorHeight = min(max(start + value.translation.height, SplitMetrics.minEditor), maxEditor)
                    }
                    .onEnded { _ in dragStartHeight = nil }
            )
            #if os(macOS)
            .onHover { inside in
                if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            #endif
    }
}
