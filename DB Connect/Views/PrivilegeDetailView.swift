import SwiftUI

/// The right-hand side of the account manager: a tabbed editor for one account's privileges.
///
/// It loads the account's current grants, lets the user toggle privileges at global and per-schema
/// scope, and on Apply issues only the `GRANT`/`REVOKE` needed to reach the edited state — never a
/// blanket rewrite. Unchanged scopes are left completely alone.
struct PrivilegeDetailView: View {
    let session: any DatabaseSession
    let user: DatabaseUser
    let databases: [String]
    let catalog: [MySQLPrivilege]
    let onDropped: () -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case general = "General"
        case global = "Global Privileges"
        case schema = "Schema Privileges"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .global

    // Server truth, loaded from SHOW GRANTS.
    @State private var current = AccountGrants()
    @State private var rawGrants: [String] = []

    // The edited copy the checkboxes bind to.
    @State private var editedGlobal: Set<String> = []
    @State private var editedGlobalGO = false
    @State private var editedSchema: [String: Set<String>] = [:]
    @State private var editedSchemaGO: [String: Bool] = [:]

    @State private var schemaSelection: String?
    @State private var isLoading = true
    @State private var isApplying = false
    @State private var errorMessage: String?

    // Account actions.
    @State private var showsPasswordChange = false
    @State private var showsDropConfirm = false

