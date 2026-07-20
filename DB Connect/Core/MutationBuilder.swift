import Foundation

/// The SQL spelling differences that matter when generating statements.
nonisolated struct SQLDialect: Sendable {
    let identifierStyle: SQLIdentifier.Style
    /// Placeholder for the *n*-th bound value, 1-based. SQLite uses `?`, Postgres uses `$n`.
    let placeholder: @Sendable (Int) -> String

    static let sqlite = SQLDialect(identifierStyle: .doubleQuote, placeholder: { _ in "?" })
    static let postgres = SQLDialect(identifierStyle: .doubleQuote, placeholder: { "$\($0)" })
    static let mysql = SQLDialect(identifierStyle: .backtick, placeholder: { _ in "?" })
}

/// Turns a `RowMutation` into a parameterized statement.
///
/// Every value is bound; only identifiers are interpolated, and those go through
/// `SQLIdentifier.quote`. Columns are sorted so the generated SQL is stable and reviewable —
/// the user sees the same statement twice for the same edit.
nonisolated enum MutationBuilder {

    static func statement(
        for mutation: RowMutation,
        table: TableDescriptor,
        dialect: SQLDialect
    ) throws -> Statement {
        if let reason = table.readOnlyReason {
            throw DatabaseError.readOnly(reason: reason)
        }

        let qualified = try SQLIdentifier.qualify(
            schema: table.schema,
            name: table.name,
            style: dialect.identifierStyle
        )

        switch mutation.kind {
        case .update:
            return try update(mutation, qualified: qualified, dialect: dialect)
        case .delete:
            return try delete(mutation, qualified: qualified, dialect: dialect)
        case .insert:
            return try insert(mutation, qualified: qualified, dialect: dialect)
        }
    }

    private static func update(
        _ mutation: RowMutation,
        qualified: String,
        dialect: SQLDialect
    ) throws -> Statement {
        guard !mutation.values.isEmpty else {
            throw DatabaseError.queryFailed(sql: "", message: "The update contains no changed columns.")
        }
        try requireKey(mutation)

        var bindings: [SQLValue] = []
        var index = 1

        let assignments = try mutation.values.sorted { $0.key < $1.key }.map { column, value -> String in
            bindings.append(value)
            defer { index += 1 }
            return "\(try SQLIdentifier.quote(column, style: dialect.identifierStyle)) = \(dialect.placeholder(index))"
        }

        let (whereClause, keyBindings) = try predicate(for: mutation, dialect: dialect, startingAt: index)
        bindings.append(contentsOf: keyBindings)

        return Statement(
            "UPDATE \(qualified) SET \(assignments.joined(separator: ", ")) WHERE \(whereClause)",
            bindings: bindings
        )
    }

    private static func delete(
        _ mutation: RowMutation,
        qualified: String,
        dialect: SQLDialect
    ) throws -> Statement {
        try requireKey(mutation)
        let (whereClause, bindings) = try predicate(for: mutation, dialect: dialect, startingAt: 1)
        return Statement("DELETE FROM \(qualified) WHERE \(whereClause)", bindings: bindings)
    }

    private static func insert(
        _ mutation: RowMutation,
        qualified: String,
        dialect: SQLDialect
    ) throws -> Statement {
        guard !mutation.values.isEmpty else {
            throw DatabaseError.queryFailed(sql: "", message: "The insert contains no values.")
        }

        let sorted = mutation.values.sorted { $0.key < $1.key }
        let columns = try sorted.map {
            try SQLIdentifier.quote($0.key, style: dialect.identifierStyle)
        }
        let placeholders = sorted.indices.map { dialect.placeholder($0 + 1) }

        return Statement(
            "INSERT INTO \(qualified) (\(columns.joined(separator: ", "))) VALUES (\(placeholders.joined(separator: ", ")))",
            bindings: sorted.map(\.value)
        )
    }

    /// Builds the `WHERE` clause that pins the statement to one row.
    private static func predicate(
        for mutation: RowMutation,
        dialect: SQLDialect,
        startingAt start: Int
    ) throws -> (String, [SQLValue]) {
        var bindings: [SQLValue] = []
        var index = start

        let terms = try mutation.primaryKey.sorted { $0.key < $1.key }.map { column, value -> String in
            let quoted = try SQLIdentifier.quote(column, style: dialect.identifierStyle)
            // A NULL key would make the predicate match nothing; treat it as a broken edit.
            guard !value.isNull else {
                throw DatabaseError.readOnly(reason: "The row's key column “\(column)” is NULL, so it cannot be identified.")
            }
            bindings.append(value)
            defer { index += 1 }
            return "\(quoted) = \(dialect.placeholder(index))"
        }

        return (terms.joined(separator: " AND "), bindings)
    }

    /// The rule that keeps this whole feature safe: no key, no write.
    private static func requireKey(_ mutation: RowMutation) throws {
        guard !mutation.primaryKey.isEmpty else {
            throw DatabaseError.readOnly(
                reason: "This row has no primary key, so it cannot be changed safely."
            )
        }
    }
}
