import Foundation
import SQLite3

/// Passing a Swift string to SQLite without this tells it the buffer is permanent, which it is not.
nonisolated(unsafe) private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

nonisolated struct SQLiteDriver: DatabaseDriver {
    static let id = "sqlite"
    static let displayName = "SQLite"

    let capabilities = DriverCapabilities(
        canEditRows: true,
        canRunArbitrarySQL: true,
        supportsTransactions: true,
        supportsSchemas: false,
        requiresCredentials: false
    )

    init() {}

    /// `config.database` is the file path. Use `":memory:"` for a scratch database.
    func connect(config: ConnectionConfig, secret: Secret?) async throws -> any DatabaseSession {
        try await SQLiteSession(path: config.database, capabilities: capabilities)
    }
}

actor SQLiteSession: DatabaseSession {
    private var handle: OpaquePointer?
    nonisolated let capabilities: DriverCapabilities

    init(path: String, capabilities: DriverCapabilities) async throws {
        self.capabilities = capabilities
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open \(path)"
            sqlite3_close_v2(db)
            throw DatabaseError.connectionFailed(message)
        }
        self.handle = db
        // Foreign keys are off by default in SQLite; without this, edits can orphan rows.
        sqlite3_exec(db, "PRAGMA foreign_keys = ON", nil, nil, nil)
    }

    isolated deinit {
        if let handle { sqlite3_close_v2(handle) }
    }

    func close() {
        if let handle { sqlite3_close_v2(handle) }
        handle = nil
    }

    // MARK: - Introspection

    func tables() async throws -> [TableDescriptor] {
        let listing = try runQuery(Statement("""
            SELECT name, type FROM sqlite_master
            WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%'
            ORDER BY name
            """))

        var result: [TableDescriptor] = []
        for row in listing.rows {
            guard case .text(let name) = row[0], case .text(let type) = row[1] else { continue }
            let kind: TableKind = (type == "view") ? .view : .table
            result.append(TableDescriptor(name: name, kind: kind, columns: try columns(of: name)))
        }
        return result
    }

    func describe(table: String, schema: String?) async throws -> TableDescriptor {
        let kindResult = try runQuery(Statement(
            "SELECT type FROM sqlite_master WHERE name = ? AND type IN ('table','view')",
            bindings: [.text(table)]
        ))
        guard case .text(let type)? = kindResult.rows.first?.first else {
            throw DatabaseError.tableNotFound(table)
        }
        return TableDescriptor(
            name: table,
            kind: type == "view" ? .view : .table,
            columns: try columns(of: table)
        )
    }

    private func columns(of table: String) throws -> [ColumnDescriptor] {
        // PRAGMA does not accept bound parameters, so the name must be quoted instead.
        let quoted = try SQLIdentifier.quote(table)
        let info = try runQuery(Statement("PRAGMA table_info(\(quoted))"))

        return info.rows.compactMap { row -> ColumnDescriptor? in
            guard case .text(let name) = row[1] else { return nil }
            let declared: String = if case .text(let t) = row[2] { t } else { "" }
            let notNull = row[3].doubleValue.map { $0 != 0 } ?? false
            let pk = row[5].doubleValue.map { $0 != 0 } ?? false
            let defaultValue: String? = if case .text(let d) = row[4] { d } else { nil }

            return ColumnDescriptor(
                name: name,
                declaredType: declared,
                isNullable: !notNull,
                isPrimaryKey: pk,
                defaultValue: defaultValue
            )
        }
    }

    // MARK: - Reading

    func fetch(_ request: RowRequest) async throws -> ResultSet {
        let descriptor = try await describe(table: request.table, schema: request.schema)
        let known = Set(descriptor.columns.map(\.name))

        var sql = "SELECT * FROM \(try SQLIdentifier.quote(request.table))"
        var bindings: [SQLValue] = []

        let predicate = try PredicateBuilder.build(
            filters: request.filters,
            search: request.search,
            columns: descriptor.columns,
            dialect: .sqlite
        )
        if let clause = predicate.clause {
            sql += " WHERE \(clause)"
            bindings += predicate.bindings
        }

        if !request.sort.isEmpty {
            // Sort columns come from UI interaction, but validate against the real schema anyway —
            // a quoted-but-unknown column would otherwise surface as a raw SQL error.
            let terms = try request.sort.map { sort -> String in
                guard known.contains(sort.column) else {
                    throw DatabaseError.invalidIdentifier("Unknown column “\(sort.column)”.")
                }
                return "\(try SQLIdentifier.quote(sort.column)) \(sort.ascending ? "ASC" : "DESC")"
            }
            sql += " ORDER BY " + terms.joined(separator: ", ")
        }

        // Fetch one extra row to learn whether another page exists, without a second COUNT query.
        sql += " LIMIT ? OFFSET ?"
        bindings += [.integer(Int64(request.limit + 1)), .integer(Int64(request.offset))]
        let result = try runQuery(Statement(sql, bindings: bindings))

        let hasMore = result.rows.count > request.limit
        return ResultSet(
            columns: descriptor.columns,
            rows: hasMore ? Array(result.rows.prefix(request.limit)) : result.rows,
            hasMore: hasMore,
            elapsed: result.elapsed
        )
    }

    func count(_ request: RowRequest) async throws -> Int? {
        let descriptor = try await describe(table: request.table, schema: request.schema)
        var sql = "SELECT COUNT(*) FROM \(try SQLIdentifier.quote(request.table))"
        var bindings: [SQLValue] = []

        let predicate = try PredicateBuilder.build(
            filters: request.filters,
            search: request.search,
            columns: descriptor.columns,
            dialect: .sqlite
        )
        if let clause = predicate.clause {
            sql += " WHERE \(clause)"
            bindings = predicate.bindings
        }

        return try runQuery(Statement(sql, bindings: bindings)).scalar().map(Int.init)
    }

    func query(_ statement: Statement) async throws -> ResultSet {
        try runQuery(statement)
    }

    func execute(_ statement: Statement) async throws -> ExecutionResult {
        guard let handle else { throw DatabaseError.notConnected }
        let clock = ContinuousClock()
        let start = clock.now

        let stmt = try prepare(statement, on: handle)
        defer { sqlite3_finalize(stmt) }

        let step = sqlite3_step(stmt)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw DatabaseError.queryFailed(sql: statement.sql, message: String(cString: sqlite3_errmsg(handle)))
        }

        let lastID = sqlite3_last_insert_rowid(handle)
        return ExecutionResult(
            affectedRows: Int(sqlite3_changes(handle)),
            lastInsertID: lastID == 0 ? nil : lastID,
            elapsed: clock.now - start
        )
    }

    // MARK: - Editing

    nonisolated func preview(_ mutations: [RowMutation], to table: TableDescriptor) throws -> [String] {
        try sqlPreview(mutations, to: table, dialect: .sqlite)
    }

    func apply(_ mutations: [RowMutation], to table: TableDescriptor) async throws -> ExecutionResult {
        guard let handle else { throw DatabaseError.notConnected }
        guard !mutations.isEmpty else { return ExecutionResult(affectedRows: 0) }

        let clock = ContinuousClock()
        let start = clock.now

        // Build every statement before touching the database, so a malformed edit fails
        // without leaving a half-applied batch behind.
        let statements = try mutations.map {
            try MutationBuilder.statement(for: $0, table: table, dialect: .sqlite)
        }

        sqlite3_exec(handle, "BEGIN", nil, nil, nil)
        var affected = 0

        do {
            for statement in statements {
                let outcome = try await execute(statement)
                // A statement matching no rows means the row changed underneath us.
                guard outcome.affectedRows > 0 else {
                    throw DatabaseError.queryFailed(
                        sql: statement.sql,
                        message: "No row matched. It may have been changed or deleted by someone else."
                    )
                }
                affected += outcome.affectedRows
            }
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }

        sqlite3_exec(handle, "COMMIT", nil, nil, nil)
        return ExecutionResult(affectedRows: affected, lastInsertID: nil, elapsed: clock.now - start)
    }

    // MARK: - Plumbing

    private func prepare(_ statement: Statement, on handle: OpaquePointer) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, statement.sql, -1, &stmt, nil) == SQLITE_OK else {
            throw DatabaseError.queryFailed(sql: statement.sql, message: String(cString: sqlite3_errmsg(handle)))
        }

        for (offset, value) in statement.bindings.enumerated() {
            let index = Int32(offset + 1)
            let status: Int32 = switch value {
            case .null: sqlite3_bind_null(stmt, index)
            case .bool(let v): sqlite3_bind_int64(stmt, index, v ? 1 : 0)
            case .integer(let v): sqlite3_bind_int64(stmt, index, v)
            case .double(let v): sqlite3_bind_double(stmt, index, v)
            case .text(let v): sqlite3_bind_text(stmt, index, v, -1, SQLITE_TRANSIENT)
            case .blob(let d): d.withUnsafeBytes { sqlite3_bind_blob(stmt, index, $0.baseAddress, Int32(d.count), SQLITE_TRANSIENT) }
            // SQLite has no date type. ISO-8601 text is the convention that also sorts correctly.
            case .date(let d): sqlite3_bind_text(stmt, index, ISO8601DateFormatter().string(from: d), -1, SQLITE_TRANSIENT)
            }

            guard status == SQLITE_OK else {
                sqlite3_finalize(stmt)
                throw DatabaseError.queryFailed(sql: statement.sql, message: "Could not bind parameter \(index).")
            }
        }
        return stmt
    }

    private func runQuery(_ statement: Statement) throws -> ResultSet {
        guard let handle else { throw DatabaseError.notConnected }
        let clock = ContinuousClock()
        let start = clock.now

        let stmt = try prepare(statement, on: handle)
        defer { sqlite3_finalize(stmt) }

        let columnCount = Int(sqlite3_column_count(stmt))
        let columns = (0..<columnCount).map { index -> ColumnDescriptor in
            let i = Int32(index)
            let name = sqlite3_column_name(stmt, i).map { String(cString: $0) } ?? "column\(index)"
            let declared = sqlite3_column_decltype(stmt, i).map { String(cString: $0) } ?? ""
            return ColumnDescriptor(name: name, declaredType: declared)
        }

        var rows: [[SQLValue]] = []
        var truncated = false
        while true {
            // Stop collecting past the safety cap; an unqualified SELECT * must not be able
            // to exhaust memory just because the user did not write a LIMIT.
            if rows.count >= QueryLimits.maxRows {
                truncated = true
                break
            }
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw DatabaseError.queryFailed(sql: statement.sql, message: String(cString: sqlite3_errmsg(handle)))
            }
            rows.append((0..<columnCount).map { value(of: stmt, at: Int32($0)) })
        }

        return ResultSet(columns: columns, rows: rows, hasMore: truncated, elapsed: clock.now - start)
    }

    private func value(of stmt: OpaquePointer?, at index: Int32) -> SQLValue {
        switch sqlite3_column_type(stmt, index) {
        case SQLITE_INTEGER:
            .integer(sqlite3_column_int64(stmt, index))
        case SQLITE_FLOAT:
            .double(sqlite3_column_double(stmt, index))
        case SQLITE_BLOB:
            if let bytes = sqlite3_column_blob(stmt, index) {
                .blob(Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index))))
            } else {
                .blob(Data())
            }
        case SQLITE_NULL:
            .null
        default:
            sqlite3_column_text(stmt, index).map { .text(String(cString: $0)) } ?? .null
        }
    }
}
