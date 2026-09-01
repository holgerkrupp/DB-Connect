import Foundation

extension MySQLSession {
    var mysqlAdmin: MySQLAdminCapability {
        get async {
            guard let result = try? await query(Statement("SHOW GRANTS FOR CURRENT_USER()")) else {
                return .none
            }
            let grants = result.rows.compactMap { $0.first?.displayText.uppercased() }
            return MySQLAdminCapabilityResolver.resolve(from: grants)
        }
    }

    func mysqlTableMetadata(for target: GrantTableTarget) async throws -> MySQLTableMetadata {
        let database = try SQLIdentifier.quote(target.database, style: .backtick)
        let tablePattern = Self.sqlLikeLiteral(target.table)
        let result = try await query(Statement(
            "SHOW TABLE STATUS FROM \(database) LIKE \(tablePattern)"
        ))
        guard let row = result.rows.first else {
            throw DatabaseError.tableNotFound(target.qualifiedName)
        }

        let values = Self.namedValues(row: row, columns: result.columns)
        let overview = Self.compactMetadataFields([
            ("Engine", values["Engine"]),
            ("Rows (estimate)", values["Rows"]),
            ("Auto Increment", values["Auto_increment"]),
            ("Collation", values["Collation"]),
            ("Comment", values["Comment"])
        ])
        let storage = Self.compactMetadataFields([
            ("Row Format", values["Row_format"]),
            ("Data Length", values["Data_length"]),
            ("Index Length", values["Index_length"]),
            ("Data Free", values["Data_free"]),
            ("Create Options", values["Create_options"])
        ])
        let timestamps = Self.compactMetadataFields([
            ("Created", values["Create_time"]),
            ("Updated", values["Update_time"]),
            ("Checked", values["Check_time"])
        ])

        return MySQLTableMetadata(
            target: target,
            sections: [
                MySQLMetadataSection(title: "Overview", fields: overview),
                MySQLMetadataSection(title: "Storage", fields: storage),
                MySQLMetadataSection(title: "Timestamps", fields: timestamps)
            ].filter { !$0.fields.isEmpty }
        )
    }

    func mysqlForeignKeyRelations(for target: GrantTableTarget) async throws -> [MySQLForeignKeyRelation] {
        let outgoing = try await query(Statement(
            """
            SELECT
                k.CONSTRAINT_NAME,
                k.COLUMN_NAME,
                k.TABLE_SCHEMA,
                k.TABLE_NAME,
                k.REFERENCED_TABLE_SCHEMA,
                k.REFERENCED_TABLE_NAME,
                k.REFERENCED_COLUMN_NAME,
                rc.UPDATE_RULE,
                rc.DELETE_RULE
            FROM information_schema.KEY_COLUMN_USAGE k
            JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
              ON rc.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA
             AND rc.CONSTRAINT_NAME = k.CONSTRAINT_NAME
             AND rc.TABLE_NAME = k.TABLE_NAME
            WHERE k.TABLE_SCHEMA = ?
              AND k.TABLE_NAME = ?
              AND k.REFERENCED_TABLE_NAME IS NOT NULL
            ORDER BY k.CONSTRAINT_NAME, k.ORDINAL_POSITION
            """,
            bindings: [.text(target.database), .text(target.table)]
        ))

        let incoming = try await query(Statement(
            """
            SELECT
                k.CONSTRAINT_NAME,
                k.COLUMN_NAME,
                k.TABLE_SCHEMA,
                k.TABLE_NAME,
                k.REFERENCED_TABLE_SCHEMA,
                k.REFERENCED_TABLE_NAME,
                k.REFERENCED_COLUMN_NAME,
                rc.UPDATE_RULE,
                rc.DELETE_RULE
            FROM information_schema.KEY_COLUMN_USAGE k
            JOIN information_schema.REFERENTIAL_CONSTRAINTS rc
              ON rc.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA
             AND rc.CONSTRAINT_NAME = k.CONSTRAINT_NAME
             AND rc.TABLE_NAME = k.TABLE_NAME
            WHERE k.REFERENCED_TABLE_SCHEMA = ?
              AND k.REFERENCED_TABLE_NAME = ?
            ORDER BY k.TABLE_SCHEMA, k.TABLE_NAME, k.CONSTRAINT_NAME, k.ORDINAL_POSITION
            """,
            bindings: [.text(target.database), .text(target.table)]
        ))

        return try outgoing.rows.map { try Self.foreignKey(from: $0, direction: .outgoing) }
            + incoming.rows.map { try Self.foreignKey(from: $0, direction: .incoming) }
    }

