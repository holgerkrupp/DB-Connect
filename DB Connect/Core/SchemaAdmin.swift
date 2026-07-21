import Foundation

/// What this *connection* may do to the schema — not just what the driver supports.
///
/// Mirrors `UserAdminCapability`: each action is gated separately, because the privileges
/// genuinely are separate. An account can very often create tables in the database it is
/// connected to while having no right at all to create new databases.
nonisolated struct SchemaAdminCapability: Sendable, Hashable {
    /// Can create tables in the database currently in use.
    let canCreateTable: Bool
    /// Can drop tables in the database currently in use.
    let canDropTable: Bool
    /// Can create new databases on the server.
    let canCreateDatabase: Bool

    static let none = SchemaAdminCapability(
        canCreateTable: false,
        canDropTable: false,
        canCreateDatabase: false
    )

    /// A local file the user already has write access to — SQLite, where there is no privilege
    /// system and the only question is whether the file opened read-write.
    static let localFile = SchemaAdminCapability(
        canCreateTable: true,
        canDropTable: true,
        canCreateDatabase: false
    )
}

/// A portable column type, mapped to each engine's spelling at generation time.
///
/// Deliberately a short list. This is the "create a table" path, not a schema migration tool:
/// anything exotic is better written by hand in the SQL console, and offering fifty types would
/// make the common case harder rather than the rare case possible.
nonisolated enum ColumnType: String, Sendable, Hashable, CaseIterable, Identifiable {
    case integer
    case bigInteger
    case text
    case varchar
    case boolean
    case real
    case decimal
    case date
    case timestamp
    case uuid
    case json
    case blob

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .integer: "Integer"
        case .bigInteger: "Big Integer"
        case .text: "Text"
        case .varchar: "Text (limited)"
        case .boolean: "Boolean"
        case .real: "Decimal (floating)"
        case .decimal: "Decimal (exact)"
        case .date: "Date"
        case .timestamp: "Timestamp"
        case .uuid: "UUID"
        case .json: "JSON"
        case .blob: "Binary"
        }
    }

    /// Whether `length` applies. Only the limited-text type uses it.
    var usesLength: Bool { self == .varchar }

    /// Whether this type can carry an auto-incrementing identity.
    var supportsAutoIncrement: Bool { self == .integer || self == .bigInteger }

    /// The engine's own spelling.
    ///
    /// SQLite is the odd one out: it has five storage classes and treats everything else as an
    /// affinity hint, so the richer types collapse onto TEXT or NUMERIC rather than erroring.
    func sql(for family: SQLDialect.Family, length: Int?) -> String {
        let n = max(1, min(length ?? 255, 65_535))
        switch family {
        case .sqlite:
            switch self {
            case .integer, .bigInteger, .boolean: return "INTEGER"
            case .text, .varchar, .date, .timestamp, .uuid, .json: return "TEXT"
            case .real: return "REAL"
            case .decimal: return "NUMERIC"
            case .blob: return "BLOB"
            }
        case .postgres:
            switch self {
            case .integer: return "INTEGER"
            case .bigInteger: return "BIGINT"
            case .text: return "TEXT"
            case .varchar: return "VARCHAR(\(n))"
            case .boolean: return "BOOLEAN"
            case .real: return "DOUBLE PRECISION"
            case .decimal: return "NUMERIC"
            case .date: return "DATE"
            case .timestamp: return "TIMESTAMPTZ"
            case .uuid: return "UUID"
            case .json: return "JSONB"
            case .blob: return "BYTEA"
            }
        case .mysql:
            switch self {
            case .integer: return "INT"
            case .bigInteger: return "BIGINT"
            // TEXT columns cannot carry a DEFAULT or be fully indexed in MySQL, but that is
            // the price of unbounded text; the limited variant exists for when it matters.
            case .text: return "TEXT"
            case .varchar: return "VARCHAR(\(n))"
            case .boolean: return "TINYINT(1)"
            case .real: return "DOUBLE"
            case .decimal: return "DECIMAL(10,2)"
            case .date: return "DATE"
            case .timestamp: return "DATETIME"
            case .uuid: return "CHAR(36)"
            case .json: return "JSON"
            case .blob: return "BLOB"
            }
        }
    }
}