    var body: some View {
        content
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaBar(edge: .bottom) { actionBar }
        .navigationTitle(user.displayName)
        .task { await load() }
        .alert("Change Password", isPresented: $showsPasswordChange) {
            PasswordChangeField(session: session, user: user)
        } message: {
            Text("The new password is sent as part of a SQL statement, so it may appear in the server's query log.")
        }
        .confirmationDialog("Delete “\(user.displayName)”?", isPresented: $showsDropConfirm, titleVisibility: .visible) {
            Button("Delete User", role: .destructive) { Task { await drop() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes the account and all its privileges. It cannot be undone.")
        }
    }

    // MARK: - Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                accountLabel
                Spacer(minLength: 12)
                tabPicker.fixedSize()
            }

            // The navigation title already identifies the account on a phone, leaving the full
            // row to the control that changes which set of permissions is being edited.
            tabPicker.frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var accountLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: user.isSuperuser ? "person.fill.badge.plus" : "person.circle")
                .font(.title2)
                .foregroundStyle(user.isSuperuser ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(user.displayName).font(.headline)
                if user.isSuperuser {
                    Text("Superuser").font(.caption).foregroundStyle(.orange)
                }
            }
        }
    }

    private var tabPicker: some View {
        Picker("View", selection: $tab) {
            Text("General").tag(Tab.general)
            Text("Global").tag(Tab.global)
            Text("Schema").tag(Tab.schema)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            DatabaseLoadingView("Loading privileges…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch tab {
            case .general: generalTab
            case .global: globalTab
            case .schema: schemaTab
            }
        }
    }

    private var generalTab: some View {
        Form {
            Section("Account") {
                LabeledContent("User", value: user.name)
                if let host = user.host { LabeledContent("Host", value: host) }
                LabeledContent("Login", value: user.canLogin ? "Allowed" : "Denied")
                if !user.attributes.isEmpty {
                    LabeledContent("Flags", value: user.attributes.joined(separator: ", "))
                }
            }
            Section("Actions") {
                Button("Change Password…", systemImage: "lock.rotation") { showsPasswordChange = true }
                Button("Delete User…", systemImage: "trash", role: .destructive) { showsDropConfirm = true }
            }
            Section("Current Grants") {
                if rawGrants.isEmpty {
                    Text("No grants").foregroundStyle(.secondary)
                }
                ForEach(rawGrants, id: \.self) { grant in
                    Text(grant).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var globalTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Privileges granted on **all databases** (`*.*`). Administrative and replication privileges are server-wide and can only be set here.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                PrivilegeGroupsView(
                    privileges: catalog,
                    selected: $editedGlobal,
                    grantOption: $editedGlobalGO
                )

                selectionButtons(
                    checkAll: {
                        editedGlobal = Set(catalog.filter { !$0.isGrantOption }.map(\.sql))
                        editedGlobalGO = true
                    },
                    uncheckAll: { editedGlobal = []; editedGlobalGO = false }
                )
            }
            .padding(16)
        }
    }

    private var schemaTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Database", selection: $schemaSelection) {
                Text("Choose a database…").tag(String?.none)
                ForEach(schemaDatabaseChoices, id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            if let db = schemaSelection {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Privileges granted on **\(db)** (`\(db).*`).")
                            .font(.callout).foregroundStyle(.secondary)

                        PrivilegeGroupsView(
                            privileges: catalog.filter(\.schemaApplicable),
                            selected: schemaBinding(for: db),
                            grantOption: schemaGrantOptionBinding(for: db)
                        )

                        selectionButtons(
                            checkAll: {
                                editedSchema[db] = Set(catalog.filter { $0.schemaApplicable && !$0.isGrantOption }.map(\.sql))
                                editedSchemaGO[db] = true
                            },
                            uncheckAll: { editedSchema[db] = []; editedSchemaGO[db] = false }
                        )
                    }
                    .padding(16)
                }
            } else {
                ContentUnavailableView("No Database Selected", systemImage: "cylinder.split.1x2",
                                       description: Text("Pick a database to edit its privileges for this account."))
            }
        }
    }

    private func selectionButtons(checkAll: @escaping () -> Void, uncheckAll: @escaping () -> Void) -> some View {
        HStack {
            Button("Check All", action: checkAll)
            Button("Uncheck All", action: uncheckAll)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - Action bar

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                actionStatus
                Spacer(minLength: 12)
                actionButtons
            }

            VStack(alignment: .leading, spacing: 8) {
                actionStatus
                actionButtons.frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var actionStatus: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .lineLimit(2)
        } else if isDirty {
            Text("Unsaved changes").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var actionButtons: some View {
        HStack {
            Button("Revert") { seedEdits(from: current) }
                .buttonStyle(.glass)
                .disabled(!isDirty || isApplying)
            Button("Apply") { Task { await apply() } }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isDirty || isApplying)
        }
    }

    // MARK: - Schema bindings

    /// Databases shown in the schema picker: connection-visible ones plus any the account already
    /// holds grants on.
    private var schemaDatabaseChoices: [String] {
        Set(databases).union(current.schema.keys).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func schemaBinding(for db: String) -> Binding<Set<String>> {
        Binding(
            get: { editedSchema[db] ?? current.schema[db] ?? [] },
            set: { editedSchema[db] = $0 }
        )
    }

    private func schemaGrantOptionBinding(for db: String) -> Binding<Bool> {
        Binding(
            get: { editedSchemaGO[db] ?? current.schemaGrantOption[db] ?? false },
            set: { editedSchemaGO[db] = $0 }
        )
    }

    // MARK: - Diff

    /// The scopes whose edited state differs from the server, each with the sets needed to sync.
    private func changedScopes() -> [(scope: GrantScope, desired: Set<String>, desiredGO: Bool, current: Set<String>, currentGO: Bool)] {
        var out: [(GrantScope, Set<String>, Bool, Set<String>, Bool)] = []
        out.append((.global, editedGlobal, editedGlobalGO, current.global, current.globalGrantOption))

        let dbs = Set(editedSchema.keys).union(current.schema.keys)
        for db in dbs {
            let desired = editedSchema[db] ?? current.schema[db] ?? []
            let desiredGO = editedSchemaGO[db] ?? current.schemaGrantOption[db] ?? false
            out.append((.database(db), desired, desiredGO, current.schema[db] ?? [], current.schemaGrantOption[db] ?? false))
        }

        return out
            .filter { $0.1 != $0.3 || $0.2 != $0.4 }
            .map { (scope: $0.0, desired: $0.1, desiredGO: $0.2, current: $0.3, currentGO: $0.4) }
    }

    private var isDirty: Bool { !changedScopes().isEmpty }

    // MARK: - Loading & applying

    private func load() async {
        isLoading = true
        errorMessage = nil
        let lines = (try? await session.grants(for: user)) ?? []
        rawGrants = lines
        current = MySQLGrantParser.parse(lines)
        seedEdits(from: current)
        isLoading = false
    }

    private func seedEdits(from grants: AccountGrants) {
        editedGlobal = grants.global
        editedGlobalGO = grants.globalGrantOption
        editedSchema = grants.schema
        editedSchemaGO = grants.schemaGrantOption
    }

    private func apply() async {
        isApplying = true
        errorMessage = nil
        do {
            for change in changedScopes() {
                let toGrant = Array(change.desired.subtracting(change.current))
                let toRevoke = Array(change.current.subtracting(change.desired))
                let grantOptionAdd = change.desiredGO && !change.currentGO
                let grantOptionRemove = !change.desiredGO && change.currentGO

                if !toGrant.isEmpty || grantOptionAdd {
                    try await session.grantPrivileges(toGrant, grantOption: grantOptionAdd, on: change.scope, to: user)
                }
                if !toRevoke.isEmpty || grantOptionRemove {
                    try await session.revokePrivileges(toRevoke, grantOption: grantOptionRemove, on: change.scope, from: user)
                }
            }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
        isApplying = false
    }

    private func drop() async {
        do {
            try await session.dropUser(user)
            onDropped()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// The grouped checkbox grid shared by the Global and Schema tabs. `GRANT OPTION` is rendered as
/// a checkbox but bound to the separate `grantOption` flag, since MySQL grants it through a
/// `WITH GRANT OPTION` clause rather than as a privilege in the list.
struct PrivilegeGroupsView: View {
    let privileges: [MySQLPrivilege]
    @Binding var selected: Set<String>
    @Binding var grantOption: Bool

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 16, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 16) {
            ForEach(presentGroups, id: \.self) { group in
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(privileges.filter { $0.group == group }) { privilege in
                            Toggle(isOn: binding(for: privilege)) {
                                HStack(spacing: 4) {
                                    Text(privilege.title)
                                    if privilege.isDestructive {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.caption2).foregroundStyle(.orange)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Text(group.rawValue).font(.subheadline.weight(.semibold))
                }
            }
        }
    }

    private var presentGroups: [MySQLPrivilege.Group] {
        MySQLPrivilege.Group.allCases.filter { group in privileges.contains { $0.group == group } }
    }

    private func binding(for privilege: MySQLPrivilege) -> Binding<Bool> {
        if privilege.isGrantOption { return $grantOption }
        return Binding(
            get: { selected.contains(privilege.sql) },
            set: { isOn in
                if isOn { selected.insert(privilege.sql) } else { selected.remove(privilege.sql) }
            }
        )
    }
}

/// The single secure field inside the "Change Password" alert.
private struct PasswordChangeField: View {
    let session: any DatabaseSession
    let user: DatabaseUser

    @State private var password = ""

    var body: some View {
        SecureField("New password", text: $password)
        Button("Change") {
            guard !password.isEmpty else { return }
            Task { try? await session.setPassword(for: user, to: password) }
        }
        Button("Cancel", role: .cancel) {}
    }
}
