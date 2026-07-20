import Foundation

/// Role management for PostgreSQL.
///
/// Postgres has roles rather than user@host accounts, and role names are *identifiers*, so
/// unlike MySQL they are quoted with `SQLIdentifier.quote`. Passwords remain string literals.
extension PostgresSession {

    var userAdmin: UserAdminCapability {
        get async {
            guard let result = try? await query(Statement(
                "SELECT rolsuper, rolcreaterole FROM pg_roles WHERE rolname = current_user"
            )), let row = result.rows.first else { return .none }

            func flag(_ index: Int) -> Bool {
                guard row.indices.contains(index) else { return false }
                if case .bool(let value) = row[index] { return value }
                return row[index].displayText.lowercased() == "true" || row[index].displayText == "t"
            }

            let isSuper = flag(0)
            let canCreateRole = flag(1)

            return UserAdminCapability(
                // pg_roles is readable by everyone, so listing always works.
                canList: true,
                canCreateOrDrop: isSuper || canCreateRole,
                canGrant: isSuper || canCreateRole
            )
        }
    }

    func users() async throws -> [DatabaseUser] {
        let result = try await query(Statement(
            """
            SELECT rolname, rolcanlogin, rolsuper, rolcreatedb, rolcreaterole, rolreplication
            FROM pg_roles
            WHERE rolname NOT LIKE 'pg\\_%'
            ORDER BY rolname
            """
        ))

        return result.rows.compactMap { row -> DatabaseUser? in
            guard case .text(let name) = row[0] else { return nil }
            func flag(_ index: Int) -> Bool {
                guard row.indices.contains(index) else { return false }
                if case .bool(let value) = row[index] { return value }
                return row[index].displayText.lowercased() == "true" || row[index].displayText == "t"
            }

            var attributes: [String] = []
            if flag(3) { attributes.append("create db") }
            if flag(4) { attributes.append("create role") }
            if flag(5) { attributes.append("replication") }

            return DatabaseUser(
                name: name,
                host: nil,
                canLogin: flag(1),
                isSuperuser: flag(2),
                attributes: attributes
            )
        }
    }

    func grants(for user: DatabaseUser) async throws -> [String] {
        // Postgres has no SHOW GRANTS; assemble the equivalent from the catalogs.
        let result = try await query(Statement(
            """
            SELECT DISTINCT table_schema || '.' || table_name || ': ' || privilege_type
            FROM information_schema.table_privileges
            WHERE grantee = $1
            ORDER BY 1
            """,
            bindings: [.text(user.name)]
        ))
        let table = result.rows.compactMap { $0.first?.displayText }

        let databases = try await query(Statement(
            """
            SELECT datname || ': CONNECT'
            FROM pg_database
            WHERE has_database_privilege($1, datname, 'CONNECT') AND datallowconn
            ORDER BY 1
            """,
            bindings: [.text(user.name)]
        ))

        let combined = databases.rows.compactMap { $0.first?.displayText } + table
        return combined.isEmpty ? ["No explicit grants"] : combined
    }

    func createUser(name: String, host: String?, password: String) async throws {
        let role = try SQLIdentifier.quote(name)
        _ = try await execute(Statement(
            "CREATE ROLE \(role) LOGIN PASSWORD \(Self.sqlLiteral(password))"
        ))
    }

    func dropUser(_ user: DatabaseUser) async throws {
        if let current = try? await currentRoleName(), current == user.name {
            throw UserManagementError.cannotModifySelf
        }
        _ = try await execute(Statement("DROP ROLE \(try SQLIdentifier.quote(user.name))"))
    }

    func setPassword(for user: DatabaseUser, to password: String) async throws {
        _ = try await execute(Statement(
            "ALTER ROLE \(try SQLIdentifier.quote(user.name)) PASSWORD \(Self.sqlLiteral(password))"
        ))
    }

    func grant(_ privileges: [Privilege], on scope: GrantScope, to user: DatabaseUser) async throws {
        guard !privileges.isEmpty else { return }
        let role = try SQLIdentifier.quote(user.name)
        let list = privileges.map(\.rawValue).joined(separator: ", ")

        switch scope {
        case .global:
            // Postgres has no server-wide table grant; the closest useful thing is every table
            // in the current database's public schema.
            _ = try await execute(Statement("GRANT \(list) ON ALL TABLES IN SCHEMA public TO \(role)"))
        case .database(let name):
            _ = try await execute(Statement("GRANT CONNECT ON DATABASE \(try SQLIdentifier.quote(name)) TO \(role)"))
            _ = try await execute(Statement("GRANT \(list) ON ALL TABLES IN SCHEMA public TO \(role)"))
        }
    }

    func revoke(_ privileges: [Privilege], on scope: GrantScope, from user: DatabaseUser) async throws {
        guard !privileges.isEmpty else { return }
        let role = try SQLIdentifier.quote(user.name)
        let list = privileges.map(\.rawValue).joined(separator: ", ")
        _ = try await execute(Statement("REVOKE \(list) ON ALL TABLES IN SCHEMA public FROM \(role)"))

        if case .database(let name) = scope {
            _ = try await execute(Statement("REVOKE CONNECT ON DATABASE \(try SQLIdentifier.quote(name)) FROM \(role)"))
        }
    }

    private func currentRoleName() async throws -> String? {
        let result = try await query(Statement("SELECT current_user"))
        guard case .text(let name)? = result.rows.first?.first else { return nil }
        return name
    }

    /// Postgres string literal. With standard_conforming_strings on (the default since 9.1),
    /// only the single quote needs doubling — backslash is an ordinary character.
    static func sqlLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}
