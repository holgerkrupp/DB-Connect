import Foundation
import PostgresNIO
import NIOCore
import NIOSSL
import Logging

nonisolated struct PostgresDriver: DatabaseDriver {
    static let id = "postgres"
    static let displayName = "PostgreSQL"
    static let defaultPort = 5432

    let capabilities = DriverCapabilities(
        canEditRows: true,
        canRunArbitrarySQL: true,
        supportsTransactions: true,
        supportsSchemas: true,
        requiresCredentials: true,
        supportsUserManagement: true,
        supportsSchemaChanges: true
    )

    func connect(config: ConnectionConfig, secret: Secret?) async throws -> any DatabaseSession {
        try await PostgresSession(config: config, secret: secret, capabilities: capabilities)
    }
}

actor PostgresSession: DatabaseSession {
    private var connection: PostgresConnection?
    private let database: String
    private let logger = Logger(label: "de.holgerkrupp.DB-Connect.postgres")
    nonisolated let capabilities: DriverCapabilities

    init(config: ConnectionConfig, secret: Secret?, capabilities: DriverCapabilities) async throws {
        self.capabilities = capabilities
        self.database = config.database

        let tls = try Self.makeTLS(for: config)
        let pgConfig = PostgresConnection.Configuration(
            host: config.host,
            port: config.port == 0 ? PostgresDriver.defaultPort : config.port,
            username: config.username,
            password: secret?.password,
            database: config.database.isEmpty ? nil : config.database,
            tls: tls
        )

        do {
            self.connection = try await PostgresConnection.connect(
                configuration: pgConfig,
                id: 1,
                logger: logger
            )
        } catch {
            throw DatabaseError.connectionFailed(error.localizedDescription)
        }
    }

    private static func makeTLS(for config: ConnectionConfig) throws -> PostgresConnection.Configuration.TLS {
        switch config.tls {
        case .disabled:
            return .disable
        case .preferred:
            return .prefer(try NIOSSLContext(configuration: .makeClientConfiguration()))
        case .required:
            return .require(try NIOSSLContext(configuration: .makeClientConfiguration()))
        case .pinned:
            guard let pem = config.pinnedCertificatePEM, !pem.isEmpty else {
                throw DatabaseError.unsupported(
                    "Pinned mode needs the server's certificate. Import it in the connection settings."
                )
            }
            // BoringSSL enforces this during the handshake: the pinned certificate is the only
            // trust root, so anything else fails before a single byte of credentials is sent.
            return .require(try NIOSSLContext(configuration: CertificatePinning.tlsConfiguration(pinnedTo: pem)))
        }
    }

    func close() async {
        let closing = connection
        connection = nil
        try? await closing?.close()
    }

    // MARK: - Databases

    func databases() async throws -> [String] {
        let result = try await runQuery(Statement(
            """
            SELECT datname FROM pg_database
            WHERE datallowconn AND NOT datistemplate
            ORDER BY datname
            """
        ))
        return result.rows.compactMap {
            if case .text(let name) = $0[0] { return name }
            return nil
        }
    }

    var currentDatabase: String? {
        get async { database.isEmpty ? nil : database }
    }

    /// PostgreSQL binds a connection to one database for its lifetime — there is no `USE`.
    /// Refusing here lets the UI reconnect instead, which is the only correct way to switch.
    func use(database newDatabase: String) async throws {
        throw DatabaseError.unsupported("PostgreSQL cannot switch databases on an open connection.")
    }

    // MARK: - Introspection

    /// Schemas the user can actually see, excluding Postgres' own catalogs.
    private static let visibleSchemaPredicate = "table_schema NOT IN ('pg_catalog', 'information_schema')"

    func tables() async throws -> [TableDescriptor] {
        let listing = try await runQuery(Statement("""
            SELECT table_schema, table_name, table_type
            FROM information_schema.tables
            WHERE \(Self.visibleSchemaPredicate)
            ORDER BY table_schema, table_name
            """))

        // One introspection round-trip for all columns beats one per table on a wide database.
        let columnsByTable = try await allColumns()
        let primaryKeys = try await allPrimaryKeys()

        return listing.rows.compactMap { row -> TableDescriptor? in
            guard case .text(let schema) = row[0], case .text(let name) = row[1] else { return nil }
            let type: String = if case .text(let t) = row[2] { t } else { "BASE TABLE" }
            let key = "\(schema).\(name)"
            let pkColumns = primaryKeys[key] ?? []

            let columns = (columnsByTable[key] ?? []).map { column in
                ColumnDescriptor(
                    name: column.name,
                    declaredType: column.type,
                    isNullable: column.isNullable,
                    isPrimaryKey: pkColumns.contains(column.name),
                    defaultValue: column.defaultValue,
                    isGenerated: column.isGenerated
                )
            }

            return TableDescriptor(
                name: name,
                schema: schema,
                kind: type == "VIEW" ? .view : .table,
                columns: columns
            )
        }
    }

    func describe(table: String, schema: String?) async throws -> TableDescriptor {
        let all = try await tables()
        let match = all.first {
            $0.name == table && (schema == nil || $0.schema == schema)
        }
        guard let match else { throw DatabaseError.tableNotFound(table) }
        return match
    }

    func definitionSQL(for table: TableDescriptor) async throws -> String? {
        let qualified = try SQLIdentifier.qualify(schema: table.schema, name: table.name)
        // `to_regclass(text)` parses its input as an identifier. Passing the already-quoted
        // spelling preserves uppercase letters, dots, and other legal identifier characters.
        let registration = qualified

        if table.kind == .view {
            let result = try await runQuery(Statement(
                "SELECT pg_get_viewdef(to_regclass($1), true)",
                bindings: [.text(registration)]
            ))
            guard case .text(let body)? = result.rows.first?.first else { return nil }
            return "CREATE VIEW \(qualified) AS\n\(body)"
        }

        // PostgreSQL deliberately has no SHOW CREATE TABLE. Reconstruct from its catalogs so a
        // dump still preserves exact formatted types, defaults/identity/generated columns,
        // named constraints, and non-constraint indexes rather than only the browser metadata.
        let columnRows = try await runQuery(Statement(
            """
            SELECT a.attname,
                   pg_catalog.format_type(a.atttypid, a.atttypmod),
                   a.attnotnull,
                   pg_get_expr(d.adbin, d.adrelid),
                   a.attidentity,
                   a.attgenerated,
                   pg_get_serial_sequence($1, a.attname)
            FROM pg_attribute a
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = to_regclass($1) AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """,
            bindings: [.text(registration)]
        ))
        guard !columnRows.rows.isEmpty else { return nil }

        var definitions: [String] = try columnRows.rows.compactMap { row -> String? in
            guard row.count >= 7,
                  case .text(let name) = row[0],
                  case .text(let type) = row[1]
            else { return nil }
            let quoted = try SQLIdentifier.quote(name)
            let notNull = row[2].doubleValue.map { $0 != 0 }
                ?? (row[2] == .bool(true))
            let defaultExpression: String? = if case .text(let value) = row[3] { value } else { nil }
            let identity: String = if case .text(let value) = row[4] { value } else { "" }
            let generated: String = if case .text(let value) = row[5] { value } else { "" }
            let ownedSequence: String? = if case .text(let value) = row[6] { value } else { nil }

            let serialType: String? = if ownedSequence != nil && identity.isEmpty && generated.isEmpty {
                switch type.lowercased() {
                case "smallint": "smallserial"
                case "integer": "serial"
                case "bigint": "bigserial"
                default: nil
                }
            } else { nil }
            var parts = [quoted, serialType ?? type]
            if !generated.isEmpty, let defaultExpression {
                parts.append("GENERATED ALWAYS AS (\(defaultExpression)) STORED")
            } else if !identity.isEmpty {
                parts.append(identity == "a" ? "GENERATED ALWAYS AS IDENTITY" : "GENERATED BY DEFAULT AS IDENTITY")
            } else if serialType == nil, let defaultExpression {
                parts.append("DEFAULT \(defaultExpression)")
            }
            if notNull { parts.append("NOT NULL") }
            return parts.joined(separator: " ")
        }

        let constraints = try await runQuery(Statement(
            """
            SELECT conname, pg_get_constraintdef(oid, true)
            FROM pg_constraint
            WHERE conrelid = to_regclass($1) AND contype <> 'f'
            ORDER BY CASE contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'f' THEN 2 ELSE 3 END, conname
            """,
            bindings: [.text(registration)]
        ))
        for row in constraints.rows {
            guard row.count > 1, case .text(let name) = row[0], case .text(let body) = row[1] else { continue }
            definitions.append("CONSTRAINT \(try SQLIdentifier.quote(name)) \(body)")
        }

        let body = definitions.map { "    \($0)" }.joined(separator: ",\n")
        var definition = "CREATE TABLE \(qualified) (\n\(body)\n)"
        let indexes = try await runQuery(Statement(
            """
            SELECT pg_get_indexdef(i.indexrelid)
            FROM pg_index i
            LEFT JOIN pg_constraint c ON c.conindid = i.indexrelid
            WHERE i.indrelid = to_regclass($1) AND c.oid IS NULL
            ORDER BY i.indexrelid::regclass::text
            """,
            bindings: [.text(registration)]
        ))
        for row in indexes.rows {
            if case .text(let indexSQL)? = row.first {
                definition += ";\n\(indexSQL)"
            }
        }
        return definition
    }

    func deferredDefinitionSQL(for table: TableDescriptor) async throws -> [String] {
        guard table.kind == .table else { return [] }
        let qualified = try SQLIdentifier.qualify(schema: table.schema, name: table.name)
        let sequences = try await runQuery(Statement(
            """
            SELECT a.attname, pg_get_serial_sequence($1, a.attname)
            FROM pg_attribute a
            WHERE a.attrelid = to_regclass($1) AND a.attnum > 0 AND NOT a.attisdropped
              AND pg_get_serial_sequence($1, a.attname) IS NOT NULL
            ORDER BY a.attnum
            """,
            bindings: [.text(qualified)]
        ))
        var statements: [String] = try sequences.rows.compactMap { row -> String? in
            guard row.count > 1, case .text(let column) = row[0], case .text = row[1] else { return nil }
            let quotedColumn = try SQLIdentifier.quote(column)
            let tableLiteral = qualified.replacingOccurrences(of: "'", with: "''")
            let columnLiteral = column.replacingOccurrences(of: "'", with: "''")
            return "SELECT pg_catalog.setval(pg_get_serial_sequence('\(tableLiteral)', '\(columnLiteral)'), COALESCE(MAX(\(quotedColumn)), 1), MAX(\(quotedColumn)) IS NOT NULL) FROM \(qualified)"
        }
        let constraints = try await runQuery(Statement(
            """
            SELECT conname, pg_get_constraintdef(oid, true)
            FROM pg_constraint
            WHERE conrelid = to_regclass($1) AND contype = 'f'
            ORDER BY conname
            """,
            bindings: [.text(qualified)]
        ))
        statements += try constraints.rows.compactMap { row -> String? in
            guard row.count > 1, case .text(let name) = row[0], case .text(let body) = row[1] else { return nil }
            return "ALTER TABLE \(qualified) ADD CONSTRAINT \(try SQLIdentifier.quote(name)) \(body)"
        }
        return statements
    }

    private struct ColumnInfo {
        let name: String
        let type: String
        let isNullable: Bool
        let defaultValue: String?
        let isGenerated: Bool
    }

    private func allColumns() async throws -> [String: [ColumnInfo]] {
        let result = try await runQuery(Statement("""
            SELECT table_schema, table_name, column_name,
                   COALESCE(data_type, ''), is_nullable, column_default, is_generated
            FROM information_schema.columns
            WHERE \(Self.visibleSchemaPredicate)
            ORDER BY table_schema, table_name, ordinal_position
            """))

        var map: [String: [ColumnInfo]] = [:]
        for row in result.rows {
            guard case .text(let schema) = row[0],
                  case .text(let table) = row[1],
                  case .text(let column) = row[2] else { continue }
            let type: String = if case .text(let t) = row[3] { t } else { "" }
            let nullable: Bool = if case .text(let n) = row[4] { n == "YES" } else { true }
            let defaultValue: String? = if case .text(let d) = row[5] { d } else { nil }
            let generated: Bool = if row.indices.contains(6), case .text(let value) = row[6] {
                value == "ALWAYS"
            } else { false }

            map["\(schema).\(table)", default: []].append(
                ColumnInfo(
                    name: column,
                    type: type,
                    isNullable: nullable,
                    defaultValue: defaultValue,
                    isGenerated: generated
                )
            )
        }
        return map
    }

    /// Primary keys straight from the catalog. `information_schema` works too but is markedly
    /// slower on large databases, and this form also covers multi-column keys correctly.
    private func allPrimaryKeys() async throws -> [String: Set<String>] {
        let result = try await runQuery(Statement("""
            SELECT n.nspname, c.relname, a.attname
            FROM pg_index i
            JOIN pg_class c ON c.oid = i.indrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY(i.indkey)
            WHERE i.indisprimary AND n.nspname NOT IN ('pg_catalog', 'information_schema')
            """))

        var map: [String: Set<String>] = [:]
        for row in result.rows {
            guard case .text(let schema) = row[0],
                  case .text(let table) = row[1],
                  case .text(let column) = row[2] else { continue }
            map["\(schema).\(table)", default: []].insert(column)
        }
        return map
    }

    // MARK: - Reading

    func fetch(_ request: RowRequest) async throws -> ResultSet {
        let descriptor = try await describe(table: request.table, schema: request.schema)
        let known = Set(descriptor.columns.map(\.name))
        let qualified = try SQLIdentifier.qualify(schema: descriptor.schema, name: descriptor.name)

        var sql = "SELECT * FROM \(qualified)"
        var bindings: [SQLValue] = []

        // Postgres numbers its placeholders, so the filter binds must be emitted first and the
        // LIMIT/OFFSET placeholders continue from wherever the predicate stopped.
        let predicate = try PredicateBuilder.build(
            filters: request.filters,
            search: request.search,
            columns: descriptor.columns,
            dialect: .postgres
        )
        if let clause = predicate.clause {
            sql += " WHERE \(clause)"
            bindings += predicate.bindings
        }

        if !request.sort.isEmpty {
            let terms = try request.sort.map { sort -> String in
                guard known.contains(sort.column) else {
                    throw DatabaseError.invalidIdentifier("Unknown column “\(sort.column)”.")
                }
                return "\(try SQLIdentifier.quote(sort.column)) \(sort.ascending ? "ASC" : "DESC")"
            }
            sql += " ORDER BY " + terms.joined(separator: ", ")
        }

        // One extra row reveals whether a further page exists, without a COUNT.
        sql += " LIMIT $\(predicate.nextIndex) OFFSET $\(predicate.nextIndex + 1)"
        bindings += [.integer(Int64(request.limit + 1)), .integer(Int64(request.offset))]
        let result = try await runQuery(Statement(sql, bindings: bindings))

        let hasMore = result.rows.count > request.limit
        return ResultSet(
            columns: descriptor.columns.isEmpty ? result.columns : descriptor.columns,
            rows: hasMore ? Array(result.rows.prefix(request.limit)) : result.rows,
            hasMore: hasMore,
            elapsed: result.elapsed
        )
    }

    func count(_ request: RowRequest) async throws -> Int? {
        let descriptor = try await describe(table: request.table, schema: request.schema)
        let qualified = try SQLIdentifier.qualify(schema: descriptor.schema, name: descriptor.name)
        var sql = "SELECT COUNT(*) FROM \(qualified)"
        var bindings: [SQLValue] = []

        let predicate = try PredicateBuilder.build(
            filters: request.filters,
            search: request.search,
            columns: descriptor.columns,
            dialect: .postgres
        )
        if let clause = predicate.clause {
            sql += " WHERE \(clause)"
            bindings = predicate.bindings
        }

        return try await runQuery(Statement(sql, bindings: bindings)).scalar().map(Int.init)
    }

    func query(_ statement: Statement) async throws -> ResultSet {
        try await runQuery(statement)
    }

    func execute(_ statement: Statement) async throws -> ExecutionResult {
        // PostgresNIO surfaces no affected-row count on this path, so report what we can
        // rather than inventing a number.
        let result = try await runQuery(statement)
        return ExecutionResult(affectedRows: result.rows.count, lastInsertID: nil, elapsed: result.elapsed)
    }

    // MARK: - Editing

    nonisolated func preview(_ mutations: [RowMutation], to table: TableDescriptor) throws -> [String] {
        try sqlPreview(mutations, to: table, dialect: .postgres)
    }

    func apply(_ mutations: [RowMutation], to table: TableDescriptor) async throws -> ExecutionResult {
        guard connection != nil else { throw DatabaseError.notConnected }
        guard !mutations.isEmpty else { return ExecutionResult(affectedRows: 0) }

        let clock = ContinuousClock()
        let start = clock.now

        // Build first, so an invalid edit never opens a transaction.
        let statements = try mutations.map {
            try MutationBuilder.statement(for: $0, table: table, dialect: .postgres)
        }

        _ = try await runQuery(Statement("BEGIN"))

        do {
            for statement in statements {
                // RETURNING lets us count affected rows, which PostgresNIO's row stream
                // otherwise does not expose on this path.
                let returning = Statement(statement.sql + " RETURNING 1", bindings: statement.bindings)
                let outcome = try await runQuery(returning)
                guard !outcome.rows.isEmpty else {
                    throw DatabaseError.queryFailed(
                        sql: statement.sql,
                        message: "No row matched. It may have been changed or deleted by someone else."
                    )
                }
            }
        } catch {
            _ = try? await runQuery(Statement("ROLLBACK"))
            throw error
        }

        _ = try await runQuery(Statement("COMMIT"))
        return ExecutionResult(affectedRows: statements.count, lastInsertID: nil, elapsed: clock.now - start)
    }

    // MARK: - Plumbing

    private func runQuery(_ statement: Statement) async throws -> ResultSet {
        guard let connection else { throw DatabaseError.notConnected }
        let clock = ContinuousClock()
        let start = clock.now

        var binds = PostgresBindings(capacity: statement.bindings.count)
        for value in statement.bindings {
            switch value {
            case .null: binds.appendNull()
            case .bool(let v): binds.append(v)
            case .integer(let v): binds.append(v)
            case .double(let v): binds.append(v)
            case .text(let v): binds.append(v)
            case .blob(let d): binds.append(ByteBuffer(bytes: d))
            case .date(let v): binds.append(v)
            }
        }

        do {
            let stream = try await connection.query(
                PostgresQuery(unsafeSQL: statement.sql, binds: binds),
                logger: logger
            )

            var columns: [ColumnDescriptor] = []
            var rows: [[SQLValue]] = []
            var truncated = false

            for try await row in stream {
                // Break out of the row stream once the cap is reached rather than draining it.
                if rows.count >= QueryLimits.maxRows {
                    truncated = true
                    break
                }
                var values: [SQLValue] = []
                var discoveredColumns: [ColumnDescriptor] = []

                for cell in row {
                    values.append(Self.value(from: cell))
                    if columns.isEmpty {
                        discoveredColumns.append(
                            ColumnDescriptor(name: cell.columnName, declaredType: Self.typeName(cell.dataType))
                        )
                    }
                }

                if columns.isEmpty { columns = discoveredColumns }
                rows.append(values)
            }

            return ResultSet(columns: columns, rows: rows, hasMore: truncated, elapsed: clock.now - start)
        } catch let error as PSQLError {
            throw DatabaseError.queryFailed(
                sql: statement.sql,
                message: error.serverInfo?[.message] ?? error.localizedDescription
            )
        } catch {
            throw DatabaseError.queryFailed(sql: statement.sql, message: error.localizedDescription)
        }
    }

    /// Map a Postgres cell onto `SQLValue`.
    ///
    /// Types that cannot be represented losslessly — `numeric` above all, where going through
    /// `Double` would quietly corrupt money columns — are kept as text.
    private static func value(from cell: PostgresCell) -> SQLValue {
        guard cell.bytes != nil else { return .null }

        do {
            switch cell.dataType {
            case .bool:
                return .bool(try cell.decode(Bool.self, context: .default))
            case .int2, .int4, .int8:
                return .integer(try cell.decode(Int64.self, context: .default))
            case .float4, .float8:
                return .double(try cell.decode(Double.self, context: .default))
            case .timestamp, .timestamptz, .date:
                return .date(try cell.decode(Date.self, context: .default))
            case .bytea:
                return .blob(try cell.decode(Data.self, context: .default))
            default:
                return .text(try cell.decode(String.self, context: .default))
            }
        } catch {
            // Unknown or undecodable type: show the raw bytes as text rather than losing the row.
            if var bytes = cell.bytes, let string = bytes.readString(length: bytes.readableBytes) {
                return .text(string)
            }
            return .null
        }
    }

    private static func typeName(_ type: PostgresDataType) -> String {
        String(describing: type)
    }
}
