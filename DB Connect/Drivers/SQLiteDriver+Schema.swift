import Foundation

/// Schema management for SQLite.
///
/// There is no privilege system: a connection that opened the file read-write can do anything to
/// its schema. `CREATE DATABASE` has no meaning — a SQLite database *is* the file — so it stays
/// unsupported and the UI hides the affordance.
extension SQLiteSession {

    var schemaAdmin: SchemaAdminCapability {
        get async {
            // `PRAGMA query_only` reports whether writes are refused on this handle, which is
            // the only thing that can stand between us and a CREATE TABLE here.
            guard let result = try? await query(Statement("PRAGMA query_only")),
                  let row = result.rows.first, let value = row.first else {
                return .localFile
            }
            let isReadOnly = value.displayText == "1" || value.displayText.lowercased() == "true"
            return isReadOnly ? .none : .localFile
        }
    }

    func createTable(_ spec: NewTableSpec) async throws {
        try await sqlCreateTable(spec, dialect: .sqlite)
    }

    func dropTable(_ table: TableDescriptor) async throws {
        _ = try await execute(SQLDDLBuilder.dropTable(table, dialect: .sqlite))
    }
}
