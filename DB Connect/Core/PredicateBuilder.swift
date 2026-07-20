import Foundation

/// Builds the `WHERE` clause for column filters and free-text search.
///
/// Every user-supplied value is bound; only identifiers are interpolated, through
/// `SQLIdentifier.quote`. Placeholder numbering starts where the caller says, because Postgres
/// numbers its placeholders and the surrounding query still has its own LIMIT/OFFSET binds.
nonisolated enum PredicateBuilder {

    struct Predicate: Sendable {
        /// Nil when nothing needed filtering — callers should then omit `WHERE` entirely.
        let clause: String?
        let bindings: [SQLValue]
        /// Next free placeholder index, so the caller can continue numbering.
        let nextIndex: Int
    }

    static func build(
        filters: [ColumnFilter],
        search: String?,
        columns: [ColumnDescriptor],
        dialect: SQLDialect,
        startingAt start: Int = 1
    ) throws -> Predicate {
        var terms: [String] = []
        var bindings: [SQLValue] = []
        var index = start

        let byName = Dictionary(uniqueKeysWithValues: columns.map { ($0.name, $0) })

        for filter in filters where filter.isReady {
            // Filters arrive from UI state, but validate against the live schema anyway: a
            // stale filter naming a dropped column should say so, not produce a SQL error.
            guard let column = byName[filter.column] else {
                throw DatabaseError.invalidIdentifier("Unknown column “\(filter.column)”.")
            }
            let quoted = try SQLIdentifier.quote(column.name, style: dialect.identifierStyle)

            switch filter.op {
            case .isNull:
                terms.append("\(quoted) IS NULL")
            case .isNotNull:
                terms.append("\(quoted) IS NOT NULL")

            case .equals, .notEquals, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual:
                let comparison = switch filter.op {
                case .equals: "="
                case .notEquals: "<>"
                case .greaterThan: ">"
                case .greaterOrEqual: ">="
                case .lessThan: "<"
                default: "<="
                }
                terms.append("\(quoted) \(comparison) \(dialect.placeholder(index))")
                bindings.append(column.bind(filter.value))
                index += 1

            case .contains, .notContains, .startsWith, .endsWith:
                let pattern = switch filter.op {
                case .startsWith: "\(escapeWildcards(filter.value))%"
                case .endsWith: "%\(escapeWildcards(filter.value))"
                default: "%\(escapeWildcards(filter.value))%"
                }
                let negation = filter.op == .notContains ? "NOT " : ""
                // Cast so a "contains" filter works on numbers and dates too.
                terms.append("\(dialect.castToText(quoted)) \(negation)\(dialect.caseInsensitiveLike) \(dialect.placeholder(index)) ESCAPE \(dialect.likeEscapeLiteral)")
                bindings.append(.text(pattern))
                index += 1
            }
        }

        // Free-text search: match the term anywhere, in any column the user can read.
        if let search, !search.trimmingCharacters(in: .whitespaces).isEmpty {
            let searchable = columns.filter(\.isSearchable)
            if !searchable.isEmpty {
                let pattern = "%\(escapeWildcards(search.trimmingCharacters(in: .whitespaces)))%"
                var alternatives: [String] = []
                for column in searchable {
                    let quoted = try SQLIdentifier.quote(column.name, style: dialect.identifierStyle)
                    alternatives.append("\(dialect.castToText(quoted)) \(dialect.caseInsensitiveLike) \(dialect.placeholder(index)) ESCAPE \(dialect.likeEscapeLiteral)")
                    bindings.append(.text(pattern))
                    index += 1
                }
                terms.append("(\(alternatives.joined(separator: " OR ")))")
            }
        }

        return Predicate(
            clause: terms.isEmpty ? nil : terms.joined(separator: " AND "),
            bindings: bindings,
            nextIndex: index
        )
    }

    /// Treat `%` and `_` as literal characters — a user searching for "50%" means the string,
    /// not "50 followed by anything".
    private static func escapeWildcards(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }
}
