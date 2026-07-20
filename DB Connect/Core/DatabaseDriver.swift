import Foundation

nonisolated enum TLSMode: String, Sendable, Hashable, CaseIterable {
    case disabled
    case preferred
    case required
    /// TLS with an explicitly trusted certificate fingerprint — the common case for self-signed
    /// database servers, where full chain validation would fail but blind trust is unacceptable.
    case pinned
}

/// Everything needed to reach a database except the secret.
///
/// Secrets deliberately live only in the Keychain (`DBSecrets`) and are passed separately at
/// connect time, so a config can be synced, logged, and diffed without leaking a password.
nonisolated struct ConnectionConfig: Sendable, Hashable {
    var driverID: String
    var host: String
    var port: Int
    /// For file-based drivers such as SQLite this holds the file path.
    var database: String
    var username: String
    var tls: TLSMode
    var certificateFingerprint: String?
    /// The server certificate to pin to, PEM encoded. Public data, so it lives with the config
    /// rather than in the Keychain.
    var pinnedCertificatePEM: String?
    /// Driver-specific extras, kept out of the typed surface so adding a driver needs no core change.
    var options: [String: String]

    init(
        driverID: String,
        host: String = "",
        port: Int = 0,
        database: String = "",
        username: String = "",
        tls: TLSMode = .required,
        certificateFingerprint: String? = nil,
        pinnedCertificatePEM: String? = nil,
        options: [String: String] = [:]
    ) {
        self.driverID = driverID
        self.host = host
        self.port = port
        self.database = database
        self.username = username
        self.tls = tls
        self.certificateFingerprint = certificateFingerprint
        self.pinnedCertificatePEM = pinnedCertificatePEM
        self.options = options
    }
}

/// What a driver can do. The UI reads this to disable affordances up front rather than letting
/// the user compose an edit that fails on commit.
nonisolated struct DriverCapabilities: Sendable, Hashable {
    let canEditRows: Bool
    let canRunArbitrarySQL: Bool
    let supportsTransactions: Bool
    let supportsSchemas: Bool
    let requiresCredentials: Bool

    init(
        canEditRows: Bool,
        canRunArbitrarySQL: Bool,
        supportsTransactions: Bool,
        supportsSchemas: Bool,
        requiresCredentials: Bool
    ) {
        self.canEditRows = canEditRows
        self.canRunArbitrarySQL = canRunArbitrarySQL
        self.supportsTransactions = supportsTransactions
        self.supportsSchemas = supportsSchemas
        self.requiresCredentials = requiresCredentials
    }
}

nonisolated enum DatabaseError: Error, Sendable, Equatable {
    case connectionFailed(String)
    case notConnected
    case queryFailed(sql: String, message: String)
    case unsupported(String)
    case invalidIdentifier(String)
    case tableNotFound(String)
    case readOnly(reason: String)
    case missingCredentials
}

nonisolated extension DatabaseError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .connectionFailed(let m): "Could not connect: \(m)"
        case .notConnected: "The connection is closed."
        case .queryFailed(_, let m): m
        case .unsupported(let m): m
        case .invalidIdentifier(let m): m
        case .tableNotFound(let name): "No table named “\(name)”."
        case .readOnly(let reason): reason
        case .missingCredentials: "No stored credentials for this connection."
        }
    }
}

/// The secret half of a connection. Opaque on purpose — see `DBSecrets`.
nonisolated struct Secret: Sendable, Hashable, Codable {
    var password: String?
    var apiToken: String?
    var sshPrivateKey: String?
    var sshPassphrase: String?

    init(password: String? = nil, apiToken: String? = nil, sshPrivateKey: String? = nil, sshPassphrase: String? = nil) {
        self.password = password
        self.apiToken = apiToken
        self.sshPrivateKey = sshPrivateKey
        self.sshPassphrase = sshPassphrase
    }
}

nonisolated protocol DatabaseDriver: Sendable {
    /// Stable identifier persisted in `Connection.driverID`. Never change it once shipped.
    static var id: String { get }
    static var displayName: String { get }
    var capabilities: DriverCapabilities { get }

    func connect(config: ConnectionConfig, secret: Secret?) async throws -> any DatabaseSession
}

