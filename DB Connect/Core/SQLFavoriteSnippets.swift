import Foundation

nonisolated struct QueryFavoriteContext: Sendable, Hashable {
    let connectionName: String
    let databaseName: String
    let tableName: String?
    let now: Date

    init(connectionName: String, databaseName: String, tableName: String?, now: Date = .now) {
        self.connectionName = connectionName
        self.databaseName = databaseName
        self.tableName = tableName
        self.now = now
    }
}

nonisolated struct QueryFavoriteInsertionRequest: Identifiable, Hashable, Sendable {
    enum Mode: String, Hashable, Sendable {
        case insertAtCursor
        case replaceEditor
    }

    let id: UUID
    let sql: String
    let title: String
    let mode: Mode

    init(id: UUID = UUID(), sql: String, title: String, mode: Mode) {
        self.id = id
        self.sql = sql
        self.title = title
        self.mode = mode
    }
}

nonisolated struct QueryFavoriteExpansion: Hashable, Sendable {
    let text: String
    let selectedRange: Range<Int>?
    let cursorOffset: Int?
}

/// Expands SQL favorites and snippets without executing anything outside the editor.
///
/// DB Connect intentionally stops at text expansion. Shell-command favorites, as offered by some
/// MySQL-only tools, are deferred because executing local commands from synced SQL snippets would
/// cross a trust boundary the app does not currently model or explain well enough.
nonisolated enum QueryFavoriteSnippetExpander {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static func expand(_ template: String, context: QueryFavoriteContext) -> QueryFavoriteExpansion {
        var output = ""
        var index = template.startIndex
        var selectedRange: Range<Int>?
        var cursorOffset: Int?

        func append(_ text: String) {
            output += text
        }

        while index < template.endIndex {
            if template[index] == "$" {
                let next = template.index(after: index)
                if next < template.endIndex, template[next] == "0" {
                    cursorOffset = output.count
                    index = template.index(after: next)
                    continue
                }
                if next < template.endIndex, template[next] == "{" {
                    if let closing = template[next...].firstIndex(of: "}") {
                        let content = String(template[template.index(after: next)..<closing])
                        let start = output.count
                        let replacement = replacement(for: content, context: context)
                        append(replacement)
                        if selectedRange == nil, isPlaceholder(content) {
                            selectedRange = start..<(start + replacement.count)
                        }
                        index = template.index(after: closing)
                        continue
                    }
                } else if let token = plainToken(in: template, startingAt: next) {
                    let replacement = replacement(for: token.text, context: context)
                    append(replacement)
                    index = token.end
                    continue
                }
            }
            append(String(template[index]))
            index = template.index(after: index)
        }

        if cursorOffset == nil, let selectedRange {
            cursorOffset = selectedRange.upperBound
        }
        if selectedRange == nil, let cursorOffset {
            selectedRange = cursorOffset..<cursorOffset
        }
        return QueryFavoriteExpansion(text: output, selectedRange: selectedRange, cursorOffset: cursorOffset)
    }

    private static func isPlaceholder(_ token: String) -> Bool {
        token.contains(":") || Int(token) != nil
    }

    private static func replacement(for token: String, context: QueryFavoriteContext) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if let colon = trimmed.firstIndex(of: ":") {
            let head = trimmed[..<colon]
            let tail = trimmed[trimmed.index(after: colon)...]
            if Int(head) != nil {
                return String(tail)
            }
            let key = head.uppercased()
            if key == "PLACEHOLDER" || key == "INPUT" {
                return String(tail)
            }
        }

        switch trimmed.uppercased() {
        case "DATABASE", "CURRENT_DATABASE":
            return context.databaseName
        case "TABLE", "CURRENT_TABLE":
            return context.tableName ?? "table_name"
        case "CONNECTION", "CURRENT_CONNECTION":
            return context.connectionName
        case "DATE", "CURRENT_DATE":
            return dateFormatter.string(from: context.now)
        case "TIME", "CURRENT_TIME":
            return timeFormatter.string(from: context.now)
        default:
            if Int(trimmed) != nil {
                return ""
            }
            return "$\(trimmed)"
        }
    }

    private static func plainToken(in template: String, startingAt start: String.Index) -> (text: String, end: String.Index)? {
        var cursor = start
        while cursor < template.endIndex {
            let character = template[cursor]
            guard character.isLetter || character.isNumber || character == "_" else { break }
            cursor = template.index(after: cursor)
        }
        guard cursor > start else { return nil }
        return (String(template[start..<cursor]), cursor)
    }
}
