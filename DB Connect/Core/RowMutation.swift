import Foundation

/// A pending change to exactly one row.
///
/// Mutations are expressed at the *row* level rather than as SQL, because not every driver
/// speaks SQL — PostgREST turns these into HTTP verbs. Each driver translates a mutation into
/// whatever its protocol needs, which keeps the editor UI identical across all of them.
nonisolated struct RowMutation: Sendable, Hashable, Identifiable {
    enum Kind: String, Sendable, Hashable {
        case insert
        case update
        case delete
    }

    let id: UUID
    let kind: Kind
    /// Identifies the target row. Empty only for inserts; every other kind requires it.
    let primaryKey: [String: SQLValue]
    /// Changed columns for an update, all supplied columns for an insert, empty for a delete.
    let values: [String: SQLValue]

    private init(id: UUID = UUID(), kind: Kind, primaryKey: [String: SQLValue], values: [String: SQLValue]) {
        self.id = id
        self.kind = kind
        self.primaryKey = primaryKey
        self.values = values
    }

    static func update(primaryKey: [String: SQLValue], values: [String: SQLValue]) -> RowMutation {
        RowMutation(kind: .update, primaryKey: primaryKey, values: values)
    }

    static func delete(primaryKey: [String: SQLValue]) -> RowMutation {
        RowMutation(kind: .delete, primaryKey: primaryKey, values: [:])
    }

    static func insert(values: [String: SQLValue]) -> RowMutation {
        RowMutation(kind: .insert, primaryKey: [:], values: values)
    }

    /// Human-readable summary for the review sheet.
    var summary: String {
        switch kind {
        case .insert:
            "Insert row (\(values.count) value\(values.count == 1 ? "" : "s"))"
        case .update:
            "Update \(keyDescription) — \(values.keys.sorted().joined(separator: ", "))"
        case .delete:
            "Delete \(keyDescription)"
        }
    }

    var keyDescription: String {
        primaryKey
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.displayText)" }
            .joined(separator: ", ")
    }
}
