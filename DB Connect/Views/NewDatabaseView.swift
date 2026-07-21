import SwiftUI

/// Creates a database on the connected server.
///
/// Only reachable when the server has said this account may do it — see
/// `SchemaAdminCapability.canCreateDatabase` — so the common failure here is a name collision
/// rather than a permission error.
struct NewDatabaseView: View {
    let session: any DatabaseSession
    let dialect: SQLDialect
    let existing: [String]
    /// Called with the new name so the caller can refresh and switch to it.
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Database name", text: $name)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                } footer: {
                    if let conflict {
                        Label(conflict, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Text("The new database starts empty. You can switch to it and add tables straight away.")
                    }
                }

                Section("SQL") {
                    Text(preview)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Database")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(trimmed.isEmpty || conflict != nil || isCreating)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 340)
        #endif
    }

    private var trimmed: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    /// Caught here rather than at the server, where it comes back as a raw driver error.
    private var conflict: String? {
        guard !trimmed.isEmpty else { return nil }
        guard existing.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) else {
            return nil
        }
        return "A database named “\(trimmed)” already exists."
    }

    private var preview: String {
        guard !trimmed.isEmpty else { return "CREATE DATABASE …" }
        do {
            return try SQLDDLBuilder.createDatabase(name: trimmed, dialect: dialect).sql
        } catch {
            return error.localizedDescription
        }
    }

    private func create() async {
        isCreating = true
        errorMessage = nil
        do {
            try await session.createDatabase(name: trimmed)
            onCreate(trimmed)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isCreating = false
    }
}
