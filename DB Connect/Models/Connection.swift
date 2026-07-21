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
    /// Security-scoped bookmark for file-based drivers, so a sandboxed app can reopen the
    /// user-picked file after relaunch. Device-specific by nature — it will not sync usefully.
    var fileBookmark: Data?
    var sortOrder: Int = 0
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .cascade, inverse: \SavedQuery.connection)
    var savedQueries: [SavedQuery]? = []

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
            tls: TLSMode(rawValue: tlsMode) ?? .required,
            certificateFingerprint: certificateFingerprint,
            pinnedCertificatePEM: pinnedCertificatePEM
        )
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
