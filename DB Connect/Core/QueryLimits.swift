import Foundation

/// Safety limits that stop a single query from exhausting memory.
///
/// The table browser pages explicitly, but the SQL console runs whatever the user typed —
/// and `SELECT * FROM some_huge_table` has no LIMIT. Rather than rewrite the user's SQL
/// (which would be wrong for statements that already have their own LIMIT, and impossible
/// to do safely in general), drivers stop *collecting* rows past this cap and report the
/// truncation through `ResultSet.hasMore`.
nonisolated enum QueryLimits {
    /// Maximum rows any single result will materialise.
    ///
    /// High enough that ordinary work never notices, low enough that a wide table cannot
    /// exhaust the view system or the heap.
    static let maxRows = 2_000
}
