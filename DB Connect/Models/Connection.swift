import Foundation
import SwiftData

/// A saved database connection. Synced via CloudKit in phase 2, which is why every property
/// has a default and no attribute is `.unique` — CloudKit-backed SwiftData forbids both.
///
/// The password is deliberately absent: secrets live in the iCloud Keychain, keyed by `id`
/// (see `KeychainSecretStore`), so this record can sync and appear in logs without leaking.
@Model
final class Connection {
    var id: UUID = UUID()
    var name: String = ""
    var driverID: String = "sqlite"
    var host: String = ""
    var port: Int = 0
    /// Database name — or the file path for file-based drivers such as SQLite.
    var database: String = ""
    var username: String = ""
    var tlsMode: String = TLSMode.required.rawValue
    /// Shown so the user can compare it against what their administrator quotes.
    var certificateFingerprint: String?
    /// PEM of the pinned server certificate. Not secret — it is the server's public identity.
    var pinnedCertificatePEM: String?
    /// When set, the UI refuses all writes on this connection regardless of driver capabilities.
    var isReadOnly: Bool = false
    var transportMode: String = ConnectionTransportMode.tcp.rawValue
    var socketPath: String = ""
    var authenticationMode: String = DatabaseAuthenticationMode.password.rawValue
    var awsRegion: String = ""
    /// Non-secret Vault OIDC/database-role configuration. Vault tokens and leased DB passwords
    /// stay in Keychain/runtime memory and are never part of this model.
    var vaultServerURL: String = ""
    var vaultAuthMount: String = "oidc"
    var vaultRole: String = ""
    var vaultDatabaseMount: String = "database"
    var vaultDatabaseRole: String = ""
    var sshTunnelEnabled: Bool = false
    var sshHost: String = ""
    var sshPort: Int = 22
    var sshUsername: String = ""
    var sshAuthenticationMode: String = SSHTunnelAuthenticationMode.agent.rawValue
    /// Security-scoped bookmark for file-based drivers, so a sandboxed app can reopen the
    /// user-picked file after relaunch. Device-specific by nature — it will not sync usefully.
    var fileBookmark: Data?
    /// SQLite commonly needs sibling WAL, SHM, or rollback-journal files beside the database.
    /// A folder bookmark gives the sandbox access to those companion files when the connection
    /// is writable.
    var fileContainerBookmark: Data?
    /// Remembers which device last granted local file access, so a synced SQLite connection can
    /// explain why it is inactive on another device instead of just failing to connect.
    var fileAccessOwnerDeviceID: String?
    var fileAccessOwnerDeviceName: String?
    /// Optional favorite metadata. These fields are additive/defaulted for existing CloudKit rows.
    var favoriteColor: String = FavoriteColor.none.rawValue
    var favoriteTag: String = ""
    /// Groups are separate records so an empty group can exist and renaming does not require
    /// rewriting every connection. The UUID is intentionally not a SwiftData relationship:
    /// CloudKit can merge records independently and removing a group must never delete a favorite.
    var favoriteGroupID: UUID?
    /// Manual order within the group. Zero means legacy/unassigned ordering.
    var favoriteOrder: Int = 0
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \SavedQuery.connection)
    var savedQueries: [SavedQuery]? = []

    @Relationship(deleteRule: .cascade, inverse: \QueryFavorite.connection)
    var queryFavorites: [QueryFavorite]? = []

    /// Automatically recorded statements. Cascade: history is meaningless without its connection.
    @Relationship(deleteRule: .cascade, inverse: \QueryHistoryEntry.connection)
    var history: [QueryHistoryEntry]? = []

    init(name: String, driverID: String) {
        self.name = name
        self.driverID = driverID
    }

    var config: ConnectionConfig {
        ConnectionConfig(
            driverID: driverID,
            host: host,
            port: port,
            database: database,
            username: username,
            isReadOnly: isReadOnly,
            tls: TLSMode(rawValue: tlsMode) ?? .required,
            certificateFingerprint: certificateFingerprint,
            pinnedCertificatePEM: pinnedCertificatePEM,
            socketPath: transport == .unixSocket ? socketPath : "",
            authentication: DatabaseAuthenticationConfiguration(
                mode: DatabaseAuthenticationMode(rawValue: authenticationMode) ?? .password,
                awsRegion: awsRegion,
                vault: vaultAuthenticationConfiguration
            ),
            sshTunnel: sshTunnelEnabled
                ? SSHTunnelConfiguration(
                    host: sshHost,
                    port: sshPort,
                    username: sshUsername,
                    authenticationMode: SSHTunnelAuthenticationMode(rawValue: sshAuthenticationMode) ?? .agent
                )
                : nil
        )
    }

    var transport: ConnectionTransportMode {
        ConnectionTransportMode(rawValue: transportMode) ?? .tcp
    }

    var vaultAuthenticationConfiguration: VaultAuthenticationConfiguration? {
        guard DatabaseAuthenticationMode(rawValue: authenticationMode) == .vaultOIDC else {
            return nil
        }
        guard let serverURL = URL(string: vaultServerURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              !vaultRole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !vaultDatabaseRole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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

    var favoriteColorValue: FavoriteColor {
        FavoriteColor(rawValue: favoriteColor) ?? .none
    }
}

/// A CloudKit-compatible favorite folder. Connections refer to it by UUID instead of a deleting
/// relationship, so deleting a group simply unassigns its connections.
@Model
final class ConnectionFavoriteGroup {
    var id: UUID = UUID()
    var name: String = ""
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    init(name: String, sortOrder: Int = 0) {
        self.name = name
        self.sortOrder = sortOrder
    }
}

@Model
final class SavedQuery {
    var id: UUID = UUID()
    var title: String = ""
    var sql: String = ""
    /// The database this query was written against — captured from the console's active
    /// database when saved. Server-level connections (typically MySQL) leave `Connection.database`
    /// empty and pick a database interactively, so without this a monitor would reconnect with no
    /// database selected and fail with "No database selected". Empty means "use the connection's
    /// own database", which covers file-based drivers and connections bound to a single database.
    var database: String = ""
    var createdAt: Date = Date.now
    var connection: Connection?

    /// Inverse of `Monitor.query`. CloudKit refuses to load a store containing any relationship
    /// without one, so this must exist even though the app rarely navigates in this direction.
    /// Deleting a query takes its monitors with it — a monitor without a query cannot run.
    @Relationship(deleteRule: .cascade, inverse: \Monitor.query)
    var monitors: [Monitor]? = []

    /// Inverse of `MonitorField.query`. Nullify rather than cascade: losing a detail query
    /// should leave its token unresolved, not delete the whole monitor.
    @Relationship(deleteRule: .nullify, inverse: \MonitorField.query)
    var monitorFields: [MonitorField]? = []

    init(title: String, sql: String) {
        self.title = title
        self.sql = sql
    }
}

nonisolated enum QueryFavoriteScope: String, Sendable, Hashable, CaseIterable, Identifiable {
    case connection
    case global

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connection: "This Connection"
        case .global: "Global"
        }
    }
}

@Model
final class QueryFavorite {
    var id: UUID = UUID()
    var title: String = ""
    var sql: String = ""
    var tabTrigger: String = ""
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    /// Nil means a global favorite; otherwise it is scoped to one connection.
    var connection: Connection?

    init(title: String, sql: String, tabTrigger: String = "") {
        self.title = title
        self.sql = sql
        self.tabTrigger = tabTrigger
    }

    var scope: QueryFavoriteScope {
        connection == nil ? .global : .connection
    }

    func update(title: String, sql: String, tabTrigger: String, connection: Connection?) {
        self.title = title
        self.sql = sql
        self.tabTrigger = tabTrigger
        self.connection = connection
        self.updatedAt = .now
    }
}
