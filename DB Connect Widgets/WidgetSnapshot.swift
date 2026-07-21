import Foundation

/// Mirrors the main app's privacy-safe snapshot. Keep this target independent of SwiftData so
/// WidgetKit never needs to open the CloudKit store or load database-driver dependencies.
nonisolated struct WidgetSnapshot: Codable, Sendable {
    static let appGroup = "group.de.holgerkrupp.DB-Connect"
    static let defaultsKey = "widget.snapshot.v1"

    struct Query: Codable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let connectionName: String
        let database: String
    }

    struct MonitorStatus: Codable, Identifiable, Sendable {
        let id: UUID
        let title: String
        let queryTitle: String
        let connectionName: String
        let isEnabled: Bool
        let value: Double?
        let lastRunAt: Date?
        let lastNotifiedAt: Date?
        let errorMessage: String?
    }

    let updatedAt: Date
    let queries: [Query]
    let monitors: [MonitorStatus]

    static let empty = WidgetSnapshot(updatedAt: .now, queries: [], monitors: [])

    static func load() -> WidgetSnapshot {
        guard let defaults = UserDefaults(suiteName: appGroup),
              let data = defaults.data(forKey: defaultsKey),
              let snapshot = try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }
}