    func mysqlTriggers(for target: GrantTableTarget) async throws -> [MySQLTriggerInfo] {
        let result = try await query(Statement(
            """
            SELECT
                TRIGGER_NAME,
                ACTION_TIMING,
                EVENT_MANIPULATION,
                ACTION_STATEMENT,
                DEFINER,
                CREATED,
                SQL_MODE
            FROM information_schema.TRIGGERS
            WHERE TRIGGER_SCHEMA = ?
              AND EVENT_OBJECT_TABLE = ?
            ORDER BY TRIGGER_NAME
            """,
            bindings: [.text(target.database), .text(target.table)]
        ))

        return result.rows.compactMap { row -> MySQLTriggerInfo? in
            guard
                let name = Self.stringValue(row, at: 0),
                let timing = Self.stringValue(row, at: 1),
                let event = Self.stringValue(row, at: 2),
                let body = Self.stringValue(row, at: 3),
                let definer = Self.stringValue(row, at: 4)
            else {
                return nil
            }
            return MySQLTriggerInfo(
                name: name,
                timing: timing,
                event: event,
                body: body,
                definer: definer,
                created: Self.stringValue(row, at: 5),
                sqlMode: Self.stringValue(row, at: 6)
            )
        }
    }

    func mysqlServerVariables() async throws -> [MySQLServerVariable] {
        if let result = try? await query(Statement("SHOW GLOBAL VARIABLES")) {
            return Self.serverVariables(from: result, isGlobal: true)
        }
        let result = try await query(Statement("SHOW VARIABLES"))
        return Self.serverVariables(from: result, isGlobal: false)
    }

    func mysqlProcesses() async throws -> [MySQLProcessInfo] {
        let result = try await query(Statement("SHOW FULL PROCESSLIST"))
        return result.rows.compactMap { row -> MySQLProcessInfo? in
            guard let id = Self.intValue(row, at: 0),
                  let user = Self.stringValue(row, at: 1),
                  let host = Self.stringValue(row, at: 2),
                  let command = Self.stringValue(row, at: 4),
                  let seconds = Self.intValue(row, at: 5)
            else {
                return nil
            }
            return MySQLProcessInfo(
                id: id,
                user: user,
                host: host,
                database: Self.stringValue(row, at: 3),
                command: command,
                seconds: seconds,
                state: Self.stringValue(row, at: 6),
                info: Self.stringValue(row, at: 7)
            )
        }
    }

    func mysqlFlushPrivileges() async throws {
        _ = try await execute(Statement("FLUSH PRIVILEGES"))
    }

    private static func namedValues(row: [SQLValue], columns: [ColumnDescriptor]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: zip(columns, row).map { column, value in
            (column.name, value.displayText)
        })
    }

    private static func compactMetadataFields(_ pairs: [(String, String?)]) -> [MySQLMetadataField] {
        pairs.compactMap { label, value in
            guard let value, !value.isEmpty, value != "NULL" else { return nil }
            return MySQLMetadataField(label: label, value: value)
        }
    }

    private static func foreignKey(from row: [SQLValue], direction: MySQLForeignKeyRelation.Direction) throws -> MySQLForeignKeyRelation {
        guard
            let constraintName = stringValue(row, at: 0),
            let column = stringValue(row, at: 1),
            let database = stringValue(row, at: 2),
            let table = stringValue(row, at: 3),
            let referencedDatabase = stringValue(row, at: 4),
            let referencedTable = stringValue(row, at: 5),
            let referencedColumn = stringValue(row, at: 6),
            let updateRule = stringValue(row, at: 7),
            let deleteRule = stringValue(row, at: 8)
        else {
            throw DatabaseError.unsupported("The server returned incomplete foreign-key metadata.")
        }

        return MySQLForeignKeyRelation(
            constraintName: constraintName,
            direction: direction,
            column: column,
            table: GrantTableTarget(database: database, table: table),
            referenced: GrantTableTarget(database: referencedDatabase, table: referencedTable),
            referencedColumn: referencedColumn,
            updateRule: updateRule,
            deleteRule: deleteRule
        )
    }

    private static func serverVariables(from result: ResultSet, isGlobal: Bool) -> [MySQLServerVariable] {
        result.rows.compactMap { row in
            guard let name = stringValue(row, at: 0), let value = stringValue(row, at: 1) else {
                return nil
            }
            return MySQLServerVariable(name: name, value: value, isGlobal: isGlobal)
        }
    }

    private static func stringValue(_ row: [SQLValue], at index: Int) -> String? {
        guard row.indices.contains(index) else { return nil }
        switch row[index] {
        case .null:
            return nil
        case .text(let value):
            return value
        default:
            return row[index].displayText
        }
    }

    private static func intValue(_ row: [SQLValue], at index: Int) -> Int64? {
        guard row.indices.contains(index) else { return nil }
        switch row[index] {
        case .integer(let value):
            return value
        case .text(let value):
            return Int64(value)
        default:
            return nil
        }
    }

    private static func sqlLikeLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "%", with: "\\%")
        return "'\(escaped)'"
    }
}
