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
        requiresCredentials: true
    )

    func connect(config: ConnectionConfig, secret: Secret?) async throws -> any DatabaseSession {
        try await MySQLSession(config: config, secret: secret, capabilities: capabilities)
    }
}

actor MySQLSession: DatabaseSession {
    private var connection: MySQLConnection?
    private let database: String
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

    /// Turn the two failures people actually hit into something actionable.
    private static func explain(_ error: Error) -> String {
        let text = String(describing: error)
        if text.contains("caching_sha2_password") || text.contains("Auth plugin") {
            return "The server requires caching_sha2_password (MySQL 8 default). Enable TLS for this connection and try again."
        }
        if text.contains("Access denied") {
            return "Access denied — check the username, password and that this host may connect."
        }
        return (error as? LocalizedError)?.errorDescription ?? text
    }

    func close() async {
        try? await connection?.close().get()
        connection = nil
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

    private func allColumns() async throws -> [String: [ColumnDescriptor]] {
        let result = try await runQuery(Statement(
            """
            SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT
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
            SELECT TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_KEY, COLUMN_DEFAULT
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

        return ColumnDescriptor(
            name: name,
            declaredType: type,
            isNullable: nullable,
            isPrimaryKey: isPrimary,
            defaultValue: defaultValue
        )
    }

    // MARK: - Reading

    func fetch(_ request: RowRequest) async throws -> ResultSet {
        let descriptor = try await describe(table: request.table, schema: nil)
        let known = Set(descriptor.columns.map(\.name))
        let quoted = try SQLIdentifier.quote(request.table, style: .backtick)

        var sql = "SELECT * FROM \(quoted)"

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
        let result = try await runQuery(Statement(
            sql,
            bindings: [.integer(Int64(request.limit + 1)), .integer(Int64(request.offset))]
        ))

        let hasMore = result.rows.count > request.limit
        return ResultSet(
            columns: descriptor.columns.isEmpty ? result.columns : descriptor.columns,
            rows: hasMore ? Array(result.rows.prefix(request.limit)) : result.rows,
            hasMore: hasMore,
            elapsed: result.elapsed
        )
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

        let mysqlRows: [MySQLRow]
        do {
            mysqlRows = try await connection.query(
                statement.sql,
                statement.bindings.map(Self.bind)
            ).get()
        } catch {
            throw DatabaseError.queryFailed(sql: statement.sql, message: Self.explain(error))
        }

        let columns = mysqlRows.first?.columnDefinitions.map { definition in
            ColumnDescriptor(name: definition.name, declaredType: String(describing: definition.columnType))
        } ?? []

        let rows = mysqlRows.map { row in
            row.columnDefinitions.map { definition in
                Self.value(row.column(definition.name))
            }
        }

        return ResultSet(columns: columns, rows: rows, hasMore: false, elapsed: clock.now - start)
    }

    private static func bind(_ value: SQLValue) -> MySQLData {
        switch value {
        case .null: .null
        case .bool(let v): MySQLData(bool: v)
        case .integer(let v): MySQLData(int: Int(v))
        case .double(let v): MySQLData(double: v)
        case .text(let v): MySQLData(string: v)
        case .date(let v): MySQLData(date: v)
        case .blob(let d): MySQLData(string: d.base64EncodedString())
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
            return data.string.map { .text($0) } ?? .null
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
