import SwiftUI
import SwiftData

/// Ad-hoc SQL editor with results below and access to the connection's saved queries.
struct SQLConsoleView: View {
    let session: any DatabaseSession
    let connection: Connection

    @Environment(\.modelContext) private var modelContext

    @State private var sql = ""
    @State private var result: ResultSet?
    @State private var executionSummary: String?
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var showsSavePrompt = false
    @State private var saveTitle = ""

    var body: some View {
        VSplitLayout {
            editor
        } bottom: {
            results
        }
        .toolbar {
            ToolbarItemGroup {
                savedQueriesMenu
                Button("Save Query", systemImage: "bookmark") {
                    saveTitle = ""
                    showsSavePrompt = true
                }
                .disabled(trimmedSQL.isEmpty)
                Button("Run", systemImage: "play.fill") { run() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(trimmedSQL.isEmpty || isRunning)
            }
        }
        .alert("Save Query", isPresented: $showsSavePrompt) {
            TextField("Title", text: $saveTitle)
            Button("Save") { saveQuery() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved queries are stored with this connection and will sync to your other devices.")
        }
    }

    private var trimmedSQL: String {
        sql.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var editor: some View {
        TextEditor(text: $sql)
            .font(.body.monospaced())
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(.quaternary.opacity(0.25))
            .overlay(alignment: .topLeading) {
                if sql.isEmpty {
                    Text("SELECT * FROM …")
                        .font(.body.monospaced())
                        .foregroundStyle(.tertiary)
                        .padding(.top, 12)
                        .padding(.leading, 9)
                        .allowsHitTesting(false)
                }
            }
    }

    @ViewBuilder
    private var results: some View {
        if isRunning {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage {
            ContentUnavailableView {
                Label("Query Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(errorMessage).font(.body.monospaced())
            }
        } else if let executionSummary {
            ContentUnavailableView {
                Label(executionSummary, systemImage: "checkmark.circle")
            }
        } else if let result {
            ResultGridView(columns: result.columns, rows: result.rows, hasMore: false)
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
            ForEach(queries) { query in
                Button(query.title) { sql = query.sql }
            }
        }
    }

    /// SELECT-shaped statements go through `query` for a grid; everything else through
    /// `execute` for an affected-row count.
    private var isReadStatement: Bool {
        let head = trimmedSQL.prefix(10).uppercased()
        return ["SELECT", "PRAGMA", "WITH", "EXPLAIN"].contains { head.hasPrefix($0) }
    }

    private func run() {
        let statement = Statement(trimmedSQL)
        isRunning = true
        errorMessage = nil
        executionSummary = nil
        result = nil

        Task {
            do {
                if isReadStatement {
                    result = try await session.query(statement)
                } else if connection.isReadOnly {
                    throw DatabaseError.readOnly(reason: "This connection is read-only.")
                } else {
                    let outcome = try await session.execute(statement)
                    executionSummary = "\(outcome.affectedRows) row\(outcome.affectedRows == 1 ? "" : "s") affected"
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isRunning = false
        }
    }

    private func saveQuery() {
        guard !saveTitle.isEmpty, !trimmedSQL.isEmpty else { return }
        let query = SavedQuery(title: saveTitle, sql: trimmedSQL)
        query.connection = connection
        modelContext.insert(query)
        try? modelContext.save()
    }
}

/// `VSplitView` exists only on macOS; iOS gets a fixed vertical split.
struct VSplitLayout<Top: View, Bottom: View>: View {
    @ViewBuilder let top: () -> Top
    @ViewBuilder let bottom: () -> Bottom

    init(@ViewBuilder top: @escaping () -> Top, @ViewBuilder bottom: @escaping () -> Bottom) {
        self.top = top
        self.bottom = bottom
    }

    var body: some View {
        #if os(macOS)
        VSplitView {
            top().frame(minHeight: 80)
            bottom().frame(minHeight: 120)
        }
        #else
        GeometryReader { proxy in
            VStack(spacing: 0) {
                top().frame(height: proxy.size.height * 0.35)
                Divider()
                bottom()
            }
        }
        #endif
    }
}
