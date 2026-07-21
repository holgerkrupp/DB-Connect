import Foundation
import SwiftUI

/// Tokenizer and keyword table behind the SQL console's colouring and autocomplete.
///
/// Deliberately dialect-agnostic: it colours anything that looks like SQL rather than tracking
/// each driver's grammar, so a Postgres-only word in a SQLite session is still just a keyword.
nonisolated enum SQLSyntax {
    /// Standard keywords plus the common built-in function names, uppercased.
    static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE",
        "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER", "CROSS", "ON", "USING",
        "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "AS", "AND", "OR", "NOT",
        "NULL", "IS", "IN", "LIKE", "ILIKE", "BETWEEN", "EXISTS", "UNION", "ALL", "ANY",
        "DISTINCT", "CASE", "WHEN", "THEN", "ELSE", "END", "CAST", "ASC", "DESC",
        "CREATE", "ALTER", "DROP", "TABLE", "VIEW", "INDEX", "PRIMARY", "KEY", "FOREIGN",
        "REFERENCES", "DEFAULT", "UNIQUE", "CHECK", "CONSTRAINT", "WITH", "RECURSIVE",
        "EXPLAIN", "ANALYZE", "PRAGMA", "VACUUM", "BEGIN", "COMMIT", "ROLLBACK",
        "TRANSACTION", "RETURNING", "TRUE", "FALSE",
        "COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "LOWER", "UPPER",
        "LENGTH", "SUBSTR", "ROUND", "NOW", "CURRENT_DATE", "CURRENT_TIMESTAMP",
    ]

    enum TokenKind {
        case keyword
        case identifier
        /// `"double quoted"` or `` `backticked` `` — always a name, never a keyword.
        case quotedIdentifier
        case string
        case number
        case comment
    }

    struct Token {
        let kind: TokenKind
        let range: Range<String.Index>
    }

    /// Single-pass scan. Unterminated strings/comments run to the end of the text, which is
    /// exactly how they should look while the user is still typing them.
    static func tokens(in sql: String) -> [Token] {
        var tokens: [Token] = []
        var i = sql.startIndex

        func peek(after index: String.Index) -> Character? {
            let next = sql.index(after: index)
            return next < sql.endIndex ? sql[next] : nil
        }
        func advance(_ distance: Int = 1) {
            i = sql.index(i, offsetBy: distance, limitedBy: sql.endIndex) ?? sql.endIndex
        }

        while i < sql.endIndex {
            let start = i
            let c = sql[i]

            if c == "-", peek(after: i) == "-" {
                while i < sql.endIndex, sql[i] != "\n" { advance() }
                tokens.append(Token(kind: .comment, range: start..<i))
            } else if c == "/", peek(after: i) == "*" {
                advance(2)
                while i < sql.endIndex {
                    if sql[i] == "*", peek(after: i) == "/" { advance(2); break }
                    advance()
                }
                tokens.append(Token(kind: .comment, range: start..<i))
            } else if c == "'" {
                advance()
                while i < sql.endIndex {
                    if sql[i] == "'" {
                        if peek(after: i) == "'" { advance(2); continue } // '' escapes a quote
                        advance()
                        break
                    }
                    advance()
                }
                tokens.append(Token(kind: .string, range: start..<i))
            } else if c == "\"" || c == "`" {
                advance()
                while i < sql.endIndex, sql[i] != c { advance() }
                if i < sql.endIndex { advance() }
                tokens.append(Token(kind: .quotedIdentifier, range: start..<i))
            } else if c.isNumber {
                while i < sql.endIndex, sql[i].isNumber || sql[i] == "." { advance() }
                tokens.append(Token(kind: .number, range: start..<i))
            } else if c.isLetter || c == "_" {
                while i < sql.endIndex, sql[i].isLetter || sql[i].isNumber || sql[i] == "_" { advance() }
                let word = sql[start..<i].uppercased()
                tokens.append(Token(kind: keywords.contains(word) ? .keyword : .identifier, range: start..<i))
            } else {
                advance()
            }
        }
        return tokens
    }

    static func highlighted(
        _ sql: String,
        colored: Bool = true,
        issues: [SQLIdentifierCorrection.Issue] = []
    ) -> AttributedString {
        var attributed = AttributedString(sql)
        applyHighlighting(to: &attributed, colored: colored, issues: issues)
        return attributed
    }

    /// Attribute-only mutation: characters are untouched, so the caller's selection stays valid.
    static func applyHighlighting(
        to attributed: inout AttributedString,
        colored: Bool = true,
        issues: [SQLIdentifierCorrection.Issue] = []
    ) {
        let sql = String(attributed.characters)
        let everything = attributed.startIndex..<attributed.endIndex
        attributed[everything].foregroundColor = nil
        attributed[everything].underlineStyle = nil
        attributed[everything].font = .body.monospaced()

        defer { markIssues(issues, in: &attributed) }
        guard colored else { return }

        for token in tokens(in: sql) {
            guard let range = Range(token.range, in: attributed) else { continue }
            switch token.kind {
            case .keyword:
                attributed[range].foregroundColor = .blue
                attributed[range].font = .body.monospaced().bold()
            case .string:
                attributed[range].foregroundColor = .red
            case .number:
                attributed[range].foregroundColor = .purple
            case .comment:
                attributed[range].foregroundColor = .secondary
            case .quotedIdentifier:
                attributed[range].foregroundColor = .teal
            case .identifier:
                break
            }
        }
    }

    /// Underline names that don't match the schema, in the manner of a spell checker.
    private static func markIssues(
        _ issues: [SQLIdentifierCorrection.Issue],
        in attributed: inout AttributedString
    ) {
        for issue in issues {
            let characters = attributed.characters
            guard let lower = characters.index(attributed.startIndex, offsetBy: issue.offsets.lowerBound, limitedBy: attributed.endIndex),
                  let upper = characters.index(attributed.startIndex, offsetBy: issue.offsets.upperBound, limitedBy: attributed.endIndex),
                  lower < upper
            else { continue }
            attributed[lower..<upper].underlineStyle = .single
            attributed[lower..<upper].foregroundColor = issue.confidence == .caseOnly ? .orange : .red
        }
    }
}

