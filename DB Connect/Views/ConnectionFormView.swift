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
        #if os(macOS)
        return SQLiteFileAccessRequirement.issue(
            path: database,
            hasFileBookmark: bookmarkData != nil,
            hasContainerBookmark: containerBookmarkData != nil,
            isReadOnly: isReadOnly
        )
        #else
        return database.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Choose a SQLite database file."
            : nil
        #endif
    }

    private var canSave: Bool {
        switch style {
        case .file:
            return sqliteFileAccessIssue == nil
        case .server:
            if transportMode == .unixSocket {
                guard !socketPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            } else {
                guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            }

            if authenticationMode == .awsIAM {
                let hasTyped = !awsAccessKeyID.isEmpty && !awsSecretAccessKey.isEmpty
                guard !awsRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                guard hasTyped || hasStoredAWSCredentials else { return false }
            }

            if sshTunnelEnabled {
                guard !sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      !sshUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else { return false }
                switch sshAuthenticationMode {
                case .agent:
                    break
                case .password:
                    guard !sshPassword.isEmpty || hasStoredSSHPassword else { return false }
                case .privateKey:
                    guard !sshPrivateKey.isEmpty || hasStoredSSHPrivateKey else { return false }
                }
            }

            return true
        case .httpEndpoint:
            return !host.isEmpty && (!password.isEmpty || hasStoredDatabasePassword)
        }
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
            let defaults = DriverRegistry.all.map { DriverRegistry.defaultPort(for: type(of: $0).id) }
            if port == 0 || defaults.contains(port) {
                port = DriverRegistry.defaultPort(for: newValue)
            }
            if newValue != MySQLDriver.id {
                transportMode = .tcp
                socketPath = ""
                authenticationMode = .password
            }
            if style != .server {
                sshTunnelEnabled = false
            }
        }
        .onChange(of: transportMode) { _, newValue in
            if newValue == .unixSocket {
                sshTunnelEnabled = false
                tlsMode = .disabled
                authenticationMode = .password
            }
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
                 : "Use the anon or service role key. It is stored in your iCloud Keychain, never in the synced database.")
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
        transportMode = existing.transport
        socketPath = existing.socketPath
        authenticationMode = DatabaseAuthenticationMode(rawValue: existing.authenticationMode) ?? .password
        awsRegion = existing.awsRegion
        sshTunnelEnabled = existing.sshTunnelEnabled
        sshHost = existing.sshHost
        sshPort = existing.sshPort
        sshUsername = existing.sshUsername
        sshAuthenticationMode = SSHTunnelAuthenticationMode(rawValue: existing.sshAuthenticationMode) ?? .agent
        bookmarkData = existing.fileBookmark
        containerBookmarkData = existing.fileContainerBookmark
        fileAccessOwnerDeviceID = existing.fileAccessOwnerDeviceID
        fileAccessOwnerDeviceName = existing.fileAccessOwnerDeviceName

        let storedSecret = try? KeychainSecretStore().secret(for: existing.id)
        hasStoredDatabasePassword = !(storedSecret?.password ?? storedSecret?.apiToken ?? "").isEmpty
        hasStoredAWSCredentials = !(storedSecret?.awsAccessKeyID ?? "").isEmpty && !(storedSecret?.awsSecretAccessKey ?? "").isEmpty
        hasStoredSSHPassword = !(storedSecret?.sshPassword ?? "").isEmpty
        hasStoredSSHPrivateKey = !(storedSecret?.sshPrivateKey ?? "").isEmpty
        refreshSQLiteBookmarkIfPossible()
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
        connection.name = name
        connection.driverID = driverID
        connection.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.port = port
        connection.database = database.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        connection.isReadOnly = isReadOnly
        connection.tlsMode = tlsMode.rawValue
        connection.pinnedCertificatePEM = certificatePEM.isEmpty ? nil : certificatePEM
        connection.certificateFingerprint = certificateFingerprint
        connection.transportMode = transportMode.rawValue
        connection.socketPath = transportMode == .unixSocket ? socketPath.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        connection.authenticationMode = authenticationMode.rawValue
        connection.awsRegion = authenticationMode == .awsIAM ? awsRegion.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        connection.sshTunnelEnabled = sshTunnelEnabled
        connection.sshHost = sshTunnelEnabled ? sshHost.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        connection.sshPort = sshTunnelEnabled ? sshPort : 22
        connection.sshUsername = sshTunnelEnabled ? sshUsername.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        connection.sshAuthenticationMode = sshTunnelEnabled ? sshAuthenticationMode.rawValue : SSHTunnelAuthenticationMode.agent.rawValue
        connection.fileBookmark = bookmarkData
        connection.fileContainerBookmark = containerBookmarkData
        connection.fileAccessOwnerDeviceID = fileAccessOwnerDeviceID
        connection.fileAccessOwnerDeviceName = fileAccessOwnerDeviceName

        do {
            var secret = (try? KeychainSecretStore().secret(for: connection.id)) ?? Secret()
            switch style {
            case .file:
                break
            case .httpEndpoint:
                if !password.isEmpty {
                    secret.apiToken = password
                }
            case .server:
                if authenticationMode == .password, !password.isEmpty {
                    secret.password = password
                }
                if authenticationMode == .awsIAM {
                    if !awsAccessKeyID.isEmpty {
                        secret.awsAccessKeyID = awsAccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    if !awsSecretAccessKey.isEmpty {
                        secret.awsSecretAccessKey = awsSecretAccessKey
                    }
                    if !awsSessionToken.isEmpty {
                        secret.awsSessionToken = awsSessionToken
                    }
                }
                if sshTunnelEnabled {
                    switch sshAuthenticationMode {
                    case .agent:
                        break
                    case .password:
                        if !sshPassword.isEmpty {
                            secret.sshPassword = sshPassword
                        }
                    case .privateKey:
                        if !sshPrivateKey.isEmpty {
                            secret.sshPrivateKey = sshPrivateKey
                        }
                        if !sshPassphrase.isEmpty {
                            secret.sshPassphrase = sshPassphrase
                        }
                    }
                }
            }

            if secret.hasPersistedValue {
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
