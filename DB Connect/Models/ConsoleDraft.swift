import Foundation
import Observation

/// The SQL console's working state, owned by `ConnectionDetailView` rather than by the console
/// itself.
///
/// Switching to the table browser tears the console view down, which would otherwise discard a
/// half-written query and its results. Holding this one level up means the console is restored
/// exactly as it was left. It is per-connection and deliberately not persisted: a draft query
/// is scratch work, not a saved query.
@Observable
final class ConsoleDraft {
    var sql = ""
    var result: ResultSet?
    var executionSummary: String?
    var errorMessage: String?
    var sortOrder: [ColumnSortComparator] = []
    /// Set when a run auto-corrected identifiers, so the change is never silent.
    var correctionNotice: String?

    /// Cached schema for autocomplete. Fetching it costs one query per table, so it is loaded
    /// once per database rather than on every switch back to the console.
    private(set) var schema: [TableDescriptor] = []
    /// The database `schema` describes, and the one recorded with history entries.
    private(set) var database = ""
    private var hasLoadedSchema = false

    func needsSchema(for database: String) -> Bool {
        !hasLoadedSchema || self.database != database
    }

    func setSchema(_ tables: [TableDescriptor], for database: String) {
        schema = tables
        self.database = database
        hasLoadedSchema = true
    }

    /// A different database invalidates both the cached schema and any result on screen, which
    /// came from tables that may not exist here.
    func reset(for database: String) {
        guard database != self.database else { return }
        schema = []
        hasLoadedSchema = false
        self.database = database
        result = nil
        executionSummary = nil
        errorMessage = nil
        sortOrder = []
        correctionNotice = nil
    }
}
