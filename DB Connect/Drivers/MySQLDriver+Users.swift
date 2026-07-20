import Foundation

/// User management for MySQL and MariaDB.
///
/// A note on safety, because this file writes DDL rather than bound statements. MySQL account
/// names are *string literals* (`CREATE USER 'name'@'host'`), and no MySQL driver can bind a
/// parameter in that position — `CREATE USER ?@?` is a syntax error. So the values are escaped
/// as string literals instead, via `sqlLiteral`, and validated before they get there.
///
/// Passwords appear in the statement text and therefore may reach the server's general query
/// log. That is inherent to `CREATE USER`/`ALTER USER` and worth knowing; the UI says so.
extension MySQLSession {

    var userAdmin: UserAdminCapability {
        get async {
            // Ask the server what this account can do rather than assuming.
            guard let result = try? await query(Statement("SHOW GRANTS FOR CURRENT_USER()")) else {
                return .none
            }
            let grants = result.rows.compactMap { $0.first?.displayText.uppercased() }

            /// True when a grant applies to the whole server (`ON *.*`) and includes a privilege.
            func hasGlobal(_ privilege: String) -> Bool {
                grants.contains { grant in
                    guard let onRange = grant.range(of: " ON ") else { return false }
                    let target = grant[onRange.upperBound...]
                    guard target.hasPrefix("*.*") else { return false }
                    let privileges = grant[grant.startIndex..<onRange.lowerBound]
                    return privileges.contains(privilege) || privileges.contains("ALL PRIVILEGES")
                }
            }

            // Creating or dropping accounts is a server-wide privilege. A GRANT OPTION scoped
            // to one database emphatically does not confer it.
            let canCreateOrDrop = hasGlobal("CREATE USER")
            // mysql.user is a normal table; reading the account list needs global SELECT.
            let canList = hasGlobal("SELECT")
            // Grant option anywhere means privileges can be handed out somewhere.
            let canGrant = grants.contains { $0.contains("WITH GRANT OPTION") }

            return UserAdminCapability(canList: canList, canCreateOrDrop: canCreateOrDrop, canGrant: canGrant)
        }
    }

    func users() async throws -> [DatabaseUser] {
        let result = try await query(Statement(
            """
            SELECT User, Host, Super_priv, Create_user_priv
            FROM mysql.user
            ORDER BY User, Host
            """
        ))

        return result.rows.compactMap { row -> DatabaseUser? in
            guard case .text(let name) = row[0], case .text(let host) = row[1] else { return nil }
            let isSuper = row.count > 2 && row[2].displayText.uppercased() == "Y"
            let canCreateUsers = row.count > 3 && row[3].displayText.uppercased() == "Y"

            var attributes: [String] = []
            if isSuper { attributes.append("super") }
            if canCreateUsers { attributes.append("create user") }

            return DatabaseUser(
                name: name,
                host: host,
                canLogin: true,
                isSuperuser: isSuper,
                attributes: attributes
            )
        }
    }

    func grants(for user: DatabaseUser) async throws -> [String] {
        let account = try Self.account(for: user)
        let result = try await query(Statement("SHOW GRANTS FOR \(account)"))
        return result.rows.compactMap { $0.first?.displayText }
    }

    func createUser(name: String, host: String?, password: String) async throws {
        try Self.validate(name: name)
        let account = "\(Self.sqlLiteral(name))@\(Self.sqlLiteral(host ?? "%"))"
        _ = try await execute(Statement(
            "CREATE USER \(account) IDENTIFIED BY \(Self.sqlLiteral(password))"
        ))
    }

    func dropUser(_ user: DatabaseUser) async throws {
        // Refuse to remove the account we are connected with — that is an instant lockout,
        // and the error afterwards would be baffling.
        if let current = try? await currentUser(), current.id == user.id {
            throw UserManagementError.cannotModifySelf
        }
        let account = try Self.account(for: user)
        _ = try await execute(Statement("DROP USER \(account)"))
    }

    func setPassword(for user: DatabaseUser, to password: String) async throws {
        let account = try Self.account(for: user)
        _ = try await execute(Statement(
            "ALTER USER \(account) IDENTIFIED BY \(Self.sqlLiteral(password))"
        ))
    }

    func grant(_ privileges: [Privilege], on scope: GrantScope, to user: DatabaseUser) async throws {
        guard !privileges.isEmpty else { return }
        let account = try Self.account(for: user)
        let list = privileges.map(\.rawValue).joined(separator: ", ")
        _ = try await execute(Statement("GRANT \(list) ON \(try Self.target(scope)) TO \(account)"))
        _ = try await execute(Statement("FLUSH PRIVILEGES"))
    }

    func revoke(_ privileges: [Privilege], on scope: GrantScope, from user: DatabaseUser) async throws {
        guard !privileges.isEmpty else { return }
        let account = try Self.account(for: user)
        let list = privileges.map(\.rawValue).joined(separator: ", ")
        _ = try await execute(Statement("REVOKE \(list) ON \(try Self.target(scope)) FROM \(account)"))
        _ = try await execute(Statement("FLUSH PRIVILEGES"))
    }

    /// The account this connection is authenticated as.
    private func currentUser() async throws -> DatabaseUser? {
        let result = try await query(Statement("SELECT CURRENT_USER()"))
        guard case .text(let combined)? = result.rows.first?.first else { return nil }
        let parts = combined.split(separator: "@", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return DatabaseUser(name: parts[0], host: parts[1])
    }

    // MARK: - Escaping

    private static func account(for user: DatabaseUser) throws -> String {
        try validate(name: user.name)
        return "\(sqlLiteral(user.name))@\(sqlLiteral(user.host ?? "%"))"
    }

    /// Database names in a grant target are identifiers, so they take backticks — not the
    /// literal quoting used for account names.
    private static func target(_ scope: GrantScope) throws -> String {
        switch scope {
        case .global:
            return "*.*"
        case .database(let name):
            return "\(try SQLIdentifier.quote(name, style: .backtick)).*"
        }
    }

    /// Escape a value for use as a MySQL string literal.
    ///
    /// Backslash is an escape character inside MySQL string literals, so it must be doubled
    /// first — escaping the quote first would leave a stray backslash able to escape it back.
    static func sqlLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    private static func validate(name: String) throws {
        guard !name.isEmpty else {
            throw UserManagementError.invalidName("The user name cannot be empty.")
        }
        guard name.count <= 80 else {
            throw UserManagementError.invalidName("The user name is too long.")
        }
        // A NUL would terminate the string early in the C client; nothing legitimate has one.
        guard !name.contains("\0") else {
            throw UserManagementError.invalidName("The user name contains an invalid character.")
        }
    }
}
