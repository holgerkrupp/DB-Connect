import SwiftUI
import SwiftData
import UniformTypeIdentifiers

/// Create/edit form for a connection. The common path stays short, while transport and
/// authentication extras live in clearly-labelled sections for the drivers that support them.
struct ConnectionFormView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var connections: [Connection]

    let purchaseManager: PurchaseManager
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
    @State private var showsSSHKeyImporter = false
    @State private var errorMessage: String?
    @State private var showsFileImporter = false
    @State private var showsFolderImporter = false
    @State private var showsPaywall = false
    @State private var bookmarkData: Data?
    @State private var containerBookmarkData: Data?
    @State private var fileAccessOwnerDeviceID: String?
    @State private var fileAccessOwnerDeviceName: String?

    @State private var transportMode: ConnectionTransportMode = .tcp
    @State private var socketPath = ""

    @State private var authenticationMode: DatabaseAuthenticationMode = .password
    @State private var awsRegion = ""
    @State private var awsAccessKeyID = ""
    @State private var awsSecretAccessKey = ""
    @State private var awsSessionToken = ""
    @State private var vaultServerURL = ""
    @State private var vaultAuthMount = "oidc"
    @State private var vaultRole = ""
    @State private var vaultDatabaseMount = "database"
    @State private var vaultDatabaseRole = ""

    @State private var sshTunnelEnabled = false
    @State private var sshHost = ""
    @State private var sshPort = 22
    @State private var sshUsername = ""
    @State private var sshAuthenticationMode: SSHTunnelAuthenticationMode = .agent
    @State private var sshPassword = ""
    @State private var sshPrivateKey = ""
    @State private var sshPassphrase = ""

    @State private var hasStoredDatabasePassword = false
    @State private var hasStoredAWSCredentials = false
    @State private var hasStoredSSHPassword = false
    @State private var hasStoredSSHPrivateKey = false

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

    /// The editor still owns the controls that are specific to this surface, but domain
    /// validation and persistence mapping are centralized in these value drafts.
    private var currentDraft: ConnectionDraft {
        var draft = ConnectionDraft()
        draft.name = name
        draft.driverID = driverID
        draft.host = host
        draft.port = port
        draft.database = database
        draft.username = username
        draft.isReadOnly = isReadOnly
        draft.tlsMode = tlsMode
        draft.certificatePEM = certificatePEM
        draft.certificateFingerprint = certificateFingerprint
        draft.bookmarkData = bookmarkData
        draft.containerBookmarkData = containerBookmarkData
        draft.fileAccessOwnerDeviceID = fileAccessOwnerDeviceID
        draft.fileAccessOwnerDeviceName = fileAccessOwnerDeviceName
        draft.transportMode = transportMode
        draft.socketPath = socketPath
        draft.authenticationMode = authenticationMode
        draft.awsRegion = awsRegion
        draft.vaultServerURL = vaultServerURL
        draft.vaultAuthMount = vaultAuthMount
        draft.vaultRole = vaultRole
        draft.vaultDatabaseMount = vaultDatabaseMount
        draft.vaultDatabaseRole = vaultDatabaseRole
        draft.sshTunnelEnabled = sshTunnelEnabled
        draft.sshHost = sshHost
        draft.sshPort = sshPort
        draft.sshUsername = sshUsername
        draft.sshAuthenticationMode = sshAuthenticationMode
        return draft
    }

    private var currentSecretDraft: ConnectionSecretDraft {
        var draft = ConnectionSecretDraft()
        draft.password = password
        draft.awsAccessKeyID = awsAccessKeyID
        draft.awsSecretAccessKey = awsSecretAccessKey
        draft.awsSessionToken = awsSessionToken
        draft.sshPassword = sshPassword
        draft.sshPrivateKey = sshPrivateKey
        draft.sshPassphrase = sshPassphrase
        draft.hasStoredDatabasePassword = hasStoredDatabasePassword
        draft.hasStoredAWSCredentials = hasStoredAWSCredentials
        draft.hasStoredSSHPassword = hasStoredSSHPassword
        draft.hasStoredSSHPrivateKey = hasStoredSSHPrivateKey
        return draft
    }

    private var style: DriverRegistry.ConnectionStyle { DriverRegistry.style(for: driverID) }
    private var isFileBased: Bool { style == .file }
    private var supportsSocketConnections: Bool { driverID == MySQLDriver.id }
    private var supportsAWSIAM: Bool { driverID == MySQLDriver.id && transportMode == .tcp }
    private var supportsSSHTunnel: Bool {
        #if os(macOS)
        return style == .server && transportMode == .tcp
        #else
        return false
        #endif
    }

    private var sqliteFileAccessIssue: String? {
        guard isFileBased else { return nil }
        return currentDraft.validationIssue(secrets: currentSecretDraft)
    }

    private var canSave: Bool {
        currentDraft.canSave(secrets: currentSecretDraft)
    }

    private var bookmarkCreationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        [.withSecurityScope]
        #else
        []
        #endif
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
                    fileSection
                case .server:
                    serverSections
                case .httpEndpoint:
                    httpEndpointSections
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
            .fileImporter(
                isPresented: $showsSSHKeyImporter,
                allowedContentTypes: [.data, .text]
            ) { result in
                importSSHKey(result)
            }
            .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.data, .database]) { result in
                importSQLiteFile(result)
            }
            .fileImporter(isPresented: $showsFolderImporter, allowedContentTypes: [.folder]) { result in
                importSQLiteFolder(result)
            }
            .sheet(isPresented: $showsPaywall, onDismiss: saveAfterUnlock) {
                PaywallView(purchaseManager: purchaseManager)
            }
        }
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 700, minHeight: 760, idealHeight: 860)
        #endif
        .onAppear(perform: populateFromExisting)
        .onChange(of: driverID) { _, newValue in
            var draft = currentDraft
            draft.didChangeDriver(to: newValue)
            apply(draft)
        }
        .onChange(of: transportMode) { _, newValue in
            var draft = currentDraft
            draft.didChangeTransport(to: newValue)
            apply(draft)
        }
    }

    @ViewBuilder
    private var fileSection: some View {
        Section {
            HStack {
                Text(database.isEmpty ? "No file selected" : (database as NSString).lastPathComponent)
                    .foregroundStyle(database.isEmpty ? .secondary : .primary)
                Spacer()
                Button("Choose File…") { showsFileImporter = true }
            }
            if bookmarkData != nil {
                Button("Forget Saved File Access", role: .destructive) {
                    bookmarkData = nil
                }
            }
            if !isReadOnly {
                HStack {
                    Text(containerBookmarkData == nil ? "Folder access not granted" : "Folder access granted")
                        .foregroundStyle(containerBookmarkData == nil ? .secondary : .primary)
                    Spacer()
                    Button(containerBookmarkData == nil ? "Grant Folder Access…" : "Change Folder…") {
                        showsFolderImporter = true
                    }
                }
                if containerBookmarkData != nil {
                    Button("Forget Saved Folder Access", role: .destructive) {
                        containerBookmarkData = nil
                    }
                }
            }
        } header: {
            Text("Database File")
        } footer: {
            if let sqliteFileAccessIssue {
                Text("\(sqliteFileAccessIssue) Use Choose File… and, for writable databases, Grant Folder Access… here to grant access on this Mac; there is no separate permission prompt.")
            } else {
                Text(isReadOnly
                     ? "DB Connect stores SQLite file access locally on this Mac. Read-only connections only need the database file itself."
                     : "Writable SQLite connections also need access to the containing folder so SQLite can open its WAL, SHM, or rollback-journal files. If this connection came from an older version or another device, grant both file and folder access here.")
            }
        }
    }

    @ViewBuilder
    private var serverSections: some View {
        Section {
            if supportsSocketConnections {
                Picker("Transport", selection: $transportMode) {
                    Text("TCP").tag(ConnectionTransportMode.tcp)
                    Text("Local Socket").tag(ConnectionTransportMode.unixSocket)
                }
            }
            if supportsAWSIAM {
                Picker("Database Authentication", selection: $authenticationMode) {
                    Text("Password").tag(DatabaseAuthenticationMode.password)
                    Text("AWS IAM").tag(DatabaseAuthenticationMode.awsIAM)
                }
            }
            if supportsSSHTunnel {
                Toggle("Connect Through SSH Tunnel", isOn: $sshTunnelEnabled)
            }
        } header: {
            Text("Connection Options")
        } footer: {
            Text("Keep the default path for ordinary server connections. Local sockets, SSH tunnelling, and IAM credentials are opt-in so they stay discoverable without crowding the basic flow.")
        }

        if transportMode == .unixSocket {
            Section {
                TextField("Socket path", text: $socketPath)
                TextField("Database (optional)", text: $database)
            } header: {
                Text("Local Socket")
            } footer: {
                Text("Use the filesystem path published by the local MySQL or MariaDB server, for example `/tmp/mysql.sock`. Socket connections stay local to this Mac and do not use TLS.")
            }
        } else {
            Section {
                TextField("Host", text: $host)
                TextField("Port", value: $port, format: .number.grouping(.never))
                TextField("Database (optional)", text: $database)
            } header: {
                Text("Server")
            } footer: {
                Text("Leave the database blank to choose one after connecting.")
            }
        }

        Section {
            TextField("Username", text: $username)
            if authenticationMode == .password {
                SecureField(hasStoredDatabasePassword ? "Password (unchanged)" : "Password", text: $password)
            }
        } header: {
            Text("Credentials")
        } footer: {
            if authenticationMode == .password, hasStoredDatabasePassword {
                Text("A password is stored in your iCloud Keychain. Leave this blank to keep it.")
            } else if authenticationMode == .password {
                Text("Passwords are stored in your iCloud Keychain, never in the synced connection record.")
            } else {
                Text("AWS IAM generates a fresh short-lived token each time DB Connect opens or reopens the MySQL connection.")
            }
        }

        if authenticationMode == .awsIAM {
            Section {
                TextField("AWS Region", text: $awsRegion)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField(hasStoredAWSCredentials ? "Access Key ID (unchanged)" : "Access Key ID", text: $awsAccessKeyID)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                SecureField(hasStoredAWSCredentials ? "Secret Access Key (unchanged)" : "Secret Access Key", text: $awsSecretAccessKey)
                SecureField("Session Token (optional)", text: $awsSessionToken)
            } header: {
                Text("AWS IAM")
            } footer: {
                Text("Use the RDS or Aurora endpoint hostname, not a custom DNS alias. IAM tokens are valid for 15 minutes, but only for the login handshake; open sessions stay connected normally after authentication.")
            }
        }

        if transportMode == .tcp {
            tlsSection
        }

        if sshTunnelEnabled {
            sshSection
        }
    }

    @ViewBuilder
    private var tlsSection: some View {
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
        } header: {
            Text("Transport Security")
        } footer: {
            Text(tlsFooter)
        }
    }

    @ViewBuilder
    private var sshSection: some View {
        Section {
            TextField("SSH Host", text: $sshHost)
            TextField("SSH Port", value: $sshPort, format: .number.grouping(.never))
            TextField("SSH Username", text: $sshUsername)
            Picker("SSH Authentication", selection: $sshAuthenticationMode) {
                Text("SSH Agent").tag(SSHTunnelAuthenticationMode.agent)
                Text("Password").tag(SSHTunnelAuthenticationMode.password)
                Text("Private Key").tag(SSHTunnelAuthenticationMode.privateKey)
            }

            switch sshAuthenticationMode {
            case .agent:
                EmptyView()
            case .password:
                SecureField(hasStoredSSHPassword ? "SSH Password (unchanged)" : "SSH Password", text: $sshPassword)
            case .privateKey:
                HStack {
                    Text(sshPrivateKey.isEmpty ? (hasStoredSSHPrivateKey ? "Private key stored in Keychain" : "No private key imported") : "Private key ready")
                        .foregroundStyle((sshPrivateKey.isEmpty && !hasStoredSSHPrivateKey) ? .secondary : .primary)
                    Spacer()
                    Button(sshPrivateKey.isEmpty && !hasStoredSSHPrivateKey ? "Import…" : "Replace…") {
                        showsSSHKeyImporter = true
                    }
                }
                SecureField("Key Passphrase (optional)", text: $sshPassphrase)
            }
        } header: {
            Text("SSH Tunnel")
        } footer: {
            Text("DB Connect uses the system OpenSSH client on macOS and requires a trusted host key in your normal SSH known-hosts configuration. Unknown or changed host keys fail closed instead of being accepted silently.")
        }
    }

    @ViewBuilder
    private var httpEndpointSections: some View {
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
            SecureField(hasStoredDatabasePassword ? "API Key (unchanged)" : "API Key", text: $password)
        } header: {
            Text("Credentials")
        } footer: {
            Text(hasStoredDatabasePassword
                 ? "A key is stored in your iCloud Keychain. Leave this blank to keep it."
                 : "Use the anon or service role key. It is stored in Keychain, never in the local database.")
        }
    }

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

    private func importSSHKey(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }

        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

        do {
            sshPrivateKey = try String(contentsOf: url, encoding: .utf8)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func populateFromExisting() {
        guard let existing else { return }
        apply(ConnectionDraft(connection: existing))

        let storedSecret = try? KeychainSecretStore().secret(for: existing.id)
        apply(ConnectionSecretDraft(stored: storedSecret))
        refreshSQLiteBookmarkIfPossible()
    }

    private func apply(_ draft: ConnectionDraft) {
        name = draft.name
        driverID = draft.driverID
        host = draft.host
        port = draft.port
        database = draft.database
        username = draft.username
        isReadOnly = draft.isReadOnly
        tlsMode = draft.tlsMode
        certificatePEM = draft.certificatePEM
        certificateFingerprint = draft.certificateFingerprint
        transportMode = draft.transportMode
        socketPath = draft.socketPath
        authenticationMode = draft.authenticationMode
        awsRegion = draft.awsRegion
        vaultServerURL = draft.vaultServerURL
        vaultAuthMount = draft.vaultAuthMount
        vaultRole = draft.vaultRole
        vaultDatabaseMount = draft.vaultDatabaseMount
        vaultDatabaseRole = draft.vaultDatabaseRole
        sshTunnelEnabled = draft.sshTunnelEnabled
        sshHost = draft.sshHost
        sshPort = draft.sshPort
        sshUsername = draft.sshUsername
        sshAuthenticationMode = draft.sshAuthenticationMode
        bookmarkData = draft.bookmarkData
        containerBookmarkData = draft.containerBookmarkData
        fileAccessOwnerDeviceID = draft.fileAccessOwnerDeviceID
        fileAccessOwnerDeviceName = draft.fileAccessOwnerDeviceName
    }

    private func apply(_ draft: ConnectionSecretDraft) {
        hasStoredDatabasePassword = draft.hasStoredDatabasePassword
        hasStoredAWSCredentials = draft.hasStoredAWSCredentials
        hasStoredSSHPassword = draft.hasStoredSSHPassword
        hasStoredSSHPrivateKey = draft.hasStoredSSHPrivateKey
    }

    private func importSQLiteFile(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }

        #if os(macOS)
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        #endif

        database = url.path
        if let bookmark = try? url.bookmarkData(options: bookmarkCreationOptions) {
            bookmarkData = bookmark
        }
        let folderURL = url.deletingLastPathComponent()
        if let bookmark = try? folderURL.bookmarkData(options: bookmarkCreationOptions) {
            containerBookmarkData = bookmark
        }
        fileAccessOwnerDeviceID = DeviceIdentity.current.id
        fileAccessOwnerDeviceName = DeviceIdentity.current.name
        if name.isEmpty {
            name = url.deletingPathExtension().lastPathComponent
        }
    }

    private func importSQLiteFolder(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }

        #if os(macOS)
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        #endif

        if let bookmark = try? url.bookmarkData(options: bookmarkCreationOptions) {
            containerBookmarkData = bookmark
        }
        fileAccessOwnerDeviceID = DeviceIdentity.current.id
        fileAccessOwnerDeviceName = DeviceIdentity.current.name
    }

    private func save() {
        guard existing != nil || connections.isEmpty || purchaseManager.isUnlocked else {
            showsPaywall = true
            return
        }

        let connection = existing ?? Connection(name: name, driverID: driverID)
        let draft = currentDraft.normalized
        draft.apply(to: connection)

        do {
            let existingSecret = try? KeychainSecretStore().secret(for: connection.id)
            let secretDraft = currentSecretDraft
            var secret = secretDraft.merged(with: existingSecret, authenticationMode: draft.authenticationMode)
            switch draft.style {
            case .file:
                secret = existingSecret ?? Secret()
            case .httpEndpoint:
                if password.isEmpty { secret.apiToken = existingSecret?.apiToken }
            case .server:
                if authenticationMode != .password, authenticationMode != .vaultOIDC {
                    secret.password = existingSecret?.password
                }
                if authenticationMode != .awsIAM {
                    secret.awsAccessKeyID = existingSecret?.awsAccessKeyID
                    secret.awsSecretAccessKey = existingSecret?.awsSecretAccessKey
                    secret.awsSessionToken = existingSecret?.awsSessionToken
                }
                if !sshTunnelEnabled {
                    secret.sshPassword = existingSecret?.sshPassword
                    secret.sshPrivateKey = existingSecret?.sshPrivateKey
                    secret.sshPassphrase = existingSecret?.sshPassphrase
                }
            }

            if secret.hasPersistedValue {
                try KeychainSecretStore().save(secret, for: connection.id)
            } else if draft.authenticationMode == .vaultOIDC {
                try KeychainSecretStore().delete(for: connection.id)
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

    private func refreshSQLiteBookmarkIfPossible() {
        #if os(macOS)
        guard isFileBased else { return }
        let trimmed = database.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, FileManager.default.isReadableFile(atPath: trimmed) else { return }
        let url = URL(fileURLWithPath: trimmed)
        if bookmarkData == nil, let bookmark = try? url.bookmarkData(options: bookmarkCreationOptions) {
            bookmarkData = bookmark
        }
        let folderURL = url.deletingLastPathComponent()
        if !isReadOnly, containerBookmarkData == nil,
           let bookmark = try? folderURL.bookmarkData(options: bookmarkCreationOptions) {
            containerBookmarkData = bookmark
        }
        #endif
    }

    private func saveAfterUnlock() {
        if purchaseManager.isUnlocked { save() }
    }
}

private extension DatabaseDriver {
    var idString: String { type(of: self).id }
}
