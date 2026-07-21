import SwiftUI
import SwiftData
#if os(macOS)
import AppKit
#else
import UIKit
#endif

enum QueryLibrarySection: String, CaseIterable, Identifiable {
    case saved = "Saved"
    case history = "History"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .saved: "bookmark"
        case .history: "clock.arrow.circlepath"
        }
    }
}

/// A small, focused home for reusable and recently-run SQL. Unlike a menu, this can show enough
/// context to distinguish similar statements and keeps management actions attached to each row.
struct QueryLibraryView: View {
    let connection: Connection
    @Bindable var draft: ConsoleDraft
    @Binding var selection: QueryLibrarySection
    @Binding var startsInSaveMode: Bool

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    @State private var searchText = ""
    @State private var isSaving = false
    @State private var saveTitle = ""
    @State private var visibleHistoryCount = Self.historyPageSize
    @State private var queryPendingDeletion: SavedQuery?
    @State private var queryPendingRename: SavedQuery?
    @State private var renameTitle = ""
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
                case .saved:
                    savedContent
                case .history:
                    historyContent
                }
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .frame(minWidth: 360, idealWidth: 420, maxWidth: 520, minHeight: 420, idealHeight: 540, maxHeight: 680)
        .onAppear {
            if startsInSaveMode {
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
            Text("This removes the history for \(databaseName). Saved queries are untouched.")
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Label("Queries", systemImage: "text.book.closed")
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
        selection == .saved ? "Search saved queries" : "Search history"
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
                        ? "Save the statement in the editor to reuse it later."
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

private extension String {
    var compactSQLPreview: String {
        split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
