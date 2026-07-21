import Foundation

/// Schema management for PostgreSQL.
///
/// Postgres answers privilege questions directly, so unlike MySQL there is no grant-string
/// parsing here — `has_schema_privilege` and `rolcreatedb` are authoritative.
extension PostgresSession {

    var schemaAdmin: SchemaAdminCapability {
        get async {
            guard let result = try? await query(Statement(
                """
                SELECT has_schema_privilege(current_schema(), 'CREATE'),
                       (SELECT rolcreatedb OR rolsuper FROM pg_roles WHERE rolname = current_user)
                """
            )), let row = result.rows.first else { return .none }

            func flag(_ index: Int) -> Bool {
                guard row.indices.contains(index) else { return false }
                if case .bool(let value) = row[index] { return value }
                let text = row[index].displayText.lowercased()
                return text == "true" || text == "t"
            }

            let canCreateInSchema = flag(0)

            return SchemaAdminCapability(
                canCreateTable: canCreateInSchema,
                // Ownership is what actually governs DROP, and that is per table rather than
                // per schema. CREATE on the schema is the closest honest proxy: it means the
                // user owns objects here. A drop they cannot do still fails on the server.
                canDropTable: canCreateInSchema,
                canCreateDatabase: flag(1)
            )
        }
    }

    func createTable(_ spec: NewTableSpec) async throws {
        try await sqlCreateTable(spec, dialect: .postgres)
    }

    func dropTable(_ table: TableDescriptor) async throws {
        _ = try await execute(SQLDDLBuilder.dropTable(table, dialect: .postgres))
    }

    /// `CREATE DATABASE` cannot run inside a transaction block, which is why this goes through
    /// `execute` as a single statement rather than being batched with anything else.
    func createDatabase(name: String) async throws {
        _ = try await execute(SQLDDLBuilder.createDatabase(name: name, dialect: .postgres))
    }
}