/// One column in a table being created.
nonisolated struct NewColumn: Sendable, Hashable, Identifiable {
    var id = UUID()
    var name: String = ""
    var type: ColumnType = .text
    var length: Int? = nil
    var isNullable: Bool = true
    var isPrimaryKey: Bool = false
    var isUnique: Bool = false
    var isAutoIncrement: Bool = false
    /// Raw text as typed by the user. Rendered safely by `SQLDDLBuilder` — see `defaultClause`.
    var defaultValue: String = ""

    init(
        name: String = "",
        type: ColumnType = .text,
        length: Int? = nil,
        isNullable: Bool = true,
        isPrimaryKey: Bool = false,
        isUnique: Bool = false,
        isAutoIncrement: Bool = false,
        defaultValue: String = ""
    ) {
        self.name = name
        self.type = type
        self.length = length
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.isUnique = isUnique
        self.isAutoIncrement = isAutoIncrement
        self.defaultValue = defaultValue
    }
}

nonisolated struct NewTableSpec: Sendable, Hashable {
    var name: String
    var schema: String?
    var columns: [NewColumn]

    init(name: String, schema: String? = nil, columns: [NewColumn]) {
        self.name = name
        self.schema = schema
        self.columns = columns
    }
}

nonisolated enum SchemaError: Error, LocalizedError, Equatable {
    case notPermitted(String)
    case invalidName(String)
    case noColumns
    case duplicateColumn(String)

    var errorDescription: String? {
        switch self {
        case .notPermitted(let detail): detail
        case .invalidName(let detail): detail
        case .noColumns: "A table needs at least one column."
        case .duplicateColumn(let name): "There is more than one column named “\(name)”."
        }
    }
}

