import SwiftUI

/// Sidebar list of the open database's tables and views.
///
/// Doubles as a schema reference: each entry expands to its columns with types and key markers,
/// which is as useful while writing SQL as it is while browsing rows.
struct TableListView: View {
    let tables: [TableDescriptor]
    @Binding var selection: TableDescriptor?

    /// Databases on this server, and which one is open. Empty for drivers with no such concept
    /// (SQLite), where the selector is hidden entirely.
    var databases: [String] = []
    @Binding var activeDatabase: String?
    var isSwitchingDatabase = false
    /// What the connected account may do — drives which actions are offered, not just enabled.
    var schemaAdmin: SchemaAdminCapability = .none
    var onNewTable: () -> Void = {}
    var onNewDatabase: () -> Void = {}

    @State private var search = ""
    @State private var expanded: Set<String> = []

    private var filtered: [TableDescriptor] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return tables }
        // Match on column names too, so "email" finds the table that has an email column.
        return tables.filter { table in
            table.name.localizedCaseInsensitiveContains(term)
                || table.columns.contains { $0.name.localizedCaseInsensitiveContains(term) }
        }
    }

    private var groups: [(title: String, tables: [TableDescriptor])] {
        let tables = filtered.filter { $0.kind == .table }
        let views = filtered.filter { $0.kind == .view }
        return [("Tables", tables), ("Views", views)].filter { !$0.tables.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The database selector sits above its own tables, where the relationship is
            // obvious, rather than in the window toolbar far from the list it governs.
            if !databases.isEmpty {
                databaseBar
                Divider()
            }

            // An inline field rather than `.searchable`: the row grid already owns the window's
            // search field, and two searchables in one window fight over that one slot.
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Filter tables", text: $search)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                if !search.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") { search = "" }
                        .buttonStyle(.borderless)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            List(selection: $selection) {
                ForEach(groups, id: \.title) { group in
                    Section("\(group.title) (\(group.tables.count))") {
                        ForEach(group.tables) { table in
                            row(for: table)
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView(
                        tables.isEmpty ? "No Tables" : "No Matches",
                        systemImage: "tablecells",
                        description: Text(
                            tables.isEmpty
                                ? "This database contains no tables."
                                : "No table or column matches “\(search)”."
                        )
                    )
                }
            }
        }
        .frame(maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            newTableBar
        }
    }

    private var databaseBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "cylinder.split.1x2")
                .foregroundStyle(.secondary)
                .font(.caption)

            Picker("Database", selection: $activeDatabase) {
                ForEach(databases, id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            }
            .labelsHidden()
            .disabled(isSwitchingDatabase)

            if isSwitchingDatabase {
                ProgressView().controlSize(.small)
            } else if schemaAdmin.canCreateDatabase {
                Button("New Database", systemImage: "plus", action: onNewDatabase)
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .help("Create a database on this server")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Kept out of the toolbar: creating a table acts on the database shown in this column, and
    /// a button beside that list says so more clearly than one in the window chrome.
    @ViewBuilder
    private var newTableBar: some View {
        if schemaAdmin.canCreateTable {
            Button(action: onNewTable) {
                Label("New Table", systemImage: "plus")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // Without this the button's hit area is only the text, and the empty stretch
                    // to its right looks clickable but is not.
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .bottomBar()
        }
    }

    @ViewBuilder
    private func row(for table: TableDescriptor) -> some View {
        DisclosureGroup(isExpanded: expansionBinding(for: table)) {
            ForEach(table.columns) { column in
                HStack(spacing: 6) {
                    Image(systemName: column.isPrimaryKey ? "key.fill" : "circle.dotted")
                        .font(.caption2)
                        .foregroundStyle(column.isPrimaryKey ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                    Text(column.name).font(.callout)
                    Spacer(minLength: 8)
                    Text(column.declaredType)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Columns are reference material, not navigation targets.
                .selectionDisabled()
            }
        } label: {
            Label {
                Text(table.name).lineLimit(1)
            } icon: {
                Image(systemName: table.kind == .view ? "eye" : "tablecells")
            }
            .badge(table.columns.count)
            .help(table.readOnlyReason ?? table.qualifiedName)
            .tag(table)
        }
    }

    /// Searching expands matches automatically so the matching column is visible, but a manual
    /// toggle still wins while the search stands.
    private func expansionBinding(for table: TableDescriptor) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(table.id) },
            set: { isExpanded in
                if isExpanded { expanded.insert(table.id) } else { expanded.remove(table.id) }
            }
        )
    }
}
