import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
import Logging

/// MySQL and MariaDB.
///
/// Both speak the same wire protocol, but they diverge on authentication: MySQL 8 defaults to
/// `caching_sha2_password`, which requires either TLS or the server's public key, while MariaDB
/// still uses `mysql_native_password`. MySQLNIO handles both, but this is the most common cause
/// of a first-connection failure — hence the specific error mapping below.
nonisolated struct MySQLDriver: DatabaseDriver {
    static let id = "mysql"
    static let displayName = "MySQL / MariaDB"
    static let defaultPort = 3306

    let capabilities = DriverCapabilities(
        canEditRows: true,
        canRunArbitrarySQL: true,
        supportsTransactions: true,
        supportsSchemas: false,     // MySQL's "schema" is the database itself
        requiresCredentials: true,
        supportsUserManagement: true,
        supportsSchemaChanges: true,
        supportsGranularPrivileges: true
    )

    func connect(config: ConnectionConfig, secret: Secret?) async throws -> any DatabaseSession {
        try await MySQLSession(config: config, secret: secret, capabilities: capabilities)
    }
}

actor MySQLSession: DatabaseSession {
    private var connection: MySQLConnection?
    /// Mutable: `use(database:)` switches it without reconnecting.
    private var database: String
    private let logger = Logger(label: "de.holgerkrupp.DB-Connect.mysql")
    nonisolated let capabilities: DriverCapabilities

    init(config: ConnectionConfig, secret: Secret?, capabilities: DriverCapabilities) async throws {
        self.capabilities = capabilities
        self.database = config.database

        let port = config.port == 0 ? MySQLDriver.defaultPort : config.port
        let address: SocketAddress
        do {
            address = try SocketAddress.makeAddressResolvingHost(config.host, port: port)
        } catch {
            throw DatabaseError.connectionFailed("Could not resolve “\(config.host)”.")
        }

        do {
            self.connection = try await MySQLConnection.connect(
                to: address,
                username: config.username,
                database: config.database,
                password: secret?.password,
                tlsConfiguration: try Self.makeTLS(for: config),
                serverHostname: config.host,
                logger: logger,
                on: MultiThreadedEventLoopGroup.singleton.any()
            ).get()
        } catch {
            throw DatabaseError.connectionFailed(Self.explain(error))
        }
    }

    /// `nil` disables TLS entirely in MySQLNIO; a configuration enables it.
    private static func makeTLS(for config: ConnectionConfig) throws -> TLSConfiguration? {
        switch config.tls {
        case .disabled:
            return nil
        case .preferred, .required:
            // MySQLNIO falls back to plaintext if the server refuses TLS, so "required" is not
            // strictly enforceable here — see the note in the connection form.
            return .makeClientConfiguration()
        case .pinned:
            guard let pem = config.pinnedCertificatePEM, !pem.isEmpty else {
                throw DatabaseError.unsupported(
                    "Pinned mode needs the server's certificate. Import it in the connection settings."
                )
            }
            return try CertificatePinning.tlsConfiguration(pinnedTo: pem)
        }
    }

    /// Turn the failures people actually hit into something actionable.
    ///
    /// The server's own message is always preserved: on "Access denied" MySQL names the host it
    /// saw the connection arrive from, which is the single most useful detail for fixing a grant
    /// — and an earlier version of this method discarded it.
    private static func explain(_ error: Error) -> String {
        let text = String(describing: error)
        let server = serverMessage(in: text)

        if text.contains("caching_sha2_password") || text.contains("Auth plugin") {
            return "The server requires caching_sha2_password (MySQL 8 default). Enable TLS for this connection and try again.\n\n\(server)"
        }
        if text.contains("Access denied") {
            return """
                Access denied. Check the password, and that the account is allowed to connect from \
                this network — the host shown below is the one the server saw.

                \(server)
                """
        }
        return (error as? LocalizedError)?.errorDescription ?? text
    }

    /// Pull "Server error: …" out of MySQLNIO's wrapper, falling back to the whole description.
    private static func serverMessage(in text: String) -> String {
        guard let range = text.range(of: "Server error: ") else { return text }
        return String(text[range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"() "))
    }

    func close() async {
        // Clear actor-owned state before suspending so concurrent close calls cannot both try to
        // tear down the same channel. The local keeps MySQLConnection alive until NIO confirms
        // the channel is inactive; releasing it any earlier trips MySQLNIO's deinit assertion.
        let closing = connection
        connection = nil
        try? await closing?.close().get()
    }

    // MARK: - Databases

    /// Only the databases this account can actually see — MySQL already filters `SHOW DATABASES`
    /// by privilege, so no extra work is needed to hide the rest.
    func databases() async throws -> [String] {
        let result = try await runQuery(Statement(
            """
            SELECT SCHEMA_NAME FROM information_schema.SCHEMATA
            WHERE SCHEMA_NAME NOT IN ('information_schema', 'performance_schema', 'mysql', 'sys')
            ORDER BY SCHEMA_NAME
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

    func use(database newDatabase: String) async throws {
        // USE takes no parameters, so the name must be quoted instead of bound.
        let quoted = try SQLIdentifier.quote(newDatabase, style: .backtick)
        _ = try await runQuery(Statement("USE \(quoted)"))
        database = newDatabase
    }

    // MARK: - Introspection

    func tables() async throws -> [TableDescriptor] {
        let listing = try await runQuery(Statement(
            """
            SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = ?
            ORDER BY TABLE_NAME
            """,
            bindings: [.text(database)]
        ))

        // One pass for all columns beats one query per table on a wide database.
        let columnsByTable = try await allColumns()

        return listing.rows.compactMap { row -> TableDescriptor? in
            guard case .text(let name) = row[0] else { return nil }
            let type: String = if case .text(let t) = row[1] { t } else { "BASE TABLE" }
            return TableDescriptor(
                name: name,
                schema: nil,
                kind: type == "VIEW" ? .view : .table,
                columns: columnsByTable[name] ?? []
            )
        }
    }

    func describe(table: String, schema: String?) async throws -> TableDescriptor {
        let kind = try await runQuery(Statement(
            "SELECT TABLE_TYPE FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?",
            bindings: [.text(database), .text(table)]
        ))
        guard case .text(let type)? = kind.rows.first?.first else {
            throw DatabaseError.tableNotFound(table)
        }
        return TableDescriptor(
            name: table,
            schema: nil,
            kind: type == "VIEW" ? .view : .table,
            columns: try await columns(of: table)
        )
    }

    func definitionSQL(for table: TableDescriptor) async throws -> String? {
        let name = try SQLIdentifier.quote(table.name, style: .backtick)
        let result = try await runQuery(Statement(
            table.kind == .view ? "SHOW CREATE VIEW \(name)" : "SHOW CREATE TABLE \(name)"
        ))
        guard let row = result.rows.first, row.count > 1 else { return nil }
        if case .text(let definition) = row[1] { return definition }
        return nil
    }

    private func allColumns() async throws -> [String: [ColumnDescriptor]] {
        let result = try await runQuery(Statement(
            """
            SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = ?
            ORDER BY TABLE_NAME, ORDINAL_POSITION
            """,
            bindings: [.text(database)]
        ))

        var map: [String: [ColumnDescriptor]] = [:]
        for row in result.rows {
            guard case .text(let table) = row[0], case .text(let name) = row[1] else { continue }
            map[table, default: []].append(Self.column(name: name, row: row))
        }
        return map
    }

    private func columns(of table: String) async throws -> [ColumnDescriptor] {
        let result = try await runQuery(Statement(
            """
            SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT, EXTRA
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
            ORDER BY ORDINAL_POSITION
            """,
            bindings: [.text(database), .text(table)]
        ))
        return result.rows.compactMap { row in
            guard case .text(let name) = row[1] else { return nil }
            return Self.column(name: name, row: row)
        }
    }

    private static func column(name: String, row: [SQLValue]) -> ColumnDescriptor {
        let type: String = if case .text(let t) = row[2] { t } else { "" }
        let nullable: Bool = if case .text(let n) = row[3] { n == "YES" } else { true }
        // COLUMN_KEY is "PRI" for primary keys — MySQL's own marker, no join required.
        let isPrimary: Bool = if case .text(let key) = row[4] { key == "PRI" } else { false }
        let defaultValue: String? = if case .text(let d) = row[5] { d } else { nil }
        let isGenerated: Bool = if row.indices.contains(6), case .text(let extra) = row[6] {
            extra.uppercased().contains("GENERATED")
        } else { false }

        return ColumnDescriptor(
            name: name,
            declaredType: type,
            isNullable: nullable,
            isPrimaryKey: isPrimary,
            defaultValue: defaultValue,
            isGenerated: isGenerated
        )
    }

    // MARK: - Reading

    func fetch(_ request: RowRequest) async throws -> ResultSet {
        let descriptor = try await describe(table: request.table, schema: nil)
        let known = Set(descriptor.columns.map(\.name))
        let quoted = try SQLIdentifier.quote(request.table, style: .backtick)

        var sql = "SELECT * FROM \(quoted)"
        var bindings: [SQLValue] = []

        let predicate = try PredicateBuilder.build(
            filters: request.filters,
            search: request.search,
            columns: descriptor.columns,
            dialect: .mysql
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
                return "\(try SQLIdentifier.quote(sort.column, style: .backtick)) \(sort.ascending ? "ASC" : "DESC")"
            }
            sql += " ORDER BY " + terms.joined(separator: ", ")
        }

        // One extra row tells us whether another page exists, without a COUNT.
        sql += " LIMIT ? OFFSET ?"
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
        let descriptor = try await describe(table: request.table, schema: nil)
        var sql = "SELECT COUNT(*) FROM \(try SQLIdentifier.quote(request.table, style: .backtick))"
        var bindings: [SQLValue] = []

        let predicate = try PredicateBuilder.build(
            filters: request.filters,
            search: request.search,
            columns: descriptor.columns,
            dialect: .mysql
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
        guard let connection else { throw DatabaseError.notConnected }
        let clock = ContinuousClock()
        let start = clock.now

        let metadata = MetadataBox()
        do {
            _ = try await connection.query(
                statement.sql,
                statement.bindings.map(Self.bind),
                onRow: { _ in },
                onMetadata: { metadata.store($0) }
            ).get()
        } catch {
            throw DatabaseError.queryFailed(sql: statement.sql, message: Self.explain(error))
        }

        let captured = metadata.value
        return ExecutionResult(
            affectedRows: Int(captured?.affectedRows ?? 0),
            lastInsertID: captured?.lastInsertID.map(Int64.init),
            elapsed: clock.now - start
        )
    }

    // MARK: - Editing

    nonisolated func preview(_ mutations: [RowMutation], to table: TableDescriptor) throws -> [String] {
        try sqlPreview(mutations, to: table, dialect: .mysql)
    }

    func apply(_ mutations: [RowMutation], to table: TableDescriptor) async throws -> ExecutionResult {
        guard connection != nil else { throw DatabaseError.notConnected }
        guard !mutations.isEmpty else { return ExecutionResult(affectedRows: 0) }

        let clock = ContinuousClock()
        let start = clock.now

        // Build everything first, so an invalid edit never opens a transaction.
        let statements = try mutations.map {
            try MutationBuilder.statement(for: $0, table: table, dialect: .mysql)
        }

        _ = try await execute(Statement("START TRANSACTION"))
        var affected = 0

        do {
            for statement in statements {
                let outcome = try await execute(statement)
                // MySQL reports 0 affected rows when an UPDATE sets a column to the value it
                // already holds, so that alone is not proof the row is missing.
                affected += outcome.affectedRows
            }
        } catch {
            _ = try? await execute(Statement("ROLLBACK"))
            throw error
        }

        _ = try await execute(Statement("COMMIT"))
        return ExecutionResult(affectedRows: affected, lastInsertID: nil, elapsed: clock.now - start)
    }

    // MARK: - Plumbing

    /// MySQLNIO delivers metadata through an escaping callback, so it needs somewhere to land.
    private final class MetadataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: MySQLQueryMetadata?

        func store(_ metadata: MySQLQueryMetadata) {
            lock.lock(); defer { lock.unlock() }
            stored = metadata
        }

        var value: MySQLQueryMetadata? {
            lock.lock(); defer { lock.unlock() }
            return stored
        }
    }

    private func runQuery(_ statement: Statement) async throws -> ResultSet {
        guard let connection else { throw DatabaseError.notConnected }
        let clock = ContinuousClock()
        let start = clock.now

        // Collect through a callback so rows past the safety cap are dropped as they arrive,
        // rather than materialising the whole result first and trimming afterwards.
        let collector = RowCollector()
        do {
            _ = try await connection.query(
                statement.sql,
                statement.bindings.map(Self.bind),
                onRow: { collector.append($0) }
            ).get()
        } catch {
            throw DatabaseError.queryFailed(sql: statement.sql, message: Self.explain(error))
        }
        let mysqlRows = collector.rows
        let truncated = collector.truncated

        let columns = mysqlRows.first?.columnDefinitions.map { definition in
            ColumnDescriptor(name: definition.name, declaredType: String(describing: definition.columnType))
        } ?? []

        let rows = mysqlRows.map { row in
            row.columnDefinitions.map { definition in
                Self.value(row.column(definition.name))
            }
        }

        return ResultSet(columns: columns, rows: rows, hasMore: truncated, elapsed: clock.now - start)
    }

    /// MySQLNIO hands rows to an escaping callback, so collection needs somewhere thread-safe
    /// to accumulate — and it is where the row cap is enforced.
    private final class RowCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [MySQLRow] = []
        private var didTruncate = false

        func append(_ row: MySQLRow) {
            lock.lock(); defer { lock.unlock() }
            guard storage.count < QueryLimits.maxRows else {
                didTruncate = true
                return
            }
            storage.append(row)
        }

        var rows: [MySQLRow] {
            lock.lock(); defer { lock.unlock() }
            return storage
        }

        var truncated: Bool {
            lock.lock(); defer { lock.unlock() }
            return didTruncate
        }
    }

    private static func bind(_ value: SQLValue) -> MySQLData {
        switch value {
        case .null: .null
        case .bool(let v): MySQLData(bool: v)
        case .integer(let v): MySQLData(int: Int(v))
        case .double(let v): MySQLData(double: v)
        case .text(let v): MySQLData(string: v)
        case .date(let v): MySQLData(date: v)
        case .blob(let d): MySQLData(type: .blob, buffer: ByteBuffer(bytes: d))
        }
    }

    /// Map a MySQL cell onto `SQLValue`.
    ///
    /// `decimal` deliberately stays text: routing money through `Double` loses precision, and a
    /// wrong number is worse than a string the user can still read.
    private static func value(_ data: MySQLData?) -> SQLValue {
        guard let data else { return .null }

        switch data.type {
        case .null:
            return .null
        case .tiny:
            // MySQL has no boolean; TINYINT(1) is the convention, but a plain TINYINT is a
            // number. Keeping it integral avoids showing "true" for a value of 1.
            return data.int.map { .integer(Int64($0)) } ?? .null
        case .short, .long, .int24, .longlong, .year:
            return data.int.map { .integer(Int64($0)) } ?? .null
        case .float, .double:
            return data.double.map { .double($0) } ?? .null
        case .decimal, .newdecimal:
            // MySQLNIO's `string` accessor returns nil for NEWDECIMAL, so going through it
            // silently produced NULL for every DECIMAL column. The wire format is ASCII digits,
            // so read the buffer directly — that also keeps the exact precision, which is the
            // whole reason DECIMAL is not routed through Double.
            if var buffer = data.buffer, let text = buffer.readString(length: buffer.readableBytes) {
                return .text(text)
            }
            // Better an approximate number than a lost value, if the buffer is ever absent.
            return data.double.map { .double($0) } ?? .null
        case .date, .datetime, .timestamp:
            if let date = data.date { return .date(date) }
            return data.string.map { .text($0) } ?? .null
        case .blob, .tinyBlob, .mediumBlob, .longBlob:
            // MySQL uses blob types for TEXT as well; prefer readable text when it decodes.
            if let string = data.string { return .text(string) }
            if var buffer = data.buffer, let bytes = buffer.readBytes(length: buffer.readableBytes) {
                return .blob(Data(bytes))
            }
            return .null
        default:
            return data.string.map { .text($0) } ?? .null
        }
    }
}