nonisolated protocol DatabaseSession: Sendable {
    var capabilities: DriverCapabilities { get }

    /// Databases the account can see. Empty when the driver has no such concept (SQLite).
    func databases() async throws -> [String]
    /// Switch the active database without reconnecting. Throws if the driver cannot.
    func use(database: String) async throws
    /// The database currently in use, if any.
    var currentDatabase: String? { get async }

    func tables() async throws -> [TableDescriptor]
    func describe(table: String, schema: String?) async throws -> TableDescriptor
    func fetch(_ request: RowRequest) async throws -> ResultSet

    /// Total rows matching the request's filters, ignoring its paging.
    /// Nil when the driver cannot count cheaply — the UI then hides the total.
    func count(_ request: RowRequest) async throws -> Int?
    func query(_ statement: Statement) async throws -> ResultSet
    func execute(_ statement: Statement) async throws -> ExecutionResult

    /// Apply a batch of row edits. Drivers that report `supportsTransactions` must apply the
    /// whole batch atomically — all or nothing.
    func apply(_ mutations: [RowMutation], to table: TableDescriptor) async throws -> ExecutionResult

    /// What `apply` would do, for the review sheet shown before committing.
    /// SQL drivers return statements; REST drivers return request lines.
    func preview(_ mutations: [RowMutation], to table: TableDescriptor) throws -> [String]

    // MARK: User management

    /// What this *connection* may do with accounts — not just what the driver supports.
    /// Each action is gated separately, so a limited account gets the buttons it can use.
    var userAdmin: UserAdminCapability { get async }

    func users() async throws -> [DatabaseUser]
    func grants(for user: DatabaseUser) async throws -> [String]
    func createUser(name: String, host: String?, password: String) async throws
    func dropUser(_ user: DatabaseUser) async throws
    func setPassword(for user: DatabaseUser, to password: String) async throws
    func grant(_ privileges: [Privilege], on scope: GrantScope, to user: DatabaseUser) async throws
    func revoke(_ privileges: [Privilege], on scope: GrantScope, from user: DatabaseUser) async throws

    func close() async
}

nonisolated extension DatabaseSession {
    /// Drivers with a single fixed database (SQLite, PostgREST) inherit these.
    func databases() async throws -> [String] { [] }

    func use(database: String) async throws {
        throw DatabaseError.unsupported("This connection cannot switch databases.")
    }

    var currentDatabase: String? {
        get async { nil }
    }

    func count(_ request: RowRequest) async throws -> Int? { nil }

    // User management is opt-in: drivers that do not implement it report no capability and
    // throw, so the UI never offers an action that cannot work.
    var userAdmin: UserAdminCapability {
        get async { .none }
    }

    func users() async throws -> [DatabaseUser] {
        throw DatabaseError.unsupported("This connection does not support user management.")
    }

    func grants(for user: DatabaseUser) async throws -> [String] {
        throw DatabaseError.unsupported("This connection does not support user management.")
    }

    func createUser(name: String, host: String?, password: String) async throws {
        throw DatabaseError.unsupported("This connection does not support user management.")
    }

    func dropUser(_ user: DatabaseUser) async throws {
        throw DatabaseError.unsupported("This connection does not support user management.")
    }

    func setPassword(for user: DatabaseUser, to password: String) async throws {
        throw DatabaseError.unsupported("This connection does not support user management.")
    }

    func grant(_ privileges: [Privilege], on scope: GrantScope, to user: DatabaseUser) async throws {
        throw DatabaseError.unsupported("This connection does not support user management.")
    }

    func revoke(_ privileges: [Privilege], on scope: GrantScope, from user: DatabaseUser) async throws {
        throw DatabaseError.unsupported("This connection does not support user management.")
    }

    /// Shared implementation for SQL drivers: build one parameterized statement per mutation.
    func sqlPreview(_ mutations: [RowMutation], to table: TableDescriptor, dialect: SQLDialect) throws -> [String] {
        try mutations.map { mutation in
            let statement = try MutationBuilder.statement(for: mutation, table: table, dialect: dialect)
            guard !statement.bindings.isEmpty else { return statement.sql }
            let values = statement.bindings.map(\.displayText).joined(separator: ", ")
            return "\(statement.sql)\n   ⤷ \(values)"
        }
    }
}
