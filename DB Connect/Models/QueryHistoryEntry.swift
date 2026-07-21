import Foundation
import SwiftData

/// One executed statement, recorded so the user can get back to a query they already ran.
///
/// Distinct from `SavedQuery`: history is automatic and disposable, a saved query is deliberate
/// and named. Only the statement and its outcome are kept — never result rows, which can be
/// large and are frequently more sensitive than the query itself.
@Model
final class QueryHistoryEntry {
    var id: UUID = UUID()
    var sql: String = ""
    var executedAt: Date = Date.now
    /// The database in use when it ran, so history can be scoped per database on a connection
    /// that can switch. Empty for drivers with no such concept.
    var database: String = ""
    var succeeded: Bool = true
    /// Row count for a SELECT, affected rows for a write, nil when the statement failed.
    var rowCount: Int?
    /// Kept for failures so history doubles as a record of what went wrong.
    var errorMessage: String?
    /// Wall-clock duration in seconds.
    var duration: Double = 0

    var connection: Connection?

    init(sql: String, database: String, succeeded: Bool, rowCount: Int?, errorMessage: String?, duration: Double) {
        self.sql = sql
        self.database = database
        self.succeeded = succeeded
        self.rowCount = rowCount
        self.errorMessage = errorMessage
        self.duration = duration
    }

    /// How many entries a single connection keeps. History is a convenience, not an archive —
    /// without a cap it would grow without bound and sync forever through CloudKit.
    static let limitPerConnection = 100

    /// Record a run, collapsing an immediate repeat of the same statement into one entry so
    /// re-running a query while iterating on it does not bury everything else.
    @MainActor
    static func record(
        sql: String,
        database: String,
        succeeded: Bool,
        rowCount: Int?,
        errorMessage: String?,
        duration: Double,
        connection: Connection,
        in context: ModelContext
    ) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var entries = (connection.history ?? []).sorted { $0.executedAt > $1.executedAt }

        if let latest = entries.first, latest.sql == trimmed, latest.database == database {
            latest.executedAt = .now
            latest.succeeded = succeeded
            latest.rowCount = rowCount
            latest.errorMessage = errorMessage
            latest.duration = duration
        } else {
            let entry = QueryHistoryEntry(
                sql: trimmed,
                database: database,
                succeeded: succeeded,
                rowCount: rowCount,
                errorMessage: errorMessage,
                duration: duration
            )
            entry.connection = connection
            context.insert(entry)
            entries.insert(entry, at: 0)
        }

        for stale in entries.dropFirst(limitPerConnection) {
            context.delete(stale)
        }
        try? context.save()
    }

    /// One-line description of the outcome, for the history list.
    var summary: String {
        if !succeeded { return errorMessage ?? "Failed" }
        let time = duration.formatted(.number.precision(.fractionLength(2)))
        guard let rowCount else { return "\(time)s" }
        return "\(rowCount) row\(rowCount == 1 ? "" : "s") · \(time)s"
    }
}
