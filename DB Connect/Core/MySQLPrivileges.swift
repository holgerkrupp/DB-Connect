import Foundation

/// The MySQL/MariaDB privilege model behind the Sequel Ace–style rights editor.
///
/// This is deliberately separate from the cross-driver `Privilege` enum. That enum is a small,
/// curated set used by the simple grant presets and by PostgreSQL (whose privilege names differ);
/// this catalog is the *complete* MySQL static-privilege set, including the administrative and
/// replication privileges the curated list intentionally leaves out. Keeping them apart means the
/// full editor can expose everything MySQL understands without leaking dangerous global privileges
/// into Postgres or into the "read / read-write / full" quick presets.
nonisolated struct MySQLPrivilege: Identifiable, Hashable, Sendable {

    /// The panels the editor groups privileges into — mirrors how Sequel Ace lays them out.
    enum Group: String, CaseIterable, Sendable {
        case data = "Database and Tables"
        case views = "Views and Procedures"
        case replication = "Replication"
        case administration = "Administration"
    }

    /// The keyword as it appears in `GRANT`/`REVOKE` and in `SHOW GRANTS` output, upper-cased.
    let sql: String
    /// Human label for the checkbox.
    let title: String
    let group: Group
    /// Whether the privilege is meaningful on a single database (`ON db.*`). The administrative
    /// and replication privileges are server-wide only — granting them `ON db.*` is a SQL error —
    /// so they never appear on the Schema Privileges tab.
    let schemaApplicable: Bool
    /// Privileges that can change or destroy data, so the UI can flag them.
    let isDestructive: Bool

    var id: String { sql }

    /// `GRANT OPTION` is not an ordinary privilege: on `GRANT` it is expressed as the trailing
    /// `WITH GRANT OPTION` clause rather than a list item. The editor tracks it as a separate
    /// boolean and renders it as a checkbox in the Administration group.
    var isGrantOption: Bool { sql == "GRANT OPTION" }
}

nonisolated extension MySQLPrivilege {

    /// The complete catalog, in display order within each group.
    ///
    /// Names follow MySQL's `SHOW PRIVILEGES` spelling so parsing and applying round-trip cleanly.
    /// Not every server supports every entry (MariaDB, for instance, has no `CREATE TABLESPACE`),
    /// so the editor intersects this with the server's `SHOW PRIVILEGES` before displaying.
    static let all: [MySQLPrivilege] = [
        // Database and Tables
        .init(sql: "SELECT", title: "Select", group: .data, schemaApplicable: true, isDestructive: false),
        .init(sql: "INSERT", title: "Insert", group: .data, schemaApplicable: true, isDestructive: false),
        .init(sql: "UPDATE", title: "Update", group: .data, schemaApplicable: true, isDestructive: false),
        .init(sql: "DELETE", title: "Delete", group: .data, schemaApplicable: true, isDestructive: true),
        .init(sql: "CREATE", title: "Create", group: .data, schemaApplicable: true, isDestructive: false),
        .init(sql: "DROP", title: "Drop", group: .data, schemaApplicable: true, isDestructive: true),
        .init(sql: "ALTER", title: "Alter", group: .data, schemaApplicable: true, isDestructive: true),
        .init(sql: "INDEX", title: "Index", group: .data, schemaApplicable: true, isDestructive: false),
        .init(sql: "REFERENCES", title: "References", group: .data, schemaApplicable: true, isDestructive: false),
        .init(sql: "CREATE TEMPORARY TABLES", title: "Create Temp Table", group: .data, schemaApplicable: true, isDestructive: false),
        .init(sql: "LOCK TABLES", title: "Lock Tables", group: .data, schemaApplicable: true, isDestructive: false),
        .init(sql: "TRIGGER", title: "Trigger", group: .data, schemaApplicable: true, isDestructive: false),
        .init(sql: "EVENT", title: "Event", group: .data, schemaApplicable: true, isDestructive: false),

        // Views and Procedures
        .init(sql: "CREATE VIEW", title: "Create View", group: .views, schemaApplicable: true, isDestructive: false),
        .init(sql: "SHOW VIEW", title: "Show View", group: .views, schemaApplicable: true, isDestructive: false),
        .init(sql: "CREATE ROUTINE", title: "Create Routine", group: .views, schemaApplicable: true, isDestructive: false),
        .init(sql: "ALTER ROUTINE", title: "Alter Routine", group: .views, schemaApplicable: true, isDestructive: true),
        .init(sql: "EXECUTE", title: "Execute", group: .views, schemaApplicable: true, isDestructive: false),

        // Replication (server-wide)
        .init(sql: "REPLICATION CLIENT", title: "Replication Client", group: .replication, schemaApplicable: false, isDestructive: false),
        .init(sql: "REPLICATION SLAVE", title: "Replication Slave", group: .replication, schemaApplicable: false, isDestructive: false),

        // Administration
        .init(sql: "GRANT OPTION", title: "Grant", group: .administration, schemaApplicable: true, isDestructive: false),
        .init(sql: "SUPER", title: "Super", group: .administration, schemaApplicable: false, isDestructive: true),
        .init(sql: "PROCESS", title: "Process", group: .administration, schemaApplicable: false, isDestructive: false),
        .init(sql: "RELOAD", title: "Reload", group: .administration, schemaApplicable: false, isDestructive: false),
        .init(sql: "SHUTDOWN", title: "Shutdown", group: .administration, schemaApplicable: false, isDestructive: true),
        .init(sql: "SHOW DATABASES", title: "Show Databases", group: .administration, schemaApplicable: false, isDestructive: false),
        .init(sql: "FILE", title: "File", group: .administration, schemaApplicable: false, isDestructive: false),
        .init(sql: "CREATE USER", title: "Create User", group: .administration, schemaApplicable: false, isDestructive: true),
        .init(sql: "CREATE TABLESPACE", title: "Create Tablespace", group: .administration, schemaApplicable: false, isDestructive: false),
    ]

    static let byName: [String: MySQLPrivilege] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.sql, $0) }
    )

    /// Ordinary privileges (everything except `GRANT OPTION`) valid at the given scope.
    static func names(schemaOnly: Bool) -> Set<String> {
        Set(all.lazy
            .filter { !$0.isGrantOption }
            .filter { !schemaOnly || $0.schemaApplicable }
            .map(\.sql))
    }
}

