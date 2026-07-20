import SwiftUI

/// Create an account, optionally granting it a starting set of privileges.
struct NewUserView: View {
    let session: any DatabaseSession
    let databases: [String]
    let onCreated: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var host = "%"
    @State private var password = ""
    @State private var selectedDatabase: String?
    @State private var preset: AccessPreset = .readOnly
    @State private var errorMessage: String?
    @State private var isWorking = false

    /// MySQL accounts are name@host; Postgres roles have no host part.
    private var usesHost: Bool {
        session.capabilities.supportsSchemas == false || databases.isEmpty == false
    }

    enum AccessPreset: String, CaseIterable, Identifiable {
        case none
        case readOnly
        case readWrite
        case full

        var id: String { rawValue }

        var title: String {
            switch self {
            case .none: "No access yet"
            case .readOnly: "Read only"
            case .readWrite: "Read and write"
            case .full: "Full control"
            }
        }

        var privileges: [Privilege] {
            switch self {
            case .none: []
            case .readOnly: Privilege.readOnly
            case .readWrite: Privilege.readWrite
            case .full: Privilege.allCases
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("User name", text: $name)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                    SecureField("Password", text: $password)
                }

                Section {
                    TextField("Host", text: $host)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } header: {
                    Text("Allowed From")
                } footer: {
                    Text(host == "%"
                         ? "% lets this account connect from any address. Prefer a specific host or IP where you can."
                         : "The account may only connect from this host. Note that a dynamic home IP will change.")
                }

                Section {
                    Picker("Database", selection: $selectedDatabase) {
                        Text("None").tag(Optional<String>.none)
                        ForEach(databases, id: \.self) { database in
                            Text(database).tag(Optional(database))
                        }
                    }
                    Picker("Access", selection: $preset) {
                        ForEach(AccessPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }
                    .disabled(selectedDatabase == nil)
                } header: {
                    Text("Initial Privileges")
                } footer: {
                    Text(privilegeFooter)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New User")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(name.isEmpty || password.isEmpty || isWorking)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 420)
        #endif
    }

    private var privilegeFooter: String {
        guard let selectedDatabase else {
            return "The account will be created with no access. You can grant privileges afterwards."
        }
        switch preset {
        case .none:
            return "The account will be created with no access to \(selectedDatabase)."
        case .readOnly:
            return "SELECT on \(selectedDatabase)."
        case .readWrite:
            return "SELECT, INSERT, UPDATE and DELETE on \(selectedDatabase)."
        case .full:
            return "Every privilege on \(selectedDatabase), including DROP. Grant this only when it is genuinely needed."
        }
    }

    private func create() async {
        isWorking = true
        errorMessage = nil
        do {
            try await session.createUser(name: name, host: host.isEmpty ? nil : host, password: password)

            if let selectedDatabase, !preset.privileges.isEmpty {
                let user = DatabaseUser(name: name, host: host.isEmpty ? nil : host)
                try await session.grant(preset.privileges, on: .database(selectedDatabase), to: user)
            }
            onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}

/// Grant and revoke privileges for an existing account.
struct PrivilegeEditorView: View {
    let session: any DatabaseSession
    let user: DatabaseUser
    let databases: [String]
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var selectedDatabase: String?
    @State private var selected: Set<Privilege> = []
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Scope") {
                    Picker("Database", selection: $selectedDatabase) {
                        Text("Choose…").tag(Optional<String>.none)
                        ForEach(databases, id: \.self) { database in
                            Text(database).tag(Optional(database))
                        }
                    }
                }

                Section {
                    ForEach(Privilege.allCases) { privilege in
                        Toggle(isOn: Binding(
                            get: { selected.contains(privilege) },
                            set: { isOn in
                                if isOn { selected.insert(privilege) } else { selected.remove(privilege) }
                            }
                        )) {
                            HStack {
                                Text(privilege.title)
                                if privilege.isDestructive {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.orange)
                                }
                            }
                        }
                    }
                } header: {
                    Text("Privileges")
                } footer: {
                    Text("Marked privileges can destroy data. Grant applies the selection; Revoke removes it.")
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(user.displayName)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Revoke", role: .destructive) { Task { await apply(granting: false) } }
                        .disabled(!canApply)
                    Button("Grant") { Task { await apply(granting: true) } }
                        .disabled(!canApply)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 480)
        #endif
    }

    private var canApply: Bool {
        selectedDatabase != nil && !selected.isEmpty && !isWorking
    }

    private func apply(granting: Bool) async {
        guard let selectedDatabase else { return }
        isWorking = true
        errorMessage = nil
        let privileges = Array(selected)

        do {
            if granting {
                try await session.grant(privileges, on: .database(selectedDatabase), to: user)
            } else {
                try await session.revoke(privileges, on: .database(selectedDatabase), from: user)
            }
            onChange()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isWorking = false
    }
}
