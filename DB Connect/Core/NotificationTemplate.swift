import Foundation

/// Composes a notification body from several query results.
///
/// A monitor's *trigger* query decides whether to notify; a template decides what the message
/// says, and it may pull values from additional queries. So "142 open tickets — newest from
/// 12.03.2026" is one notification backed by two queries.
///
/// Tokens are `{{name}}`. Unknown tokens are left visible rather than silently blanked, so a
/// typo shows up in the preview instead of producing a mysteriously empty message.
nonisolated enum NotificationTemplate {

    /// Values available to a template: built-ins plus one entry per user-defined field.
    struct Context: Sendable {
        var value: Double?
        var previous: Double?
        var rowCount: Int
        var fields: [String: String]

        init(value: Double? = nil, previous: Double? = nil, rowCount: Int = 0, fields: [String: String] = [:]) {
            self.value = value
            self.previous = previous
            self.rowCount = rowCount
            self.fields = fields
        }
    }

    /// Tokens every monitor provides without configuring a field.
    static let builtInTokens = ["value", "previous", "delta", "rows", "time", "date"]

    static func render(_ template: String, context: Context, now: Date = .now) -> String {
        var output = template

        var replacements: [String: String] = [
            "value": context.value.map(format) ?? "—",
            "previous": context.previous.map(format) ?? "—",
            "delta": deltaText(context),
            "rows": String(context.rowCount),
            "time": now.formatted(date: .omitted, time: .shortened),
            "date": now.formatted(date: .abbreviated, time: .omitted)
        ]
        // User fields win, so a field named "value" can deliberately override the built-in.
        replacements.merge(context.fields) { _, field in field }

        for (token, replacement) in replacements {
            output = output.replacingOccurrences(of: "{{\(token)}}", with: replacement)
            // Tolerate the spacing people naturally type.
            output = output.replacingOccurrences(of: "{{ \(token) }}", with: replacement)
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func deltaText(_ context: Context) -> String {
        guard let value = context.value, let previous = context.previous else { return "—" }
        let delta = value - previous
        return (delta >= 0 ? "+" : "−") + format(abs(delta))
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int64(value)) : String(format: "%.2f", value)
    }

    /// Tokens referenced by a template, so the editor can warn about unresolved ones.
    static func tokens(in template: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"\{\{\s*([A-Za-z0-9_]+)\s*\}\}"#) else { return [] }
        let range = NSRange(template.startIndex..., in: template)
        return regex.matches(in: template, range: range).compactMap { match in
            Range(match.range(at: 1), in: template).map { String(template[$0]) }
        }
    }

    /// Ready-made messages, so common cases need no token syntax at all.
    struct Preset: Identifiable, Sendable, Hashable {
        var id: String { title }
        let title: String
        let template: String
        /// Extra fields this preset expects the user to point at a query.
        let suggestedFields: [String]
    }

    static let presets: [Preset] = [
        Preset(
            title: "Count only",
            template: "{{value}} entries",
            suggestedFields: []
        ),
        Preset(
            title: "Count with change",
            template: "{{value}} entries ({{delta}} since last check)",
            suggestedFields: []
        ),
        Preset(
            title: "Count with newest date",
            template: "{{value}} entries — newest from {{newest}}",
            suggestedFields: ["newest"]
        ),
        Preset(
            title: "Count, change and newest",
            template: "{{value}} entries ({{delta}}) — newest from {{newest}}",
            suggestedFields: ["newest"]
        ),
        Preset(
            title: "Status line",
            template: "{{value}} open · {{closed}} closed · checked {{time}}",
            suggestedFields: ["closed"]
        )
    ]
}

/// How a field's raw query result is rendered into text.
nonisolated enum FieldFormat: String, Sendable, CaseIterable, Identifiable {
    case automatic
    case number
    case date
    case dateTime
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .number: "Number"
        case .date: "Date"
        case .dateTime: "Date & time"
        case .text: "Text"
        }
    }

    func render(_ value: SQLValue) -> String {
        switch self {
        case .text:
            return value.displayText
        case .number:
            return value.doubleValue.map(NotificationTemplate.format) ?? value.displayText
        case .date:
            return Self.date(from: value)?.formatted(date: .numeric, time: .omitted) ?? value.displayText
        case .dateTime:
            return Self.date(from: value)?.formatted(date: .numeric, time: .shortened) ?? value.displayText
        case .automatic:
            // Dates arrive as text from most drivers, so try parsing before giving up.
            if let date = Self.date(from: value), !value.isNumeric {
                return date.formatted(date: .numeric, time: .omitted)
            }
            if let number = value.doubleValue, value.isNumeric {
                return NotificationTemplate.format(number)
            }
            return value.displayText
        }
    }

    /// Parse the date spellings databases actually emit.
    static func date(from value: SQLValue) -> Date? {
        if case .date(let date) = value { return date }
        guard case .text(let text) = value else { return nil }

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: text) { return date }
        iso.formatOptions = [.withFullDate]
        if let date = iso.date(from: text) { return date }

        for pattern in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd", "dd.MM.yyyy", "MM/dd/yyyy"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = pattern
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}

nonisolated extension SQLValue {
    /// True for values that are genuinely numeric, as opposed to text that merely parses.
    var isNumeric: Bool {
        switch self {
        case .integer, .double, .bool: true
        default: false
        }
    }
}
