import Foundation

/// Schema management for MySQL and MariaDB.
///
/// Like the user-management extension, this writes DDL rather than bound statements — see
/// `SQLDDLBuilder` for why that is unavoidable and how the text is kept safe.
extension MySQLSession {

    var schemaAdmin: SchemaAdminCapability {
        get async {
            // Ask the server rather than assuming. An account that can write rows very often
            // cannot create tables, and almost never gets CREATE DATABASE.
            guard let result = try? await query(Statement("SHOW GRANTS FOR CURRENT_USER()")) else {
                return .none
            }
            let grants = result.rows.compactMap { $0.first?.displayText.uppercased() }
            let database = await currentDatabase

            /// Whether some grant confers `privilege` on a target the predicate accepts.
            func has(_ privilege: String, where matchesTarget: (Substring) -> Bool) -> Bool {
                grants.contains { grant in
                    guard let onRange = grant.range(of: " ON ") else { return false }
                    let target = grant[onRange.upperBound...]
                    guard matchesTarget(target) else { return false }
                    let privileges = grant[grant.startIndex..<onRange.lowerBound]
                    return privileges.contains(privilege) || privileges.contains("ALL PRIVILEGES")
                }
            }

            let isGlobal: (Substring) -> Bool = { $0.hasPrefix("*.*") }

            // A CREATE grant on the current database is enough for tables; a global one also is.
            let onCurrentDatabase: (Substring) -> Bool = { target in
                guard target.hasPrefix("*.*") == false else { return true }
                guard let database, !database.isEmpty else { return false }
                // Targets read as `` `db`.* `` — compare on the unquoted name.
                let unquoted = target
                    .replacingOccurrences(of: "`", with: "")
                    .uppercased()
                return unquoted.hasPrefix("\(database.uppercased()).")
            }

            return SchemaAdminCapability(
                canCreateTable: has("CREATE", where: onCurrentDatabase),
                canDropTable: has("DROP", where: onCurrentDatabase),
                // CREATE DATABASE is a server-wide right; a CREATE grant scoped to one database
                // emphatically does not confer it.
                canCreateDatabase: has("CREATE", where: isGlobal)
            )
        }
    }

    func createTable(_ spec: NewTableSpec) async throws {
        try await sqlCreateTable(spec, dialect: .mysql)
    }

    func dropTable(_ table: TableDescriptor) async throws {
        _ = try await execute(SQLDDLBuilder.dropTable(table, dialect: .mysql))
    }

    func createDatabase(name: String) async throws {
        _ = try await execute(SQLDDLBuilder.createDatabase(name: name, dialect: .mysql))
    }
}
