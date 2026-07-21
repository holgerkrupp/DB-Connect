import Foundation

/// Finds identifiers in a statement that nearly — but not exactly — match the live schema.
///
/// The motivating case is case: many servers are case-sensitive for table names (MySQL on
/// Linux, PostgreSQL for anything that was created quoted), so `playtimes` fails against a
/// `Playtimes` table with an error that reads like the table is missing. This catches that
/// before the round trip, and catches ordinary misspellings as a secondary, lower-confidence
/// case.
nonisolated enum SQLIdentifierCorrection {
    /// How wrong an identifier is, which decides whether it is safe to fix without asking.
    enum Confidence: Sendable, Hashable {
        /// Same letters, different case. Mechanical and safe to apply automatically.
        case caseOnly
        /// A near-match by edit distance. A real guess — offered, but only auto-applied when
        /// the user has explicitly opted in.
        case spelling
    }

    enum Role: String, Sendable, Hashable {
        case table
        case column
    }

    struct Issue: Sendable, Hashable, Identifiable {
        /// Character offsets into the statement, so the caller can apply fixes to its own copy.
        let offsets: Range<Int>
        let written: String
        let suggestion: String
        let confidence: Confidence
        let role: Role

        var id: String { "\(offsets.lowerBound)-\(offsets.upperBound)-\(suggestion)" }

        var explanation: String {
            switch confidence {
            case .caseOnly: "The \(role.rawValue) is spelled “\(suggestion)”. Some servers are case-sensitive."
            case .spelling: "No \(role.rawValue) named “\(written)”. Did you mean “\(suggestion)”?"
            }
        }
    }

    /// Keywords that introduce a table name. Matches the autocomplete's notion of table position.
    private static let tableContext: Set<String> = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE", "DESCRIBE"]

    static func issues(in sql: String, tables: [TableDescriptor]) -> [Issue] {
        guard !tables.isEmpty else { return [] }

        let tokens = SQLSyntax.tokens(in: sql)
        let tableNames = tables.map(\.name)
        let columnNames = Array(Set(tables.flatMap { $0.columns.map(\.name) }))
        let aliases = declaredAliases(in: sql, tokens: tokens, tableNames: tableNames)

        var issues: [Issue] = []

        for (index, token) in tokens.enumerated() {
            guard token.kind == .identifier else { continue }
            let written = String(sql[token.range])

            // An alias is a name the user just invented; there is nothing to match it against.
            if aliases.contains(written.lowercased()) { continue }
            // `orders.` handling: a qualified name's owner is checked as a table, and the part
            // after the dot only against that table's columns.
            let precededByDot = token.range.lowerBound > sql.startIndex
                && sql[sql.index(before: token.range.lowerBound)] == "."
            let followedByDot = token.range.upperBound < sql.endIndex
                && sql[token.range.upperBound] == "."

            let candidates: [String]
            let role: Role
            if precededByDot {
                let owner = qualifier(before: token.range.lowerBound, in: sql)
                guard let table = tables.first(where: { $0.name.caseInsensitiveCompare(owner ?? "") == .orderedSame })
                else { continue }
                candidates = table.columns.map(\.name)
                role = .column
            } else if followedByDot {
                candidates = tableNames
                role = .table
            } else {
                let priorKeyword = tokens[..<index].last { $0.kind == .keyword }
                    .map { sql[$0.range].uppercased() }
                if priorKeyword.map(tableContext.contains) ?? false {
                    candidates = tableNames
                    role = .table
                } else {
                    candidates = columnNames + tableNames
                    role = .column
                }
            }

            // Spelled exactly right — nothing to say.
            if candidates.contains(written) { continue }

            if let match = candidates.first(where: { $0.caseInsensitiveCompare(written) == .orderedSame }) {
                issues.append(Issue(
                    offsets: offsets(of: token.range, in: sql),
                    written: written,
                    suggestion: match,
                    confidence: .caseOnly,
                    role: role
                ))
            } else if let match = nearestMatch(to: written, in: candidates) {
                issues.append(Issue(
                    offsets: offsets(of: token.range, in: sql),
                    written: written,
                    suggestion: match,
                    confidence: .spelling,
                    role: role
                ))
            }
        }
        return issues
    }

    /// Apply fixes, latest first so earlier offsets stay valid.
    static func applying(_ issues: [Issue], to sql: String) -> String {
        var result = sql
        for issue in issues.sorted(by: { $0.offsets.lowerBound > $1.offsets.lowerBound }) {
            guard let lower = result.index(result.startIndex, offsetBy: issue.offsets.lowerBound, limitedBy: result.endIndex),
                  let upper = result.index(result.startIndex, offsetBy: issue.offsets.upperBound, limitedBy: result.endIndex)
            else { continue }
            result.replaceSubrange(lower..<upper, with: issue.suggestion)
        }
        return result
    }

    // MARK: - Helpers

    private static func offsets(of range: Range<String.Index>, in sql: String) -> Range<Int> {
        sql.distance(from: sql.startIndex, to: range.lowerBound)..<sql.distance(from: sql.startIndex, to: range.upperBound)
    }

    /// The identifier immediately before a dot at `index`.
    private static func qualifier(before index: String.Index, in sql: String) -> String? {
        guard index > sql.startIndex else { return nil }
        let dot = sql.index(before: index)
        guard sql[dot] == "." else { return nil }
        var start = dot
        while start > sql.startIndex {
            let previous = sql.index(before: start)
            guard sql[previous].isLetter || sql[previous].isNumber || sql[previous] == "_" else { break }
            start = previous
        }
        return start < dot ? String(sql[start..<dot]) : nil
    }

    /// Names bound by the query itself — `FROM orders o`, `JOIN x AS y`, `SELECT a AS b`.
    /// These must never be flagged: they are not schema names and have nothing to match.
    private static func declaredAliases(
        in sql: String,
        tokens: [SQLSyntax.Token],
        tableNames: [String]
    ) -> Set<String> {
        var aliases: Set<String> = []
        for (index, token) in tokens.enumerated() {
            guard token.kind == .identifier else { continue }
            let previous = index > 0 ? tokens[index - 1] : nil
            guard let previous else { continue }

            if previous.kind == .keyword, sql[previous.range].uppercased() == "AS" {
                aliases.insert(String(sql[token.range]).lowercased())
            } else if previous.kind == .identifier || previous.kind == .quotedIdentifier {
                // `FROM orders o` — an identifier directly after a table name, with no comma or
                // operator between, is an alias.
                let between = sql[previous.range.upperBound..<token.range.lowerBound]
                let bare = between.allSatisfy(\.isWhitespace)
                let previousText = String(sql[previous.range]).trimmingCharacters(in: CharacterSet(charactersIn: "\"`"))
                if bare, tableNames.contains(where: { $0.caseInsensitiveCompare(previousText) == .orderedSame }) {
                    aliases.insert(String(sql[token.range]).lowercased())
                }
            }
        }
        return aliases
    }

    /// Closest candidate within a length-scaled distance budget, and only when it beats the
    /// runner-up. An ambiguous guess between two equally-close names is worse than none.
    private static func nearestMatch(to written: String, in candidates: [String]) -> String? {
        guard written.count >= 3 else { return nil }
        let budget = written.count <= 5 ? 1 : (written.count <= 9 ? 2 : 3)

        var best: (name: String, distance: Int)?
        var runnerUp = Int.max
        for candidate in candidates {
            guard abs(candidate.count - written.count) <= budget else { continue }
            let distance = editDistance(written.lowercased(), candidate.lowercased())
            if distance < (best?.distance ?? Int.max) {
                runnerUp = best?.distance ?? Int.max
                best = (candidate, distance)
            } else if distance < runnerUp {
                runnerUp = distance
            }
        }
        guard let best, best.distance <= budget, best.distance < runnerUp else { return nil }
        return best.name
    }

    /// Damerau-Levenshtein, so a transposition ("teh") costs one rather than two — the single
    /// most common kind of typo.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        if x.isEmpty { return y.count }
        if y.isEmpty { return x.count }

        var previous2 = [Int]()
        var previous = Array(0...y.count)
        var current = [Int](repeating: 0, count: y.count + 1)

        for i in 1...x.count {
            current[0] = i
            for j in 1...y.count {
                let cost = x[i - 1] == y[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, x[i - 1] == y[j - 2], x[i - 2] == y[j - 1] {
                    current[j] = min(current[j], previous2[j - 2] + cost)
                }
            }
            previous2 = previous
            previous = current
        }
        return previous[y.count]
    }
}
