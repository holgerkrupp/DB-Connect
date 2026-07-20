import Foundation

/// How a column filter compares.
nonisolated enum FilterOperator: String, Sendable, Hashable, CaseIterable, Identifiable {
    case contains
    case notContains
    case equals
    case notEquals
    case startsWith
    case endsWith
    case greaterThan
    case greaterOrEqual
    case lessThan
    case lessOrEqual
    case isNull
    case isNotNull

    var id: String { rawValue }

    var title: String {
        switch self {
        case .contains: "contains"
        case .notContains: "does not contain"
        case .equals: "is"
        case .notEquals: "is not"
        case .startsWith: "starts with"
        case .endsWith: "ends with"
        case .greaterThan: "is greater than"
        case .greaterOrEqual: "is at least"
        case .lessThan: "is less than"
        case .lessOrEqual: "is at most"
        case .isNull: "is empty"
        case .isNotNull: "is not empty"
        }
    }

    var needsValue: Bool {
        self != .isNull && self != .isNotNull
    }

    /// Operators that only make sense on values you can order.
    var isComparison: Bool {
        switch self {
        case .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual: true
        default: false
        }
    }

    /// The sensible menu for a column, given its declared type.
    static func options(for column: ColumnDescriptor) -> [FilterOperator] {
        var options: [FilterOperator] = [.contains, .notContains, .equals, .notEquals, .startsWith, .endsWith]
        if column.isOrderable {
            options = [.equals, .notEquals, .greaterThan, .greaterOrEqual, .lessThan, .lessOrEqual, .contains]
        }
        if column.isNullable {
            options += [.isNull, .isNotNull]
        }
        return options
    }
}

nonisolated struct ColumnFilter: Sendable, Hashable, Identifiable {
    let id: UUID
    var column: String
    var op: FilterOperator
    var value: String

    init(id: UUID = UUID(), column: String, op: FilterOperator = .contains, value: String = "") {
        self.id = id
        self.column = column
        self.op = op
        self.value = value
    }

    /// A filter with no value is still being typed; applying it would clear the table.
    var isReady: Bool {
        !op.needsValue || !value.isEmpty
    }

    var summary: String {
        op.needsValue ? "\(column) \(op.title) \(value)" : "\(column) \(op.title)"
    }
}

nonisolated extension ColumnDescriptor {
    /// Numbers and dates support ordering comparisons; free text mostly does not.
    var isOrderable: Bool {
        let type = declaredType.lowercased()
        return ["int", "dec", "num", "float", "double", "real", "date", "time", "year", "money"]
            .contains { type.contains($0) }
    }

    /// Binary columns are excluded from text search — casting them is meaningless and slow.
    var isSearchable: Bool {
        let type = declaredType.lowercased()
        return !["blob", "binary", "bytea", "image"].contains { type.contains($0) }
    }

    /// Convert filter text into a value typed to suit the column, so numeric comparisons
    /// compare numerically rather than lexically ("9" > "10" would otherwise be true).
    func bind(_ text: String) -> SQLValue {
        let type = declaredType.lowercased()
        if type.contains("int") || type.contains("year") {
            if let value = Int64(text) { return .integer(value) }
        }
        if ["dec", "num", "float", "double", "real"].contains(where: { type.contains($0) }) {
            if let value = Double(text) { return .double(value) }
        }
        if type.contains("bool") {
            switch text.lowercased() {
            case "true", "yes", "1": return .bool(true)
            case "false", "no", "0": return .bool(false)
            default: break
            }
        }
        return .text(text)
    }
}
