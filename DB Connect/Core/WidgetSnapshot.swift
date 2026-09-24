import AppIntents
import Foundation
import SwiftData
import WidgetKit

/// The deliberately small, non-sensitive representation shared with widgets and entity pickers.
/// SQL text, result rows, usernames, hosts, and credentials never leave the app's own store.
nonisolated struct WidgetSnapshot: Codable, Sendable {
    static let appGroup = "group.de.holgerkrupp.DB-Connect"
    static let defaultsKey = "widget.snapshot.v1"
    static let widgetKinds = ["DBConnect.Monitor", "DBConnect.MonitorOverview", "DBConnect.SavedQueries"]

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

    func save() {
        guard let defaults = UserDefaults(suiteName: Self.appGroup),
              let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

@MainActor
enum WidgetSnapshotPublisher {
    static func publish(
        monitors: [Monitor],
        queries: [SavedQuery],
        deviceID: String = DeviceIdentity.identifier
    ) {
        var queryItems: [WidgetSnapshot.Query] = []
        for query in queries {
            queryItems.append(WidgetSnapshot.Query(
                id: query.id,
                title: query.title.isEmpty ? "Untitled Query" : query.title,
                connectionName: query.connection?.name ?? "Unknown Connection",
                database: query.database
            ))
        }
        queryItems.sort { lhs, rhs in
            if lhs.connectionName == rhs.connectionName {
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
            return lhs.connectionName.localizedStandardCompare(rhs.connectionName) == .orderedAscending
        }

        var monitorItems: [WidgetSnapshot.MonitorStatus] = []
        for monitor in monitors {
            let activation = monitor.activation(for: deviceID)
            monitorItems.append(WidgetSnapshot.MonitorStatus(
                id: monitor.id,
                title: monitor.title.isEmpty ? "Untitled Monitor" : monitor.title,
                queryTitle: monitor.query?.title ?? "Missing Query",
                connectionName: monitor.query?.connection?.name ?? "Unknown Connection",
                isEnabled: activation?.isEnabled == true,
                value: activation?.lastValue,
                lastRunAt: activation?.lastRunAt,
                lastNotifiedAt: activation?.lastNotifiedAt,
                errorMessage: activation?.lastErrorMessage
            ))
        }
        monitorItems.sort { lhs, rhs in
            lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }

        WidgetSnapshot(updatedAt: .now, queries: queryItems, monitors: monitorItems).save()
        for kind in WidgetSnapshot.widgetKinds {
            WidgetCenter.shared.reloadTimelines(ofKind: kind)
        }
        DBConnectShortcuts.updateAppShortcutParameters()
        SpotlightEntityIndexer.reindex(queries: queryItems, monitors: monitorItems)
    }

    static func publish(container: ModelContainer) {
        let context = ModelContext(container)
        let monitors = (try? context.fetch(FetchDescriptor<Monitor>())) ?? []
        let queries = (try? context.fetch(FetchDescriptor<SavedQuery>())) ?? []
        publish(monitors: monitors, queries: queries)
    }
}