/// Generates `CREATE TABLE` and `CREATE DATABASE` statements.
///
/// DDL cannot be parameterized — neither identifiers nor DEFAULT expressions can be bound — so
/// everything here is string construction, and every piece of user text is either routed through
/// `SQLIdentifier.quote` or run through `defaultClause`'s allowlist below. Nothing else is
/// interpolated.
nonisolated enum SQLDDLBuilder {

    static func createTable(_ spec: NewTableSpec, dialect: SQLDialect) throws -> Statement {
        let columns = spec.columns.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !columns.isEmpty else { throw SchemaError.noColumns }

        var seen: Set<String> = []
        for column in columns {
            let key = column.name.lowercased()
            guard seen.insert(key).inserted else {
                throw SchemaError.duplicateColumn(column.name)
            }
        }

        let style = dialect.identifierStyle
        let qualified = try SQLIdentifier.qualify(schema: spec.schema, name: spec.name, style: style)

        let keyColumns = columns.filter(\.isPrimaryKey)
        // SQLite only recognises AUTOINCREMENT on a column-level `INTEGER PRIMARY KEY`, so a
        // single auto-increment key has to be declared inline rather than as a table constraint.
        let inlinePrimaryKey = dialect.family == .sqlite
            && keyColumns.count == 1
            && keyColumns[0].isAutoIncrement

        var definitions = try columns.map { column in
            try definition(for: column, dialect: dialect, inlinePrimaryKey: inlinePrimaryKey)
        }

        if !keyColumns.isEmpty && !inlinePrimaryKey {
            let names = try keyColumns.map { try SQLIdentifier.quote($0.name, style: style) }
            definitions.append("PRIMARY KEY (\(names.joined(separator: ", ")))")
        }

        let body = definitions.map { "    \($0)" }.joined(separator: ",\n")
        return Statement("CREATE TABLE \(qualified) (\n\(body)\n)")
    }

    private static func definition(
        for column: NewColumn,
        dialect: SQLDialect,
        inlinePrimaryKey: Bool
    ) throws -> String {
        let name = try SQLIdentifier.quote(
            column.name.trimmingCharacters(in: .whitespaces),
            style: dialect.identifierStyle
        )
        let autoIncrement = column.isAutoIncrement && column.type.supportsAutoIncrement && column.isPrimaryKey

        var parts: [String] = [name]

        // Postgres spells identity as a column constraint after the type; SQLite requires the
        // bare INTEGER type; MySQL appends a keyword. Three shapes, so build the type per family.
        switch (dialect.family, autoIncrement) {
        case (.sqlite, true):
            parts.append("INTEGER")
        case (.postgres, true):
            parts.append(column.type.sql(for: .postgres, length: column.length))
            parts.append("GENERATED BY DEFAULT AS IDENTITY")
        default:
            parts.append(column.type.sql(for: dialect.family, length: column.length))
        }

        if inlinePrimaryKey && column.isPrimaryKey {
            parts.append("PRIMARY KEY")
            if dialect.family == .sqlite && autoIncrement {
                parts.append("AUTOINCREMENT")
            }
        }

        // An auto-increment key is implicitly NOT NULL everywhere; saying so again is harmless
        // but noisy, and on SQLite `INTEGER PRIMARY KEY NOT NULL` is a different beast.
        if !column.isNullable && !autoIncrement {
            parts.append("NOT NULL")
        }

        if let clause = defaultClause(column.defaultValue, type: column.type, dialect: dialect) {
            // MySQL refuses a literal DEFAULT on TEXT, BLOB and JSON columns; the value has to
            // be written as an expression default instead, which MySQL 8.0.13+ and MariaDB
            // 10.2+ accept. Older servers reject a default on these types however it is spelled.
            let needsExpressionForm = dialect.family == .mysql
                && [.text, .blob, .json].contains(column.type)
            parts.append(needsExpressionForm ? "DEFAULT (\(clause))" : "DEFAULT \(clause)")
        }

        if column.isUnique && !column.isPrimaryKey {
            parts.append("UNIQUE")
        }

        if dialect.family == .mysql && autoIncrement {
            parts.append("AUTO_INCREMENT")
        }

        return parts.joined(separator: " ")
    }

    /// Render a user-typed default safely.
    ///
    /// A DEFAULT can legitimately be an expression (`CURRENT_TIMESTAMP`), which rules out
    /// binding it — so instead of trusting the text, only a fixed set of keywords and numeric
    /// literals pass through verbatim. Everything else becomes an escaped string literal, which
    /// is inert whatever it contains. The worst case for a user who meant an expression is a
    /// default that reads literally, not a statement that runs something unintended.
    static func defaultClause(_ raw: String, type: ColumnType, dialect: SQLDialect) -> String? {
        let value = raw.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return nil }

        let upper = value.uppercased()
        if upper == "NULL" { return "NULL" }
        if upper == "TRUE" || upper == "FALSE" {
            // SQLite and older MySQL store booleans as integers; the keywords work, but 1/0 is
            // what actually comes back out, so write what the engine will store.
            switch dialect.family {
            case .sqlite, .mysql: return upper == "TRUE" ? "1" : "0"
            case .postgres: return upper
            }
        }
        // Spelled the same on all three engines, and the one expression worth allowing through.
        if upper == "CURRENT_TIMESTAMP" || upper == "NOW()" {
            return "CURRENT_TIMESTAMP"
        }
        if Double(value) != nil {
            return value
        }
        return sqlStringLiteral(value, dialect: dialect)
    }

    /// Escape text as a SQL string literal.
    ///
    /// MySQL treats backslash as an escape character inside literals, so it must be doubled
    /// first — escaping the quote first would leave a stray backslash able to escape it back.
    static func sqlStringLiteral(_ value: String, dialect: SQLDialect) -> String {
        switch dialect.family {
        case .mysql:
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            return "'\(escaped)'"
        case .sqlite, .postgres:
            return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
        }
    }

    static func createDatabase(name: String, dialect: SQLDialect) throws -> Statement {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw SchemaError.invalidName("The database name cannot be empty.")
        }
        let quoted = try SQLIdentifier.quote(trimmed, style: dialect.identifierStyle)
        switch dialect.family {
        case .mysql:
            // utf8mb4 rather than the server default, which on older MySQL is a three-byte
            // "utf8" that cannot store emoji or much of CJK.
            return Statement("CREATE DATABASE \(quoted) CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci")
        case .postgres:
            return Statement("CREATE DATABASE \(quoted)")
        case .sqlite:
            throw SchemaError.notPermitted("A SQLite connection is a single file and has no other databases.")
        }
    }

    static func dropTable(_ table: TableDescriptor, dialect: SQLDialect) throws -> Statement {
        let qualified = try SQLIdentifier.qualify(
            schema: table.schema,
            name: table.name,
            style: dialect.identifierStyle
        )
        return Statement("DROP \(table.kind == .view ? "VIEW" : "TABLE") \(qualified)")
    }
}
