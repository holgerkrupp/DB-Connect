import Foundation

/// A single cell value, normalised across every driver.
///
/// Drivers are responsible for mapping their native types into this enum. Anything a driver
/// cannot represent losslessly should arrive as `.text` rather than being silently coerced —
/// a wrong number is worse than a string the user can still read.
nonisolated enum SQLValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case integer(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
    case date(Date)

    var isNull: Bool { self == .null }

    /// Best-effort numeric reduction. Used by monitors to turn a result into a comparable scalar.
    var doubleValue: Double? {
        switch self {
        case .integer(let v): Double(v)
        case .double(let v): v
        case .bool(let v): v ? 1 : 0
        case .text(let v): Double(v)
        case .date(let v): v.timeIntervalSince1970
        case .null, .blob: nil
        }
    }

    /// Ordering for locally sorted grids: NULLs first, numerics and dates by magnitude,
    /// everything else by natural text comparison of the display form.
    func compare(to other: SQLValue) -> ComparisonResult {
        switch (self, other) {
        case (.null, .null): return .orderedSame
        case (.null, _): return .orderedAscending
        case (_, .null): return .orderedDescending
        default:
            if let lhs = doubleValue, let rhs = other.doubleValue {
                if lhs == rhs { return .orderedSame }
                return lhs < rhs ? .orderedAscending : .orderedDescending
            }
            return displayText.localizedStandardCompare(other.displayText)
        }
    }

    /// Display form for the result grid. Deliberately not localised — this is data, not prose.
    var displayText: String {
        switch self {
        case .null: "NULL"
        case .bool(let v): v ? "true" : "false"
        case .integer(let v): String(v)
        case .double(let v): String(v)
        case .text(let v): v
        case .blob(let d): "<\(d.count) bytes>"
        case .date(let d): ISO8601DateFormatter().string(from: d)
        }
    }
}
