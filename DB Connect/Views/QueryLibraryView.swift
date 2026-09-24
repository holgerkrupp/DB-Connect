import SwiftUI
import SwiftData
import TipKit
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum QueryLibrarySection: String, CaseIterable, Identifiable {
    case favorites = "Favorites"
    case saved = "Saved"
    case history = "History"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .favorites: "star"
        case .saved: "bookmark"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// A small, focused home for reusable and recently-run SQL. Saved queries remain the durable,
/// monitor-friendly records they already were; favorites add snippet insertion and triggers
/// without disturbing those existing workflows.
struct QueryLibraryView: View {
    let connection: Connection
    @Bindable var draft: ConsoleDraft
    @Binding var selection: QueryLibrarySection
    @Binding var startsInSaveMode: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \QueryFavorite.title) private var allFavorites: [QueryFavorite]

    @State private var searchText = ""
    @State private var isSaving = false
    @State private var saveTitle = ""
    @State private var visibleHistoryCount = Self.historyPageSize
    @State private var queryPendingDeletion: SavedQuery?
    @State private var queryPendingRename: SavedQuery?
    @State private var renameTitle = ""
    @State private var favoritePendingDeletion: QueryFavorite?
    @State private var favoriteEditor: FavoriteEditorState?
    @State private var showsClearHistoryConfirmation = false
    @FocusState private var focusedField: Field?

    private static let historyPageSize = 8

    private enum Field {
        case search
        case saveTitle
    }

    private var trimmedSQL: String {
        draft.sql.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedSaveTitle: String {
        saveTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleFavorites: [QueryFavorite] {
        let favorites = QueryFavoriteExpander.visibleFavorites(all: allFavorites, for: connection)
        guard !searchText.isEmpty else { return favorites }
        return favorites.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.sql.localizedCaseInsensitiveContains(searchText)
                || $0.tabTrigger.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var connectionFavorites: [QueryFavorite] {
        visibleFavorites.filter { $0.scope == .connection }
    }

    private var globalFavorites: [QueryFavorite] {
        visibleFavorites.filter { $0.scope == .global }
    }

    private var savedQueries: [SavedQuery] {
        let queries = (connection.savedQueries ?? []).sorted {
            $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
        guard !searchText.isEmpty else { return queries }
        return queries.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
                || $0.sql.localizedCaseInsensitiveContains(searchText)
                || $0.database.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var historyEntries: [QueryHistoryEntry] {
        let entries = (connection.history ?? [])
            .filter { $0.database == draft.database }
            .sorted { $0.executedAt > $1.executedAt }
        guard !searchText.isEmpty else { return entries }
        return entries.filter {
            $0.sql.localizedCaseInsensitiveContains(searchText)
                || ($0.errorMessage?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                switch selection {
                case .favorites:
                    favoritesContent
                case .saved:
                    savedContent
                case .history:
                    historyContent
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(minWidth: 380, idealWidth: 460, maxWidth: 620, minHeight: 440, idealHeight: 620, maxHeight: 760)
        .onAppear {
            if startsInSaveMode {
                selection = .saved
                beginSaving()
                startsInSaveMode = false
            }
        }
        .onChange(of: startsInSaveMode) { _, requested in
            guard requested else { return }
            selection = .saved
            beginSaving()
            startsInSaveMode = false
        }
        .onChange(of: selection) { _, _ in
            searchText = ""
            visibleHistoryCount = Self.historyPageSize
            if selection == .history { isSaving = false }
        }
        .sheet(item: $favoriteEditor) { state in
            FavoriteEditorSheet(
                state: state,
                connectionName: connection.name,
                onSave: { saveFavoriteEditor($0) }
            )
        }
        .confirmationDialog(
            "Delete “\(queryPendingDeletion?.title ?? "")”?",
            isPresented: $queryPendingDeletion.isPresent(),
            titleVisibility: .visible
        ) {
            Button("Delete Query", role: .destructive) {
                if let queryPendingDeletion { delete(queryPendingDeletion) }
                queryPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { queryPendingDeletion = nil }
        } message: {
            if let queryPendingDeletion {
                Text(deleteMessage(for: queryPendingDeletion))
            }
        }
        .confirmationDialog(
            "Delete “\(favoritePendingDeletion?.title ?? "")”?",
            isPresented: $favoritePendingDeletion.isPresent(),
            titleVisibility: .visible
        ) {
            Button("Delete Favorite", role: .destructive) {
                if let favoritePendingDeletion { delete(favoritePendingDeletion) }
                favoritePendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { favoritePendingDeletion = nil }
        } message: {
            Text("This deletes the favorite only. Saved queries, monitors, and database objects are untouched.")
        }
        .alert(
            "Rename Query",
            isPresented: $queryPendingRename.isPresent()
        ) {
            TextField("Name", text: $renameTitle)
            Button("Rename") { renameQuery() }
                .disabled(renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { queryPendingRename = nil }
        }
        .confirmationDialog(
            "Clear query history?",
            isPresented: $showsClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { clearHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the history for \(databaseName). Saved queries and favorites are untouched.")
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Query Library", systemImage: "text.book.closed")
                    .font(.headline)
                Spacer()
                Button("Close", systemImage: "xmark.circle.fill") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Picker("Query Collection", selection: $selection) {
                ForEach(QueryLibrarySection.allCases) { section in
                    Label(section.rawValue, systemImage: section.symbol).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField(searchPrompt, text: $searchText)
                    .textFieldStyle(.plain)
                    .focused($focusedField, equals: .search)
                if !searchText.isEmpty {
                    Button("Clear Search", systemImage: "xmark.circle.fill") { searchText = "" }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
    }

    private var searchPrompt: String {
        switch selection {
        case .favorites: "Search favorites"
        case .saved: "Search saved queries"
        case .history: "Search history"
        }
    }

    @ViewBuilder
    private var favoritesContent: some View {
        LazyVStack(spacing: 0) {
            favoritePanel

            if connectionFavorites.isEmpty && globalFavorites.isEmpty {
                sectionHeader(title: "Favorites", count: 0)
                emptyState(
                    title: searchText.isEmpty ? "No Favorites Yet" : "No Matches",
                    detail: searchText.isEmpty
                        ? "Save a favorite for reusable snippets, tab triggers, and quick insertion."
                        : "Try another title, trigger, or SQL fragment.",
                    symbol: searchText.isEmpty ? "star" : "magnifyingglass"
                )
            } else {
                if !connectionFavorites.isEmpty {
                    sectionHeader(title: "This Connection", count: connectionFavorites.count)
                    ForEach(connectionFavorites) { favorite in
                        FavoriteLibraryRow(
                            favorite: favorite,
                            insert: { insertFavorite(favorite) },
                            load: { loadFavorite(favorite) },
                            edit: { editFavorite(favorite) },
                            delete: { favoritePendingDeletion = favorite }
                        )
                        Divider().padding(.leading, 52)
                    }
                }

                if !globalFavorites.isEmpty {
                    sectionHeader(title: "Global", count: globalFavorites.count)
                    ForEach(globalFavorites) { favorite in
                        FavoriteLibraryRow(
                            favorite: favorite,
                            insert: { insertFavorite(favorite) },
                            load: { loadFavorite(favorite) },
                            edit: { editFavorite(favorite) },
                            delete: { favoritePendingDeletion = favorite }
                        )
                        Divider().padding(.leading, 52)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var savedContent: some View {
        LazyVStack(spacing: 0) {
            savePanel

            sectionHeader(title: "Saved Queries", count: savedQueries.count)

            if savedQueries.isEmpty {
                emptyState(
                    title: searchText.isEmpty ? "No Saved Queries" : "No Matches",
                    detail: searchText.isEmpty
                        ? "Save the statement in the editor to reuse it later or attach it to a monitor."
                        : "Try another name or SQL fragment.",
                    symbol: searchText.isEmpty ? "bookmark" : "magnifyingglass"
                )
            } else {
                ForEach(savedQueries) { query in
                    SavedQueryLibraryRow(
                        query: query,
                        load: { load(query.sql) },
                        rename: {
                            renameTitle = query.title
                            queryPendingRename = query
                        },
                        delete: { queryPendingDeletion = query }
                    )
                    Divider().padding(.leading, 52)
                }
            }
        }
    }

    private var favoritePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                favoriteEditor = FavoriteEditorState(
                    favorite: nil,
                    title: "",
                    sql: trimmedSQL,
                    tabTrigger: "",
                    scope: .connection
                )
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Label("Save Current SQL as Favorite", systemImage: "star.badge.plus")
                    Spacer(minLength: 8)
                    if !trimmedSQL.isEmpty {
                        Text("Reuse with snippets and triggers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(trimmedSQL.isEmpty)

            Text("Favorites can be global or connection-scoped. Use `$DATABASE`, `$TABLE`, `$CONNECTION`, `${1:placeholder}`, and `$0` in favorite SQL. Typing a tab trigger then pressing Tab expands it directly in the editor.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    private var savePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isSaving {
                Label("Save Current Query", systemImage: "bookmark.badge.plus")
                    .font(.subheadline.weight(.semibold))

                TextField("Query name", text: $saveTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .saveTitle)
                    .onSubmit { saveCurrentQuery() }

                HStack {
                    Text("Saved to \(databaseName)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Cancel") {
                        isSaving = false
                        saveTitle = ""
                    }
                    Button("Save") { saveCurrentQuery() }
                        .buttonStyle(.borderedProminent)
                        .disabled(trimmedSaveTitle.isEmpty || trimmedSQL.isEmpty)
                }
            } else {
                Button {
                    beginSaving()
                } label: {
                    HStack {
                        Label("Save Current Query", systemImage: "bookmark.badge.plus")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(trimmedSQL.isEmpty)
            }
        }
        .padding(12)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
        .padding(.top, 12)
    }

    @ViewBuilder
    private var historyContent: some View {
        LazyVStack(spacing: 0) {
            HStack {
                sectionHeaderLabel(title: "Recent", count: historyEntries.count)
                Spacer()
                if !historyEntries.isEmpty, searchText.isEmpty {
                    Button("Clear…", role: .destructive) {
                        showsClearHistoryConfirmation = true
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if historyEntries.isEmpty {
                emptyState(
                    title: searchText.isEmpty ? "No History Yet" : "No Matches",
                    detail: searchText.isEmpty
                        ? "Queries you run in this database will appear here."
                        : "Try another SQL fragment.",
                    symbol: searchText.isEmpty ? "clock" : "magnifyingglass"
                )
            } else {
                ForEach(historyEntries.prefix(visibleHistoryCount)) { entry in
                    HistoryLibraryRow(entry: entry) { load(entry.sql) }
                    Divider().padding(.leading, 52)
                }

                if visibleHistoryCount < historyEntries.count {
                    Button {
                        visibleHistoryCount += Self.historyPageSize
                    } label: {
                        Label(
                            "Show \(min(Self.historyPageSize, historyEntries.count - visibleHistoryCount)) More",
                            systemImage: "chevron.down"
                        )
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func sectionHeader(title: String, count: Int) -> some View {
        sectionHeaderLabel(title: title, count: count)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 6)
    }

    private func sectionHeaderLabel(title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(count.formatted())
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
    }

    private func emptyState(title: String, detail: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tertiary)
            Text(title).font(.subheadline.weight(.medium))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 30)
        .padding(.vertical, 42)
    }

    private var databaseName: String {
        draft.database.isEmpty ? connection.name : draft.database
    }

    private func beginSaving() {
        guard !trimmedSQL.isEmpty else { return }
        selection = .saved
        saveTitle = ""
        isSaving = true
        Task { @MainActor in focusedField = .saveTitle }
    }

    private func saveCurrentQuery() {
        guard !trimmedSaveTitle.isEmpty, !trimmedSQL.isEmpty else { return }
        let query = SavedQuery(title: trimmedSaveTitle, sql: trimmedSQL)
        query.connection = connection
        query.database = draft.database
        modelContext.insert(query)
        try? modelContext.save()
        saveTitle = ""
        isSaving = false
    }

    private func insertFavorite(_ favorite: QueryFavorite) {
        draft.pendingFavoriteInsertion = QueryFavoriteInsertionRequest(
            sql: favorite.sql,
            title: favorite.title,
            mode: .insertAtCursor
        )
        dismiss()
    }

    private func loadFavorite(_ favorite: QueryFavorite) {
        draft.pendingFavoriteInsertion = QueryFavoriteInsertionRequest(
            sql: favorite.sql,
            title: favorite.title,
            mode: .replaceEditor
        )
        dismiss()
    }

    private func editFavorite(_ favorite: QueryFavorite) {
        favoriteEditor = FavoriteEditorState(
            favorite: favorite,
            title: favorite.title,
            sql: favorite.sql,
            tabTrigger: favorite.tabTrigger,
            scope: favorite.scope
        )
    }

    private func saveFavoriteEditor(_ state: FavoriteEditorState) {
        let title = state.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let sql = state.sql.trimmingCharacters(in: .whitespacesAndNewlines)
        let trigger = state.tabTrigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !sql.isEmpty else { return }

        let scopedConnection: Connection? = state.scope == .connection ? connection : nil
        if let favorite = state.favorite {
            favorite.update(title: title, sql: sql, tabTrigger: trigger, connection: scopedConnection)
        } else {
            let favorite = QueryFavorite(title: title, sql: sql, tabTrigger: trigger)
            favorite.connection = scopedConnection
            modelContext.insert(favorite)
        }
        try? modelContext.save()
        if !trigger.isEmpty {
            FavoriteTabTriggerTip().invalidate(reason: .actionPerformed)
        }
    }

    private func load(_ sql: String) {
        draft.sql = sql
        dismiss()
    }

    private func renameQuery() {
        guard let queryPendingRename else { return }
        let title = renameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        queryPendingRename.title = title
        try? modelContext.save()
        self.queryPendingRename = nil
    }

    private func delete(_ query: SavedQuery) {
        modelContext.delete(query)
        try? modelContext.save()
    }

    private func delete(_ favorite: QueryFavorite) {
        modelContext.delete(favorite)
        try? modelContext.save()
    }

    private func deleteMessage(for query: SavedQuery) -> String {
        let count = query.monitors?.count ?? 0
        return count == 0
            ? "This deletes the saved query. The database it queried is untouched."
            : "This also deletes \(count) monitor\(count == 1 ? "" : "s") that watch this query."
    }

    private func clearHistory() {
        for entry in (connection.history ?? []).filter({ $0.database == draft.database }) {
            modelContext.delete(entry)
        }
        try? modelContext.save()
    }
}

private struct FavoriteLibraryRow: View {
    let favorite: QueryFavorite
    let insert: () -> Void
    let load: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: insert) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: favorite.scope == .global ? "star.fill" : "star.bubble.fill")
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.yellow)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(favorite.title.isEmpty ? "Untitled Favorite" : favorite.title)
                                .font(.body.weight(.medium))
                                .lineLimit(1)
                            if !favorite.tabTrigger.isEmpty {
                                Text(favorite.tabTrigger)
                                    .font(.caption2.monospaced())
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.quaternary.opacity(0.5), in: Capsule())
                            }
                        }
                        Text(favorite.sql.compactSQLPreview)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack(spacing: 5) {
                            Text(favorite.scope.title)
                            Text("·")
                            Text(favorite.updatedAt, format: .dateTime.year().month(.abbreviated).day())
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu("Favorite Actions", systemImage: "ellipsis.circle") {
                Button("Insert into Editor", systemImage: "arrow.down.doc", action: insert)
                Button("Load into Editor", systemImage: "doc.text", action: load)
                Divider()
                Button("Edit…", systemImage: "pencil", action: edit)
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Insert into Editor", systemImage: "arrow.down.doc", action: insert)
            Button("Load into Editor", systemImage: "doc.text", action: load)
            Button("Edit…", systemImage: "pencil", action: edit)
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
        }
    }
}

private struct SavedQueryLibraryRow: View {
    let query: SavedQuery
    let load: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: load) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "bookmark.fill")
                        .frame(width: 24, height: 24)
                        .foregroundStyle(.tint)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(query.title.isEmpty ? "Untitled" : query.title)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Text(query.sql.compactSQLPreview)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        HStack(spacing: 5) {
                            if !query.database.isEmpty {
                                Text(query.database)
                                Text("·")
                            }
                            Text(query.createdAt, format: .dateTime.year().month(.abbreviated).day())
                        }
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu("Query Actions", systemImage: "ellipsis.circle") {
                Button("Rename…", systemImage: "pencil", action: rename)
                Divider()
                Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
            }
            .labelStyle(.iconOnly)
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Load Query", systemImage: "arrow.down.doc", action: load)
            Button("Rename…", systemImage: "pencil", action: rename)
            Divider()
            Button("Delete…", systemImage: "trash", role: .destructive, action: delete)
        }
    }
}

private struct HistoryLibraryRow: View {
    let entry: QueryHistoryEntry
    let load: () -> Void

    var body: some View {
        Button(action: load) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: entry.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .frame(width: 24, height: 24)
                    .foregroundStyle(entry.succeeded ? .green : .orange)

                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.sql.compactSQLPreview)
                        .font(.caption.monospaced())
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    HStack(spacing: 5) {
                        Text(entry.executedAt, style: .relative)
                        Text("·")
                        Text(entry.summary)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.left")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 3)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contextMenu {
            Button("Load in Editor", systemImage: "arrow.up.left", action: load)
            Button("Copy SQL", systemImage: "document.on.document") {
                #if os(macOS)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.sql, forType: .string)
                #else
                UIPasteboard.general.string = entry.sql
                #endif
            }
        }
    }
}

private struct FavoriteEditorSheet: View {
    let state: FavoriteEditorState
    let connectionName: String
    let onSave: (FavoriteEditorState) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var sql: String
    @State private var tabTrigger: String
    @State private var scope: QueryFavoriteScope

    init(
        state: FavoriteEditorState,
        connectionName: String,
        onSave: @escaping (FavoriteEditorState) -> Void
    ) {
        self.state = state
        self.connectionName = connectionName
        self.onSave = onSave
        _title = State(initialValue: state.title)
        _sql = State(initialValue: state.sql)
        _tabTrigger = State(initialValue: state.tabTrigger)
        _scope = State(initialValue: state.scope)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Favorite") {
                    TextField("Title", text: $title)
                    Picker("Scope", selection: $scope) {
                        ForEach(QueryFavoriteScope.allCases) { scope in
                            Text(scope == .connection ? "\(scope.title) (\(connectionName))" : scope.title)
                                .tag(scope)
                        }
                    }
                    TextField("Tab trigger", text: $tabTrigger)
                        .autocorrectionDisabled()
                    Text("Type the trigger in the SQL editor and press Tab to expand this favorite.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("SQL") {
                    TextEditor(text: $sql)
                        .font(.body.monospaced())
                        .frame(minHeight: 240)
                    Text("Dynamic tokens: `$DATABASE`, `$TABLE`, `$CONNECTION`, `$DATE`, `$TIME`. Snippet tokens: `${1:columns}` and `$0`.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(state.favorite == nil ? "New Favorite" : "Edit Favorite")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(FavoriteEditorState(
                            favorite: state.favorite,
                            title: title,
                            sql: sql,
                            tabTrigger: tabTrigger,
                            scope: scope
                        ))
                        dismiss()
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 520)
        #endif
    }
}

fileprivate struct FavoriteEditorState: Identifiable {
    let id = UUID()
    var favorite: QueryFavorite?
    var title: String
    var sql: String
    var tabTrigger: String
    var scope: QueryFavoriteScope
}

private extension String {
    var compactSQLPreview: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
