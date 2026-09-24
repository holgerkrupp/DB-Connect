import SwiftUI

/// User preferences, stored in `UserDefaults` via `@AppStorage`.
///
/// Deliberately not in SwiftData/CloudKit: these are per-device editor behaviours, and syncing
/// them would mean a change on a phone silently rewriting SQL on a Mac.
nonisolated enum AppSettings {
    enum Key {
        static let identifierCorrection = "editor.identifierCorrection"
        static let highlightIdentifierIssues = "editor.highlightIdentifierIssues"
        static let autocompleteEnabled = "editor.autocompleteEnabled"
        static let syntaxHighlighting = "editor.syntaxHighlighting"
        static let recordHistory = "console.recordHistory"
        static let keepConnectionsAlive = "connection.keepAlive"
        static let showMonitorMenuBar = "monitor.showMenuBar"
    }

    /// How far the editor may go in fixing identifiers on its own.
    ///
    /// Case and spelling are separate levels on purpose. Correcting `playtimes` to `Playtimes`
    /// is mechanical — the letters already match, and the only question is which spelling the
    /// server accepts. Correcting `Playtime` to `Playtimes` is a guess about intent, and a
    /// wrong guess against the wrong table is a genuinely bad outcome for a DELETE or UPDATE.
    /// So the default fixes case silently and only offers spelling fixes.
    enum CorrectionMode: String, CaseIterable, Identifiable, Sendable {
        case off
        case caseOnly
        case caseAndSpelling

        var id: String { rawValue }

        var title: String {
            switch self {
            case .off: "Never"
            case .caseOnly: "Capitalization only"
            case .caseAndSpelling: "Capitalization and spelling"
            }
        }

        var explanation: String {
            switch self {
            case .off:
                "Mistakes are underlined, but nothing is changed for you."
            case .caseOnly:
                "A name that matches a table or column except for capitalization is corrected before the query runs. Suspected misspellings are only suggested."
            case .caseAndSpelling:
                "Close misspellings are corrected too. Faster, but a wrong guess runs against a different table than you intended."
            }
        }

        /// Whether an issue of this confidence may be applied without asking.
        func autoApplies(_ confidence: SQLIdentifierCorrection.Confidence) -> Bool {
            switch self {
            case .off: false
            case .caseOnly: confidence == .caseOnly
            case .caseAndSpelling: true
            }
        }
    }
}
