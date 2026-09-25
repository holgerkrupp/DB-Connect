import Foundation

/// The non-secret, value-type state used while creating or editing a connection.
///
/// This type intentionally contains the fields that are safe to keep in SwiftUI state,
/// restore with a view, or pass between editor surfaces. Passwords, API keys, and private
/// keys live in `ConnectionSecretDraft` and are never part of this value.
nonisolated struct ConnectionDraft: Hashable, Sendable {
    var id: UUID?
    var name = ""
    var driverID = SQLiteDriver.id
    var host = ""
    var port = 0
    var database = ""
    var username = ""
    var isReadOnly = false
    var tlsMode: TLSMode = .required
    var certificatePEM = ""
    var certificateFingerprint: String?
    var bookmarkData: Data?
    var containerBookmarkData: Data?
    var fileAccessOwnerDeviceID: String?
    var fileAccessOwnerDeviceName: String?
    var transportMode: ConnectionTransportMode = .tcp
    var socketPath = ""
    var authenticationMode: DatabaseAuthenticationMode = .password
    var awsRegion = ""
    var vaultServerURL = ""
    var vaultAuthMount = "oidc"
    var vaultRole = ""
    var vaultDatabaseMount = "database"
    var vaultDatabaseRole = ""
    var sshTunnelEnabled = false
    var sshHost = ""
    var sshPort = 22
    var sshUsername = ""
    var sshAuthenticationMode: SSHTunnelAuthenticationMode = .agent

    init(id: UUID? = nil) {
        self.id = id
    }

    @MainActor
    init(connection: Connection) {
        id = connection.id
        name = connection.name
        driverID = connection.driverID
        host = connection.host
        port = connection.port
        database = connection.database
        username = connection.username
        isReadOnly = connection.isReadOnly
        tlsMode = TLSMode(rawValue: connection.tlsMode) ?? .required
        certificatePEM = connection.pinnedCertificatePEM ?? ""
        certificateFingerprint = connection.certificateFingerprint
        bookmarkData = connection.fileBookmark
        containerBookmarkData = connection.fileContainerBookmark
        fileAccessOwnerDeviceID = connection.fileAccessOwnerDeviceID
        fileAccessOwnerDeviceName = connection.fileAccessOwnerDeviceName
        transportMode = connection.transport
        socketPath = connection.socketPath
        authenticationMode = DatabaseAuthenticationMode(rawValue: connection.authenticationMode) ?? .password
        awsRegion = connection.awsRegion
        vaultServerURL = connection.vaultServerURL
        vaultAuthMount = connection.vaultAuthMount
        vaultRole = connection.vaultRole
        vaultDatabaseMount = connection.vaultDatabaseMount
        vaultDatabaseRole = connection.vaultDatabaseRole
        sshTunnelEnabled = connection.sshTunnelEnabled
        sshHost = connection.sshHost
        sshPort = connection.sshPort
        sshUsername = connection.sshUsername
        sshAuthenticationMode = SSHTunnelAuthenticationMode(rawValue: connection.sshAuthenticationMode) ?? .agent
    }

    @MainActor
    init(existing connection: Connection) {
        self.init(connection: connection)
    }

    var style: DriverRegistry.ConnectionStyle {
        DriverRegistry.style(for: driverID)
    }

    var isFileBased: Bool {
        style == .file
    }

    var supportsSocketConnections: Bool {
        driverID == MySQLDriver.id
    }

    var supportsAWSIAM: Bool {
        driverID == MySQLDriver.id && transportMode == .tcp
    }

    var supportsSSHTunnel: Bool {
        #if os(macOS)
        style == .server && transportMode == .tcp
        #else
        false
        #endif
    }

    /// Applies the form's driver transition rules in one testable place.
    mutating func didChangeDriver(to newDriverID: String) {
        let defaults = DriverRegistry.all.map { DriverRegistry.defaultPort(for: type(of: $0).id) }
        if port == 0 || defaults.contains(port) {
            port = DriverRegistry.defaultPort(for: newDriverID)
        }
        driverID = newDriverID
        if newDriverID != MySQLDriver.id {
            transportMode = .tcp
            socketPath = ""
            authenticationMode = .password
        }
        if style != .server {
            sshTunnelEnabled = false
        }
    }

    /// Applies the transport transition rules in one testable place.
    mutating func didChangeTransport(to newTransportMode: ConnectionTransportMode) {
        transportMode = newTransportMode
        if newTransportMode == .unixSocket {
            sshTunnelEnabled = false
            tlsMode = .disabled
            authenticationMode = .password
        }
    }

    /// A normalized draft suitable for persistence and runtime configuration.
    var normalized: ConnectionDraft {
        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        result.database = database.trimmingCharacters(in: .whitespacesAndNewlines)
        result.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        result.socketPath = transportMode == .unixSocket
            ? socketPath.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        result.awsRegion = authenticationMode == .awsIAM
            ? awsRegion.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        result.vaultServerURL = authenticationMode == .vaultOIDC
            ? vaultServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        result.vaultAuthMount = authenticationMode == .vaultOIDC
            ? vaultAuthMount.trimmingCharacters(in: .whitespacesAndNewlines)
            : "oidc"
        result.vaultRole = authenticationMode == .vaultOIDC
            ? vaultRole.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        result.vaultDatabaseMount = authenticationMode == .vaultOIDC
            ? vaultDatabaseMount.trimmingCharacters(in: .whitespacesAndNewlines)
            : "database"
        result.vaultDatabaseRole = authenticationMode == .vaultOIDC
            ? vaultDatabaseRole.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        result.sshHost = sshTunnelEnabled ? sshHost.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        result.sshUsername = sshTunnelEnabled ? sshUsername.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        result.sshPort = sshTunnelEnabled ? sshPort : 22
        result.sshAuthenticationMode = sshTunnelEnabled ? sshAuthenticationMode : .agent
        return result
    }

    /// Maps the safe half of the draft to the common runtime configuration.
    var config: ConnectionConfig {
        let draft = normalized
        return ConnectionConfig(
            driverID: draft.driverID,
            host: draft.host,
            port: draft.port,
            database: draft.database,
            username: draft.username,
            isReadOnly: draft.isReadOnly,
            tls: draft.tlsMode,
            certificateFingerprint: draft.certificateFingerprint,
            pinnedCertificatePEM: draft.certificatePEM.isEmpty ? nil : draft.certificatePEM,
            socketPath: draft.socketPath,
            authentication: DatabaseAuthenticationConfiguration(
                mode: draft.authenticationMode,
                awsRegion: draft.awsRegion,
                vault: draft.vaultAuthenticationConfiguration
            ),
            sshTunnel: draft.sshTunnelEnabled
                ? SSHTunnelConfiguration(
                    host: draft.sshHost,
                    port: draft.sshPort,
                    username: draft.sshUsername,
                    authenticationMode: draft.sshAuthenticationMode
                )
                : nil
        )
    }

    var vaultAuthenticationConfiguration: VaultAuthenticationConfiguration? {
        guard authenticationMode == .vaultOIDC,
              let serverURL = URL(string: vaultServerURL),
              !vaultRole.isEmpty,
              !vaultDatabaseRole.isEmpty else {
            return nil
        }
        return VaultAuthenticationConfiguration(
            serverURL: serverURL,
            authMount: vaultAuthMount,
            role: vaultRole,
            databaseMount: vaultDatabaseMount,
            databaseRole: vaultDatabaseRole
        )
    }

    /// Returns a user-facing validation message, or nil when the draft can be saved.
    func validationIssue(secrets: ConnectionSecretDraft) -> String? {
        switch style {
        case .file:
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
        case .server:
            if transportMode == .unixSocket {
                if socketPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "Enter a local socket path."
                }
            } else if host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Enter a host."
            }

            if authenticationMode == .awsIAM {
                if awsRegion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "Enter an AWS region."
                }
                let hasTypedCredentials = !secrets.awsAccessKeyID.isEmpty && !secrets.awsSecretAccessKey.isEmpty
                if !hasTypedCredentials && !secrets.hasStoredAWSCredentials {
                    return "Enter AWS credentials or keep the credentials stored in Keychain."
                }
            }

            if authenticationMode == .vaultOIDC {
                guard driverID == MySQLDriver.id, transportMode == .tcp else {
                    return "Vault OIDC authentication requires a MySQL TCP connection."
                }
                guard let serverURL = URL(string: vaultServerURL),
                      serverURL.scheme?.lowercased() == "https",
                      serverURL.host != nil else {
                    return "Enter a valid HTTPS Vault server URL."
                }
                guard !vaultAuthMount.isEmpty, !vaultRole.isEmpty,
                      !vaultDatabaseMount.isEmpty, !vaultDatabaseRole.isEmpty else {
                    return "Enter the Vault auth mount, role, database mount, and database role."
                }
            }

            if sshTunnelEnabled {
                if sshHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    sshUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "Enter an SSH host and username."
                }
                switch sshAuthenticationMode {
                case .agent:
                    break
                case .password where secrets.sshPassword.isEmpty && !secrets.hasStoredSSHPassword:
                    return "Enter an SSH password or keep the password stored in Keychain."
                case .privateKey where secrets.sshPrivateKey.isEmpty && !secrets.hasStoredSSHPrivateKey:
                    return "Import an SSH private key or keep the key stored in Keychain."
                case .password, .privateKey:
                    break
                }
            }
            return nil
        case .httpEndpoint:
            guard !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Enter a project URL."
            }
            return secrets.password.isEmpty && !secrets.hasStoredDatabasePassword
                ? "Enter an API key or keep the key stored in Keychain."
                : nil
        }
    }

    func canSave(secrets: ConnectionSecretDraft) -> Bool {
        validationIssue(secrets: secrets) == nil
    }

    /// Applies this draft to an existing or newly-created SwiftData model.
    @MainActor
    func apply(to connection: Connection) {
        let draft = normalized
        connection.name = draft.name
        connection.driverID = draft.driverID
        connection.host = draft.host
        connection.port = draft.port
        connection.database = draft.database
        connection.username = draft.username
        connection.isReadOnly = draft.isReadOnly
        connection.tlsMode = draft.tlsMode.rawValue
        connection.pinnedCertificatePEM = draft.certificatePEM.isEmpty ? nil : draft.certificatePEM
        connection.certificateFingerprint = draft.certificateFingerprint
        connection.transportMode = draft.transportMode.rawValue
        connection.socketPath = draft.socketPath
        connection.authenticationMode = draft.authenticationMode.rawValue
        connection.awsRegion = draft.awsRegion
        connection.vaultServerURL = draft.vaultServerURL
        connection.vaultAuthMount = draft.vaultAuthMount
        connection.vaultRole = draft.vaultRole
        connection.vaultDatabaseMount = draft.vaultDatabaseMount
        connection.vaultDatabaseRole = draft.vaultDatabaseRole
        connection.sshTunnelEnabled = draft.sshTunnelEnabled
        connection.sshHost = draft.sshHost
        connection.sshPort = draft.sshPort
        connection.sshUsername = draft.sshUsername
        connection.sshAuthenticationMode = draft.sshAuthenticationMode.rawValue
        connection.fileBookmark = draft.bookmarkData
        connection.fileContainerBookmark = draft.containerBookmarkData
        connection.fileAccessOwnerDeviceID = draft.fileAccessOwnerDeviceID
        connection.fileAccessOwnerDeviceName = draft.fileAccessOwnerDeviceName
    }
}

