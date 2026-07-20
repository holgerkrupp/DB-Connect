import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Create/edit form for a connection. Phase 1 exposes SQLite fully; the network drivers appear
/// in the picker as soon as their entries land in `DriverRegistry`.
struct ConnectionFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var existing: Connection?

    @State private var name = ""
    @State private var driverID = "sqlite"
    @State private var host = ""
    @State private var port = 0
    @State private var database = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isReadOnly = false
    @State private var tlsMode: TLSMode = .required
    @State private var certificatePEM = ""
    @State private var certificateFingerprint: String?
    @State private var certificateError: String?
    @State private var showsCertificateImporter = false
    @State private var errorMessage: String?
    @State private var showsFileImporter = false
    @State private var hasStoredSecret = false

    private var tlsFooter: String {
        switch tlsMode {
        case .pinned:
            "Only the imported certificate is trusted. Compare the fingerprint with the one your server administrator gives you — this is the mode to use for self-signed certificates."
        case .preferred:
            "Falls back to an unencrypted connection if the server refuses TLS."
        case .required:
            "Requests TLS and validates against the system trust store. Note that MySQL falls back to plaintext if the server refuses TLS — use Pinned for a guarantee."
        case .disabled:
            "The connection is not encrypted. Only sensible over a VPN or an SSH tunnel."
        }
    }

    private var style: DriverRegistry.ConnectionStyle { DriverRegistry.style(for: driverID) }
    private var isFileBased: Bool { style == .file }

    private var canSave: Bool {
        switch style {
        // The database is optional for servers: connect first, then pick one from the list.
        case .file: !database.isEmpty
        case .server: !host.isEmpty
        case .httpEndpoint: !host.isEmpty && (!password.isEmpty || hasStoredSecret)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $driverID) {
                        ForEach(DriverRegistry.all, id: \.self.idString) { driver in
                            Text(type(of: driver).displayName).tag(type(of: driver).id)
                        }
                    }
                }

                switch style {
                case .file:
                    Section("Database File") {
                        HStack {
                            Text(database.isEmpty ? "No file selected" : (database as NSString).lastPathComponent)
                                .foregroundStyle(database.isEmpty ? .secondary : .primary)
                            Spacer()
                            Button("Choose…") { showsFileImporter = true }
                        }
                    }

                case .server:
                    Section {
                        TextField("Host", text: $host)
                        TextField("Port", value: $port, format: .number.grouping(.never))
                        TextField("Database (optional)", text: $database)
                    } header: {
                        Text("Server")
                    } footer: {
                        Text("Leave the database blank to choose one after connecting.")
                    }
                    Section {
                        TextField("Username", text: $username)
                        SecureField(hasStoredSecret ? "Password (unchanged)" : "Password", text: $password)
                    } header: {
                        Text("Credentials")
                    } footer: {
                        if hasStoredSecret {
                            Text("A password is stored in your iCloud Keychain. Leave this blank to keep it.")
                        }
                    }
                    Section {
                        Picker("Encryption", selection: $tlsMode) {
                            Text("Required").tag(TLSMode.required)
                            Text("Preferred").tag(TLSMode.preferred)
                            Text("Pinned certificate").tag(TLSMode.pinned)
                            Text("Disabled").tag(TLSMode.disabled)
                        }

                        if tlsMode == .pinned {
                            HStack {
                                Text(certificatePEM.isEmpty ? "No certificate" : "Certificate imported")
                                    .foregroundStyle(certificatePEM.isEmpty ? .secondary : .primary)
                                Spacer()
                                Button(certificatePEM.isEmpty ? "Import…" : "Replace…") {
                                    showsCertificateImporter = true
                                }
                            }
                            if let fingerprint = certificateFingerprint {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("SHA-256 fingerprint").font(.caption).foregroundStyle(.secondary)
                                    Text(fingerprint)
                                        .font(.caption.monospaced())
                                        .textSelection(.enabled)
                                        .lineLimit(3)
                                }
                            }
                            if let certificateError {
                                Text(certificateError).font(.caption).foregroundStyle(.red)
                            }
                        }
                    } footer: {
                        Text(tlsFooter)
                    }

                case .httpEndpoint:
                    Section {
                        TextField("Project URL", text: $host)
                            .textContentType(.URL)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()
                    } header: {
                        Text("Project")
                    } footer: {
                        Text("For example https://abcdefgh.supabase.co — the /rest/v1 path is added automatically.")
                    }
                    Section {
                        SecureField(hasStoredSecret ? "API Key (unchanged)" : "API Key", text: $password)
                    } header: {
                        Text("Credentials")
                    } footer: {
                        Text(hasStoredSecret
                             ? "A key is stored in your iCloud Keychain. Leave this blank to keep it."
                             : "Use the anon or service role key. It is stored in your iCloud Keychain, never in the synced database.")
                    }
                }

                Section {
                    Toggle("Read-only", isOn: $isReadOnly)
                } footer: {
                    Text("Read-only blocks all writes on this connection, regardless of database permissions.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(existing == nil ? "New Connection" : "Edit Connection")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .fileImporter(
                isPresented: $showsCertificateImporter,
                allowedContentTypes: [.x509Certificate, .data, .text]
            ) { result in
                importCertificate(result)
            }
            .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.data, .database]) { result in
                if case .success(let url) = result {
                    // Keep access to the picked file across launches via a security-scoped bookmark.
                    database = url.path
                    if let bookmark = try? url.bookmarkData(options: bookmarkCreationOptions) {
                        bookmarkData = bookmark
                    }
                    if name.isEmpty {
                        name = url.deletingPathExtension().lastPathComponent
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 400)
        #endif
        .onAppear(perform: populateFromExisting)
        .onChange(of: driverID) { _, newValue in
            // Only auto-fill the port while it is untouched, so an edit is never overwritten.
            let defaults = DriverRegistry.all.map { DriverRegistry.defaultPort(for: type(of: $0).id) }
            if port == 0 || defaults.contains(port) {
                port = DriverRegistry.defaultPort(for: newValue)
            }
        }
    }

    @State private var bookmarkData: Data?

    private var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
    }

    /// Read the certificate and derive its fingerprint immediately, so an unusable file is
    /// rejected here rather than at connect time.
    private func importCertificate(_ result: Result<URL, Error>) {
        certificateError = nil
        guard case .success(let url) = result else { return }

        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            certificateFingerprint = try CertificatePinning.fingerprint(fromPEM: text)
            certificatePEM = text
        } catch {
            certificatePEM = ""
            certificateFingerprint = nil
            certificateError = error.localizedDescription
        }
    }

    private func populateFromExisting() {
        guard let existing else { return }
        name = existing.name
        driverID = existing.driverID
        host = existing.host
        port = existing.port
        database = existing.database
        username = existing.username
        isReadOnly = existing.isReadOnly
        tlsMode = TLSMode(rawValue: existing.tlsMode) ?? .required
        certificatePEM = existing.pinnedCertificatePEM ?? ""
        certificateFingerprint = existing.certificateFingerprint
        // Never read the secret into the field — only report that one exists, so an edit
        // cannot accidentally round-trip a password through the UI.
        hasStoredSecret = (try? KeychainSecretStore().secret(for: existing.id)) as? Secret != nil
    }

    private func save() {
        let connection = existing ?? Connection(name: name, driverID: driverID)
        connection.name = name
        connection.driverID = driverID
        connection.host = host
        connection.port = port
        connection.database = database
        connection.username = username
        connection.isReadOnly = isReadOnly
        connection.tlsMode = tlsMode.rawValue
        connection.pinnedCertificatePEM = certificatePEM.isEmpty ? nil : certificatePEM
        connection.certificateFingerprint = certificateFingerprint
        if let bookmarkData {
            connection.fileBookmark = bookmarkData
        }

        do {
            if !password.isEmpty {
                // HTTP drivers authenticate with a token rather than a password; keeping them
                // in separate fields means a driver never has to guess which one it was given.
                let secret = style == .httpEndpoint
                    ? Secret(apiToken: password)
                    : Secret(password: password)
                try KeychainSecretStore().save(secret, for: connection.id)
            }
            if existing == nil {
                modelContext.insert(connection)
            }
            try modelContext.save()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private extension DatabaseDriver {
    var idString: String { type(of: self).id }
}
