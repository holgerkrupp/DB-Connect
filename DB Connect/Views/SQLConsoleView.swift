import SwiftUI
import SwiftData

/// Ad-hoc SQL editor with results below and access to the connection's saved queries.
struct SQLConsoleView: View {
    let session: any DatabaseSession
    let connection: Connection
    /// Query text, results and cached schema, owned by the parent so they survive a switch to
    /// the table browser and back.
    @Bindable var draft: ConsoleDraft
    @Binding var workspaceMode: WorkspaceMode
    var showsWorkspaceModePicker = false

    @Environment(\.modelContext) private var modelContext
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var isRunning = false
    @State private var showsQueryLibrary = false
    @State private var queryLibrarySection = QueryLibrarySection.saved
    @State private var startsQuerySave = false

    @AppStorage(AppSettings.Key.identifierCorrection)
    private var correctionRaw = AppSettings.CorrectionMode.caseOnly.rawValue
    @AppStorage(AppSettings.Key.recordHistory) private var recordHistory = true

    private var correctionMode: AppSettings.CorrectionMode {
        AppSettings.CorrectionMode(rawValue: correctionRaw) ?? .caseOnly
    }

    var body: some View {
        VStack(spacing: 0) {
            if horizontalSizeClass == .compact, showsWorkspaceModePicker {
                HStack {
                    Spacer(minLength: 0)
                    WorkspaceModePicker(selection: $workspaceMode, compact: true)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }

            VSplitLayout {
                VStack(spacing: 0) {
                    editor
                    suggestionBar
                }
            } bottom: {
                results
            }
        }
        .task { await loadSchema() }
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button("Queries", systemImage: "text.book.closed") {
                    startsQuerySave = false
                    showsQueryLibrary = true
                }
                .help("Saved queries and recent history")
            }
            ToolbarItem(placement: .primaryAction) {
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
                queryLibrarySection = .saved
                startsQuerySave = true
                showsQueryLibrary = true
            },
            canSave: !trimmedSQL.isEmpty,
            clearEditor: {
                draft.sql = ""
                draft.correctionNotice = nil
            }
        ))
        .popover(isPresented: $showsQueryLibrary, arrowEdge: .top) {
            QueryLibraryView(
                connection: connection,
                draft: draft,
                selection: $queryLibrarySection,
                startsInSaveMode: $startsQuerySave
            )
            .presentationCompactAdaptation(.sheet)
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
            DatabaseLoadingView("Running query…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ContentUnavailableView {
                Text("Run a Query")
            } description: {
                emptyResultDescription
            } actions: {
                Button("Run Query", systemImage: "play.fill") { run() }
                    .buttonStyle(.glassProminent)
                    .disabled(trimmedSQL.isEmpty || isRunning)
            }
        }
    }

    @ViewBuilder
    private var emptyResultDescription: some View {
        #if os(macOS)
        Text("Results appear here. Press \(Image(systemName: "command")) \(Image(systemName: "return")) to run the query.")
            .accessibilityLabel("Results appear here. Press Command Return to run the query.")
        #else
        Text("Results appear here after you run the query.")
        #endif
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        GeometryReader { proxy in
            let maxEditor = max(SplitMetrics.minEditor, proxy.size.height - SplitMetrics.minResults)
            let height = min(max(editorHeight, SplitMetrics.minEditor), maxEditor)

            VStack(spacing: 0) {
                top().frame(height: height)
                if horizontalSizeClass == .compact {
                    Divider()
                } else {
                    divider(maxEditor: maxEditor)
                }
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
