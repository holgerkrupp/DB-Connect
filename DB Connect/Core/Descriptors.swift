import Foundation

nonisolated struct ColumnDescriptor: Sendable, Hashable, Identifiable {
    var id: String { name }

    let name: String
    /// The driver's own type spelling, e.g. "INTEGER", "varchar(255)". Shown to the user verbatim.
    let declaredType: String
    let isNullable: Bool
    let isPrimaryKey: Bool
    let defaultValue: String?
    /// Computed by the engine. Inserts and imports must omit it unless explicitly requested.
    let isGenerated: Bool

    init(
        name: String,
        declaredType: String,
        isNullable: Bool = true,
        isPrimaryKey: Bool = false,
        defaultValue: String? = nil,
        isGenerated: Bool = false
    ) {
        self.name = name
        self.declaredType = declaredType
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
        self.defaultValue = defaultValue
        self.isGenerated = isGenerated
    }
}

nonisolated enum TableKind: String, Sendable, Hashable {
    case table
    case view
}

nonisolated struct TableDescriptor: Sendable, Hashable, Identifiable {
    var id: String { qualifiedName }

    let name: String
    let schema: String?
    let kind: TableKind
    let columns: [ColumnDescriptor]

    init(name: String, schema: String? = nil, kind: TableKind = .table, columns: [ColumnDescriptor]) {
        self.name = name
        self.schema = schema
        self.kind = kind
        self.columns = columns
    }

    var qualifiedName: String {
        guard let schema else { return name }
        return "\(schema).\(name)"
    }

    var primaryKey: [String] {
        columns.filter(\.isPrimaryKey).map(\.name)
    }

    /// Whether rows in this table can be safely mutated.
    ///
    /// Without a primary key there is no way to build an `UPDATE`/`DELETE` that provably affects
    /// exactly the row the user edited — matching on displayed values can hit duplicates and
    /// silently corrupt data. Such tables open read-only, by design, and the UI explains why.
    var isEditable: Bool {
        kind == .table && !primaryKey.isEmpty
    }

    var readOnlyReason: String? {
        if kind == .view { return "Views cannot be edited." }
        if primaryKey.isEmpty { return "This table has no primary key, so rows cannot be identified safely." }
        return nil
    }
}
