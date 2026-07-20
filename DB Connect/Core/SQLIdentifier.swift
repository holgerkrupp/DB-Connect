import Foundation

/// Quoting for table and column names.
///
/// Identifiers cannot be parameter-bound, so they are the one place user-influenced text is
/// concatenated into SQL. Everything that builds a statement from a schema name must route
/// through here.
nonisolated enum SQLIdentifier {
    enum Style: Sendable {
        /// ANSI double quotes — SQLite, PostgreSQL.
        case doubleQuote
        /// MySQL/MariaDB backticks.
        case backtick

        var delimiter: Character {
            switch self {
            case .doubleQuote: "\""
            case .backtick: "`"
            }
        }
    }

    /// Quote an identifier, escaping the delimiter by doubling it.
    ///
    /// A NUL byte terminates the identifier in most client libraries, so it is rejected outright
    /// rather than escaped — no legitimate identifier contains one.
    static func quote(_ identifier: String, style: Style = .doubleQuote) throws -> String {
        guard !identifier.isEmpty else {
            throw DatabaseError.invalidIdentifier("Identifier is empty.")
        }
        guard !identifier.contains("\0") else {
            throw DatabaseError.invalidIdentifier("Identifier contains a NUL byte.")
        }
        let d = style.delimiter
        let escaped = identifier.replacingOccurrences(of: String(d), with: String(repeating: d, count: 2))
        return "\(d)\(escaped)\(d)"
    }

    /// Quote an optional schema and a name into `"schema"."name"`.
    static func qualify(schema: String?, name: String, style: Style = .doubleQuote) throws -> String {
        let quotedName = try quote(name, style: style)
        guard let schema, !schema.isEmpty else { return quotedName }
        return "\(try quote(schema, style: style)).\(quotedName)"
    }
}