nonisolated struct SQLSuggestion: Hashable, Identifiable {
    enum Kind: String, Hashable {
        case keyword, table, column
    }

    let kind: Kind
    let text: String
    /// Context shown right-aligned: a column's table, a table's schema, a dot-completion's type.
    let detail: String?

    var id: String { "\(kind.rawValue)|\(text)|\(detail ?? "")" }
}

/// Completion engine for the SQL console. Pure function of (text, cursor, schema) so it is
/// trivially testable and holds no state.
nonisolated enum SQLAutocomplete {
    struct Context {
        /// Character offsets of the word being completed, to be replaced by the chosen item.
        /// Offsets, not `String.Index`, so the caller can apply them to its own copy of the text.
        let replacementOffsets: Range<Int>
        let items: [SQLSuggestion]
    }

    /// More than this and the list stops being a shortcut and starts being homework.
    static let maxSuggestions = 8

    /// After these keywords the next word is (or contains) a table name.
    private static let tableContext: Set<String> = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE", "DESCRIBE"]

    static func suggest(in sql: String, at cursor: String.Index, tables: [TableDescriptor]) -> Context? {
        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        // Never complete mid-word — only at the end of what is being typed.
        if cursor < sql.endIndex, isWordCharacter(sql[cursor]) { return nil }

        var start = cursor
        while start > sql.startIndex, isWordCharacter(sql[sql.index(before: start)]) {
            start = sql.index(before: start)
        }
        let prefix = String(sql[start..<cursor])
        let offsets = sql.distance(from: sql.startIndex, to: start)..<sql.distance(from: sql.startIndex, to: cursor)

        func matches(_ candidate: String) -> Bool {
            prefix.isEmpty || candidate.lowercased().hasPrefix(prefix.lowercased())
        }
        func finish(_ items: [SQLSuggestion]) -> Context? {
            var seen = Set<String>()
            let unique = items.filter { seen.insert($0.id).inserted }.prefix(maxSuggestions)
            // A single suggestion that is exactly what was typed helps nobody.
            if unique.count == 1, unique.first?.text.caseInsensitiveCompare(prefix) == .orderedSame { return nil }
            return unique.isEmpty ? nil : Context(replacementOffsets: offsets, items: Array(unique))
        }

        // "orders." → columns of that table only.
        if start > sql.startIndex, sql[sql.index(before: start)] == "." {
            let dot = sql.index(before: start)
            var ownerStart = dot
            while ownerStart > sql.startIndex, isWordCharacter(sql[sql.index(before: ownerStart)]) {
                ownerStart = sql.index(before: ownerStart)
            }
            let owner = String(sql[ownerStart..<dot])
            guard let table = tables.first(where: { $0.name.caseInsensitiveCompare(owner) == .orderedSame }) else {
                return nil
            }
            return finish(table.columns.filter { matches($0.name) }.map {
                SQLSuggestion(kind: .column, text: $0.name, detail: $0.declaredType)
            })
        }

        let tokens = SQLSyntax.tokens(in: sql)

        // The keyword immediately before the word decides what leads the list.
        let priorKeyword = tokens.last { $0.kind == .keyword && $0.range.upperBound <= start }
            .map { sql[$0.range].uppercased() }
        let wantsTables = priorKeyword.map(tableContext.contains) ?? false

        let tableItems = tables.filter { matches($0.name) }
            .sorted { $0.name < $1.name }
            .map { SQLSuggestion(kind: .table, text: $0.name, detail: $0.schema) }

        // With nothing typed yet, only a table position is unambiguous enough to interrupt.
        if prefix.isEmpty {
            return wantsTables ? finish(tableItems) : nil
        }

        // Columns come from tables the query mentions; with none mentioned yet, all of them.
        let mentioned = Set(tokens.filter { $0.kind == .identifier }.map { sql[$0.range].lowercased() })
        let columnSource = tables.filter { mentioned.contains($0.name.lowercased()) }
        let columnItems = (columnSource.isEmpty ? tables : columnSource).flatMap { table in
            table.columns.filter { matches($0.name) }.map {
                SQLSuggestion(kind: .column, text: $0.name, detail: table.name)
            }
        }

        let keywordItems = SQLSyntax.keywords.filter(matches).sorted()
            .map { SQLSuggestion(kind: .keyword, text: $0, detail: nil) }

        return finish(
            wantsTables
                ? tableItems + columnItems + keywordItems
                : columnItems + tableItems + keywordItems
        )
    }
}
