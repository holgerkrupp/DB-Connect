import Foundation

/// An account on the database server.
nonisolated struct DatabaseUser: Sendable, Hashable, Identifiable {
    /// MySQL identifies accounts by name *and* host; PostgreSQL by name alone.
    var id: String { host.map { "\(name)@\($0)" } ?? name }

    let name: String
    let host: String?
    let canLogin: Bool
    let isSuperuser: Bool
    /// Extra flags worth showing, e.g. "create db", "replication".
    let attributes: [String]

    init(name: String, host: String? = nil, canLogin: Bool = true, isSuperuser: Bool = false, attributes: [String] = []) {
        self.name = name
        self.host = host
        self.canLogin = canLogin
        self.isSuperuser = isSuperuser
        self.attributes = attributes
    }

    var displayName: String {
        host.map { "\(name)@\($0)" } ?? name
    }

    /// A host of `%` means "from anywhere", which is worth surfacing in the UI.
    var isOpenToAnyHost: Bool {
        host == "%"
    }
}

/// The privileges this app offers to grant or revoke.
///
/// Deliberately a curated list rather than every privilege the server supports: these cover
/// ordinary use, and anything more exotic is better done in the SQL console where the user
/// can see exactly what they are running.
nonisolated enum Privilege: String, Sendable, CaseIterable, Identifiable {
    case select = "SELECT"
    case insert = "INSERT"
    case update = "UPDATE"
    case delete = "DELETE"
    case create = "CREATE"
    case drop = "DROP"
    case alter = "ALTER"
    case index = "INDEX"
    case createView = "CREATE VIEW"
    case showView = "SHOW VIEW"
    case execute = "EXECUTE"
    case references = "REFERENCES"
    case trigger = "TRIGGER"

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    /// Privileges that can change or destroy data, so the UI can mark them.
    var isDestructive: Bool {
        switch self {
        case .delete, .drop, .alter: true
        default: false
        }
    }

    static let readOnly: [Privilege] = [.select, .showView]
    static let readWrite: [Privilege] = [.select, .insert, .update, .delete, .showView]
}

/// What a grant applies to.
nonisolated enum GrantScope: Sendable, Hashable {
    /// Every database on the server.
    case global
    /// One database, all its tables.
    case database(String)

    var sqlTarget: String {
        switch self {
        case .global: "*.*"
        case .database(let name): "\(name).*"
        }
    }

    var description: String {
        switch self {
        case .global: "all databases"
        case .database(let name): name
        }
    }
}

/// What this connection is actually allowed to do with accounts.
///
/// These are genuinely separate privileges and conflating them is a security bug: an account
/// with `GRANT OPTION` on one database can hand out privileges *on that database*, but cannot
/// create or delete server accounts — that needs a global `CREATE USER`. An earlier version
/// treated any grant option as full user management, which would have shown Add/Delete buttons
/// that always fail.
nonisolated struct UserAdminCapability: Sendable, Hashable {
    /// Can read the account list at all.
    let canList: Bool
    /// Can create and drop accounts.
    let canCreateOrDrop: Bool
    /// Can grant and revoke privileges, at least somewhere.
    let canGrant: Bool

    static let none = UserAdminCapability(canList: false, canCreateOrDrop: false, canGrant: false)

    /// Whether the user management screen is worth showing at all.
    var isAvailable: Bool {
        canList || canCreateOrDrop || canGrant
    }
}

nonisolated enum UserManagementError: Error, LocalizedError {
    case notPermitted
    case cannotModifySelf
    case invalidName(String)

    var errorDescription: String? {
        switch self {
        case .notPermitted:
            "This account is not allowed to manage users."
        case .cannotModifySelf:
            "You cannot delete the account you are currently connected with."
        case .invalidName(let detail):
            detail
        }
    }
}
