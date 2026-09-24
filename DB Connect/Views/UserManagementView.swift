import SwiftUI

/// Server account management: list users, inspect grants, create, drop, change password,
/// and grant or revoke privileges.
struct UserManagementView: View {
    let session: any DatabaseSession
    let databases: [String]

    @Environment(\.dismiss) private var dismiss

    @State private var users: [DatabaseUser] = []
    @State private var selectedUser: DatabaseUser?
    @State private var grants: [String] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    @State private var showsNewUser = false
    @State private var userToDrop: DatabaseUser?
    @State private var showsPasswordChange = false
    @State private var showsPrivileges = false
    @State private var capability: UserAdminCapability = .none

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    DatabaseLoadingView("Loading accounts…")
                } else if let errorMessage {
                    ContentUnavailableView {
                        Label("Cannot Manage Users", systemImage: "person.slash")
                    } description: {
                        Text(errorMessage)
                    }
                } else {
                    userList
                }
            }
            .navigationTitle("Users")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Add User", systemImage: "person.badge.plus") { showsNewUser = true }
                        // Separate privilege: an account may be able to grant on one database
                        // yet have no right to create server accounts.
                        .disabled(isLoading || errorMessage != nil || !capability.canCreateOrDrop)
                        .help(capability.canCreateOrDrop ? "Create a new account" : "This account cannot create users")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, minHeight: 460)
        #endif
        .task { await load() }
        .sheet(isPresented: $showsNewUser) {
            NewUserView(session: session, databases: databases) {
                Task { await load() }
            }
        }
        .sheet(isPresented: $showsPrivileges) {
            if let selectedUser {
                PrivilegeEditorView(session: session, user: selectedUser, databases: databases) {
                    Task { await loadGrants(for: selectedUser) }
                }
            }
        }
        .alert("Change Password", isPresented: $showsPasswordChange) {
            PasswordChangeFields(session: session, user: selectedUser)
        } message: {
            Text("The new password is sent to the server as part of a SQL statement, so it may appear in the server's query log.")
        }
        .confirmationDialog(
            "Delete “\(userToDrop?.displayName ?? "")”?",
            isPresented: $userToDrop.isPresent(),
            titleVisibility: .visible
        ) {
            Button("Delete User", role: .destructive) {
                if let userToDrop { Task { await drop(userToDrop) } }
            }
            Button("Cancel", role: .cancel) { userToDrop = nil }
        } message: {
            Text("This permanently removes the account and all its privileges. It cannot be undone.")
        }
    }

    private var userList: some View {
        List(selection: $selectedUser) {
            Section("Accounts") {
                ForEach(users) { user in
                    UserRow(user: user)
                        .tag(user)
                        .contextMenu {
                            Button("Privileges…", systemImage: "key") {
                                selectedUser = user
                                showsPrivileges = true
                            }
                            .disabled(!capability.canGrant)
                            Button("Change Password…", systemImage: "lock.rotation") {
                                selectedUser = user
                                showsPasswordChange = true
                            }
                            .disabled(!capability.canCreateOrDrop)
                            Divider()
                            Button("Delete…", systemImage: "trash", role: .destructive) {
                                userToDrop = user
                            }
                            .disabled(!capability.canCreateOrDrop)
                        }
                }
            }

            if let selectedUser {
                Section("Grants for \(selectedUser.displayName)") {
                    if grants.isEmpty {
                        Text("No grants").foregroundStyle(.secondary)
                    }
                    ForEach(grants, id: \.self) { grant in
                        Text(grant)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .onChange(of: selectedUser) { _, user in
            guard let user else { return }
            Task { await loadGrants(for: user) }
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            capability = await session.userAdmin
            guard capability.isAvailable else {
                throw UserManagementError.notPermitted
            }
            users = capability.canList ? try await session.users() : []
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadGrants(for user: DatabaseUser) async {
        grants = (try? await session.grants(for: user)) ?? []
    }

    private func drop(_ user: DatabaseUser) async {
        userToDrop = nil
        do {
            try await session.dropUser(user)
            if selectedUser?.id == user.id { selectedUser = nil }
            await load()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct UserRow: View {
    let user: DatabaseUser

    var body: some View {
        HStack {
            Image(systemName: user.isSuperuser ? "person.fill.badge.plus" : "person")
                .foregroundStyle(user.isSuperuser ? .orange : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                if !user.attributes.isEmpty {
                    Text(user.attributes.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Reachable from anywhere is worth flagging: it is the usual cause of an
            // unexpectedly exposed account.
            if user.isOpenToAnyHost {
                Label("any host", systemImage: "globe")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if !user.canLogin {
                Text("no login").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Inline fields for the password alert.
private struct PasswordChangeFields: View {
    let session: any DatabaseSession
    let user: DatabaseUser?

    @State private var password = ""

    var body: some View {
        SecureField("New password", text: $password)
        Button("Change") {
            guard let user, !password.isEmpty else { return }
            Task { try? await session.setPassword(for: user, to: password) }
        }
        Button("Cancel", role: .cancel) {}
    }
}
