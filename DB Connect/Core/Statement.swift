import Foundation

/// A SQL statement with its bindings kept separate.
///
/// There is no API here that accepts an interpolated value, and that is deliberate: every value
/// reaching a database goes through `bindings`. Identifiers, which cannot be bound, go through
/// `SQLIdentifier.quote(_:)`.
nonisolated struct Statement: Sendable, Hashable {
    let sql: String
    let bindings: [SQLValue]

    init(_ sql: String, bindings: [SQLValue] = []) {
        self.sql = sql
        self.bindings = bindings
    }
}

nonisolated struct SortTerm: Sendable, Hashable {
    let column: String
    let ascending: Bool

    init(column: String, ascending: Bool = true) {
        self.column = column
        self.ascending = ascending
    }
}

/// A request for a page of rows from a table.
nonisolated struct RowRequest: Sendable, Hashable {
    let table: String
    let schema: String?
    let sort: [SortTerm]
    let limit: Int
    let offset: Int

    init(table: String, schema: String? = nil, sort: [SortTerm] = [], limit: Int = 200, offset: Int = 0) {
        self.table = table
        self.schema = schema
        self.sort = sort
        self.limit = limit
        self.offset = offset
    }

    func nextPage() -> RowRequest {
        RowRequest(table: table, schema: schema, sort: sort, limit: limit, offset: offset + limit)
    }
}

nonisolated struct ResultSet: Sendable {
    let columns: [ColumnDescriptor]
    let rows: [[SQLValue]]
    /// True when the driver stopped at the requested limit and more rows remain.
    let hasMore: Bool
    let elapsed: Duration

    init(columns: [ColumnDescriptor], rows: [[SQLValue]], hasMore: Bool = false, elapsed: Duration = .zero) {
        self.columns = columns
        self.rows = rows
        self.hasMore = hasMore
        self.elapsed = elapsed
    }

    /// Reduce a result to a single number, for monitor conditions.
    ///
    /// Defaults to the first column of the first row, which is what `SELECT COUNT(*)` produces.
    func scalar(column: String? = nil) -> Double? {
        guard let row = rows.first else { return nil }
        guard let column else { return row.first?.doubleValue }
        guard let index = columns.firstIndex(where: { $0.name == column }) else { return nil }
        return row.indices.contains(index) ? row[index].doubleValue : nil
    }
}

nonisolated struct ExecutionResult: Sendable, Hashable {
    let affectedRows: Int
    let lastInsertID: Int64?
    let elapsed: Duration

    init(affectedRows: Int, lastInsertID: Int64? = nil, elapsed: Duration = .zero) {
        self.affectedRows = affectedRows
        self.lastInsertID = lastInsertID
        self.elapsed = elapsed
    }
}