/// The privileges an account currently holds, read out of `SHOW GRANTS` and split by scope.
///
/// `GRANT OPTION` is tracked separately from the privilege sets because MySQL grants it through a
/// `WITH GRANT OPTION` clause rather than as a list entry.
nonisolated struct AccountGrants: Sendable, Equatable {
    var global: Set<String> = []
    var globalGrantOption = false
    /// Keyed by database name (the `db` in `ON db.*`).
    var schema: [String: Set<String>] = [:]
    var schemaGrantOption: [String: Bool] = [:]

    func privileges(for scope: GrantScope) -> Set<String> {
        switch scope {
        case .global: global
        case .database(let name): schema[name] ?? []
        }
    }

    func grantOption(for scope: GrantScope) -> Bool {
        switch scope {
        case .global: globalGrantOption
        case .database(let name): schemaGrantOption[name] ?? false
        }
    }
}

/// Turns raw `SHOW GRANTS` lines into an `AccountGrants`.
///
/// Kept as a free function with no server dependency so it can be unit-tested against the exact
/// strings MySQL and MariaDB emit.
nonisolated enum MySQLGrantParser {

    static func parse(_ lines: [String]) -> AccountGrants {
        var result = AccountGrants()
        for line in lines {
            guard let parsed = parseLine(line) else { continue }
            switch parsed.scope {
            case .global:
                result.global.formUnion(parsed.privileges)
                result.globalGrantOption = result.globalGrantOption || parsed.grantOption
            case .database(let db):
                result.schema[db, default: []].formUnion(parsed.privileges)
                result.schemaGrantOption[db] = (result.schemaGrantOption[db] ?? false) || parsed.grantOption
            }
        }
        return result
    }

    private struct Line {
        let scope: GrantScope
        let privileges: Set<String>
        let grantOption: Bool
    }

    /// One `GRANT … ON … TO …` statement. Returns nil for lines we do not model (table- or
    /// column-level grants, `GRANT <role> TO …`, `PROXY`).
    private static func parseLine(_ raw: String) -> Line? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard let onRange = line.range(of: " ON ", options: .caseInsensitive) else { return nil }

        // Everything before " ON ", minus the leading GRANT keyword, is the privilege list.
        var privPart = String(line[line.startIndex..<onRange.lowerBound])
        if let grantWord = privPart.range(of: "GRANT ", options: [.caseInsensitive, .anchored]) {
            privPart.removeSubrange(grantWord)
        }

        let afterOn = line[onRange.upperBound...]
        guard let toRange = afterOn.range(of: " TO ", options: .caseInsensitive) else { return nil }
        let target = afterOn[afterOn.startIndex..<toRange.lowerBound].trimmingCharacters(in: .whitespaces)
        let tail = afterOn[toRange.upperBound...]

        guard let scope = scope(from: target) else { return nil }

        // `WITH GRANT OPTION` is a suffix on the whole statement; some servers also list
        // `GRANT OPTION` among the privileges. Treat either as the grant-option flag.
        let hasWithGrantOption = tail.range(of: "WITH GRANT OPTION", options: .caseInsensitive) != nil

        let schemaOnly = scope.isDatabase
        var privileges = Set<String>()
        var listGrantOption = false

        for token in splitTopLevel(privPart) {
            let name = normalize(token)
            switch name {
            case "":
                continue
            case "USAGE":
                continue                        // USAGE means "no privileges".
            case "ALL", "ALL PRIVILEGES":
                privileges.formUnion(MySQLPrivilege.names(schemaOnly: schemaOnly))
            case "GRANT OPTION":
                listGrantOption = true
            default:
                if MySQLPrivilege.byName[name] != nil {
                    privileges.insert(name)
                }
            }
        }

        return Line(scope: scope, privileges: privileges, grantOption: hasWithGrantOption || listGrantOption)
    }

    /// `*.*` → global, `` `db`.* `` / `db.*` → that database. Table- and column-level targets
    /// (`db.tbl`) are not modelled by the editor, so they return nil and are ignored.
    private static func scope(from target: String) -> GrantScope? {
        if target == "*.*" { return .global }
        guard target.hasSuffix(".*") else { return nil }
        let dbPart = String(target.dropLast(2))
        // MySQL treats `_` and `%` as LIKE wildcards in a grant's database name, so a literal one
        // is shown backslash-escaped (`claude\_test`). Undo that, or the parsed name would not
        // match the real database and would appear as a phantom "claude\_test" entry.
        let name = unescapeGrantWildcards(unquoteIdentifier(dbPart))
        if name == "*" || name.isEmpty { return nil }
        return .database(name)
    }

    /// Reverse MySQL's grant-name escaping: `\_` → `_`, `\%` → `%`, `\\` → `\`. A backslash always
    /// takes the following character literally, which is exactly how the server escapes it.
    static func unescapeGrantWildcards(_ value: String) -> String {
        var out = ""
        var escaped = false
        for character in value {
            if escaped {
                out.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                out.append(character)
            }
        }
        if escaped { out.append("\\") }     // a lone trailing backslash is kept as-is
        return out
    }

    /// Split a privilege list on commas that are not inside parentheses, so a column list such as
    /// `SELECT (col1, col2)` stays a single token.
    private static func splitTopLevel(_ list: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var depth = 0
        for character in list {
            switch character {
            case "(": depth += 1; current.append(character)
            case ")": depth = max(0, depth - 1); current.append(character)
            case "," where depth == 0:
                tokens.append(current); current = ""
            default:
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { tokens.append(current) }
        return tokens
    }

    /// Upper-case, trimmed, with any `(column, list)` suffix stripped — a column-scoped `SELECT`
    /// still counts as the SELECT privilege for the purposes of the schema checkboxes.
    private static func normalize(_ token: String) -> String {
        var value = token.trimmingCharacters(in: .whitespaces)
        if let paren = value.firstIndex(of: "(") {
            value = String(value[value.startIndex..<paren]).trimmingCharacters(in: .whitespaces)
        }
        return value.uppercased()
    }

    private static func unquoteIdentifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        // MySQL quotes identifiers with backticks; the double-backtick escape collapses to one.
        if trimmed.hasPrefix("`") && trimmed.hasSuffix("`") && trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "``", with: "`")
        }
        // ANSI_QUOTES mode uses double quotes.
        if trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"") && trimmed.count >= 2 {
            return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "\"\"", with: "\"")
        }
        return trimmed
    }
}

private nonisolated extension GrantScope {
    var isDatabase: Bool {
        if case .database = self { return true }
        return false
    }
}