/// In-memory secret input and Keychain-presence state for a connection editor.
///
/// This type deliberately has no Codable conformance and is never stored on `Connection`.
nonisolated struct ConnectionSecretDraft: Hashable, Sendable {
    var password = ""
    var awsAccessKeyID = ""
    var awsSecretAccessKey = ""
    var awsSessionToken = ""
    var sshPassword = ""
    var sshPrivateKey = ""
    var sshPassphrase = ""

    var hasStoredDatabasePassword = false
    var hasStoredAWSCredentials = false
    var hasStoredSSHPassword = false
    var hasStoredSSHPrivateKey = false

    /// True only for values entered in the current editor session; Keychain-presence flags are
    /// intentionally excluded so a favorite can reuse its stored secret without re-persisting it.
    var hasTypedValues: Bool {
        !password.isEmpty || !awsAccessKeyID.isEmpty || !awsSecretAccessKey.isEmpty
            || !awsSessionToken.isEmpty || !sshPassword.isEmpty || !sshPrivateKey.isEmpty
            || !sshPassphrase.isEmpty
    }

    init() {}

    init(stored secret: Secret?) {
        hasStoredDatabasePassword = !(secret?.password ?? secret?.apiToken ?? "").isEmpty
        hasStoredAWSCredentials = !(secret?.awsAccessKeyID ?? "").isEmpty && !(secret?.awsSecretAccessKey ?? "").isEmpty
        hasStoredSSHPassword = !(secret?.sshPassword ?? "").isEmpty
        hasStoredSSHPrivateKey = !(secret?.sshPrivateKey ?? "").isEmpty
    }

    /// Merges newly entered values into the existing secret, preserving blank unchanged fields.
    func merged(
        with existing: Secret?,
        authenticationMode: DatabaseAuthenticationMode = .password
    ) -> Secret {
        var secret = existing ?? Secret()
        if authenticationMode == .vaultOIDC {
            // Vault supplies a short-lived password immediately before connect. A static
            // password must not survive switching this connection to Vault mode.
            secret = secret.removingStaticDatabasePassword(for: authenticationMode)
        } else if !password.isEmpty {
            secret.password = password
        }
        if !awsAccessKeyID.isEmpty { secret.awsAccessKeyID = awsAccessKeyID.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !awsSecretAccessKey.isEmpty { secret.awsSecretAccessKey = awsSecretAccessKey }
        if !awsSessionToken.isEmpty { secret.awsSessionToken = awsSessionToken }
        if !sshPassword.isEmpty { secret.sshPassword = sshPassword }
        if !sshPrivateKey.isEmpty { secret.sshPrivateKey = sshPrivateKey }
        if !sshPassphrase.isEmpty { secret.sshPassphrase = sshPassphrase }
        return secret
    }
}
