import SwiftUI

/// A Sequel Ace–style account manager: the list of accounts on the left, and a tabbed privilege
/// editor (General · Global Privileges · Schema Privileges) on the right. Presented in its own
/// window on Mac and iPad; falls back to a stack on iPhone via `NavigationSplitView`.
///
/// This is the MySQL/MariaDB experience — it relies on the driver modelling the complete
/// per-scope privilege set (`supportsGranularPrivileges`). Other drivers keep the simpler
/// `UserManagementView` sheet.
struct UserAdminView: View {
    let session: any DatabaseSession
    let databases: [String]
    let title: String
    /// Present for a sheet-hosted manager; nil when this view owns a separate window.
    var onDismiss: (() -> Void)?

    @State private var users: [DatabaseUser] = []
    @State private var selection: DatabaseUser?
    @State private var catalog: [MySQLPrivilege] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    @State private var showsNewUser = false
    /// The account awaiting delete confirmation, and any error from the drop itself.
    @State private var userToDelete: DatabaseUser?
    @State private var deletionError: String?

    var body: some View {
        NavigationSplitView {
            accountList
                .navigationTitle("Accounts")
                .navigationSubtitle(title)
                #if os(macOS)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
                #endif
                .toolbar {
                    if let onDismiss {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done", action: onDismiss)
                        }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Add User", systemImage: "person.badge.plus") {
                            showsNewUser = true
                        }
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Delete User", systemImage: "person.badge.minus", role: .destructive) {
                            userToDelete = selection
                        }
                        .disabled(selection == nil)
                    }
                    ToolbarItem(placement: .secondaryAction) {
                        Button("Reload", systemImage: "arrow.clockwise") { Task { await load() } }
                    }
                }
        } detail: {
            if let selection {
                PrivilegeDetailView(
                    session: session,
                    user: selection,
                    databases: databaseChoices,
                    catalog: catalog,
                    onDropped: { Task { await load(clearingSelection: true) } }
                )
                .id(selection)
                .navigationSubtitle(title)
            } else if isLoading {
                ProgressView("Loading accounts…")
            } else if let errorMessage {
                ContentUnavailableView("Cannot Manage Users", systemImage: "person.slash", description: Text(errorMessage))
            } else {
                ContentUnavailableView("No Account Selected", systemImage: "person.crop.circle",
                                       description: Text("Choose an account to view and edit its privileges."))
            }
        }
        .navigationTitle(title)
        .task { await load() }
        .sheet(isPresented: $showsNewUser) {
            NewUserView(session: session, databases: databases) {
                Task { await load() }
            }
        }
        .confirmationDialog(
            "Delete “\(userToDelete?.displayName ?? "")”?",
            isPresented: Binding(get: { userToDelete != nil }, set: { if !$0 { userToDelete = nil } }),
            titleVisibility: .visible,
            presenting: userToDelete
        ) { user in
            Button("Delete User", role: .destructive) { Task { await drop(user) } }
            Button("Cancel", role: .cancel) { userToDelete = nil }
        } message: { user in
            Text("This permanently removes “\(user.displayName)” and all its privileges. It cannot be undone.")
        }
        .alert(
            "Could Not Delete User",
            isPresented: Binding(get: { deletionError != nil }, set: { if !$0 { deletionError = nil } }),
            presenting: deletionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text(message)
        }
    }

    private func drop(_ user: DatabaseUser) async {
        userToDelete = nil
        do {
            try await session.dropUser(user)
            if selection == user { selection = nil }
            await load()
        } catch {
            // The driver refuses to drop the account you are connected as; surface that plainly
            // rather than leaving the button looking broken.
            deletionError = error.localizedDescription
        }
    }

    /// Databases offered on the Schema tab: the ones the connection can see, plus any the account
    /// already has grants on (which may include databases the connected user cannot list).
    private var databaseChoices: [String] {
        databases
    }

    @ViewBuilder
    private var accountList: some View {
        if isLoading && users.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(groupedNames, id: \.self) { name in
                    let hosts = grouped[name] ?? []
                    if hosts.count == 1 {
                        accountRow(hosts[0], hostOnly: false)
                    } else {
                        DisclosureGroup {
                            ForEach(hosts) { accountRow($0, hostOnly: true) }
                        } label: {
                            Label(name, systemImage: "person.2")
                        }
                    }
                }
            }
        }
    }

    private func accountRow(_ user: DatabaseUser, hostOnly: Bool) -> some View {
        AccountRow(user: user, hostOnly: hostOnly)
            .tag(user)
            .contextMenu {
                Button("Delete User…", systemImage: "trash", role: .destructive) {
                    userToDelete = user
                }
            }
            .swipeActions(edge: .trailing) {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    userToDelete = user
                }
            }
    }

    /// Accounts grouped by user name so multiple hosts collapse under one entry, mirroring Sequel
    /// Ace's account tree.
    private var grouped: [String: [DatabaseUser]] {
        Dictionary(grouping: users, by: \.name).mapValues { $0.sorted { ($0.host ?? "") < ($1.host ?? "") } }
    }

    private var groupedNames: [String] {
        grouped.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func load(clearingSelection: Bool = false) async {
        isLoading = true
        errorMessage = nil
        if clearingSelection { selection = nil }
        if catalog.isEmpty {
            let supported = await session.supportedPrivileges()
            catalog = MySQLPrivilege.all.filter { supported.contains($0.sql) }
        }
        do {
            let loaded = try await session.users()
            users = loaded
            // Keep the current selection if it still exists; otherwise pick nothing.
            if let selection, !loaded.contains(selection) { self.selection = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

/// One account line in the sidebar.
private struct AccountRow: View {
    let user: DatabaseUser
    /// When the account is shown under a name group, only the host part is meaningful.
    let hostOnly: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: user.isSuperuser ? "person.fill.badge.plus" : "person")
                .foregroundStyle(user.isSuperuser ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(hostOnly ? (user.host.map { "@\($0)" } ?? user.name) : user.displayName)
                    .lineLimit(1)
                if !user.attributes.isEmpty {
                    Text(user.attributes.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if user.isOpenToAnyHost {
                Image(systemName: "globe").font(.caption2).foregroundStyle(.orange)
                    .help("This account may connect from any host.")
            }
        }
    }
}
