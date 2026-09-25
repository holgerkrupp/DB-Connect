import AppIntents
import CoreSpotlight
import Foundation
import SwiftData
import Synchronization

struct SavedQueryEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Saved Query")
    static let defaultQuery = SavedQueryEntityQuery()

    let id: UUID
    let title: String
    let connectionName: String
    let database: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: database.isEmpty ? "\(connectionName)" : "\(connectionName) · \(database)",
            image: .init(systemName: "text.page")
        )
    }

    /// Spotlight gets the same fields as the entity picker — never SQL text or results.
    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.keywords = [connectionName, database].filter { !$0.isEmpty }
        return attributes
    }

    init(_ query: WidgetSnapshot.Query) {
        id = query.id
        title = query.title
        connectionName = query.connectionName
        database = query.database
    }
}

struct SavedQueryEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [SavedQueryEntity] {
        let wanted = Set(identifiers)
        return WidgetSnapshot.load().queries.filter { wanted.contains($0.id) }.map(SavedQueryEntity.init)
    }

    func entities(matching string: String) async throws -> [SavedQueryEntity] {
        WidgetSnapshot.load().queries
            .filter {
                string.isEmpty
                    || $0.title.localizedCaseInsensitiveContains(string)
                    || $0.connectionName.localizedCaseInsensitiveContains(string)
            }
            .map(SavedQueryEntity.init)
    }

    func suggestedEntities() async throws -> [SavedQueryEntity] {
        WidgetSnapshot.load().queries.map(SavedQueryEntity.init)
    }
}

struct MonitorEntity: AppEntity, IndexedEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Monitor")
    static let defaultQuery = MonitorEntityQuery()

    let id: UUID
    let title: String
    let queryTitle: String
    let connectionName: String
    let isEnabled: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(queryTitle) · \(connectionName)",
            image: .init(systemName: isEnabled ? "bell.badge" : "bell.slash")
        )
    }

    var attributeSet: CSSearchableItemAttributeSet {
        let attributes = defaultAttributeSet
        attributes.keywords = [queryTitle, connectionName]
        return attributes
    }

    init(_ monitor: WidgetSnapshot.MonitorStatus) {
        id = monitor.id
        title = monitor.title
        queryTitle = monitor.queryTitle
        connectionName = monitor.connectionName
        isEnabled = monitor.isEnabled
    }
}

struct MonitorEntityQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [MonitorEntity] {
        let wanted = Set(identifiers)
        return WidgetSnapshot.load().monitors.filter { wanted.contains($0.id) }.map(MonitorEntity.init)
    }

    func entities(matching string: String) async throws -> [MonitorEntity] {
        WidgetSnapshot.load().monitors
            .filter {
                string.isEmpty
                    || $0.title.localizedCaseInsensitiveContains(string)
                    || $0.queryTitle.localizedCaseInsensitiveContains(string)
                    || $0.connectionName.localizedCaseInsensitiveContains(string)
            }
            .map(MonitorEntity.init)
    }

    func suggestedEntities() async throws -> [MonitorEntity] {
        WidgetSnapshot.load().monitors.map(MonitorEntity.init)
    }
}

// Both ids are the SwiftData model's UUID, which CloudKit syncs unchanged. The same query or
// monitor therefore has the same id on every device, so Siri can carry a conversation across them.
@available(iOS 27.0, macOS 27.0, *)
extension SavedQueryEntity: SyncableEntity {}

@available(iOS 27.0, macOS 27.0, *)
extension MonitorEntity: SyncableEntity {}

/// Keeps Spotlight's semantic index — which Siri also searches — in step with the widget snapshot.
@MainActor
enum SpotlightEntityIndexer {
    private static var pending: Task<Void, Never>?

    static func reindex(queries: [WidgetSnapshot.Query], monitors: [WidgetSnapshot.MonitorStatus]) {
        let previous = pending
        let queryEntities = queries.map(SavedQueryEntity.init)
        let monitorEntities = monitors.map(MonitorEntity.init)
        pending = Task {
            // Chained so two quick passes cannot interleave one's delete with the other's insert.
            await previous?.value
            let index = CSSearchableIndex.default()
            // Replace wholesale: the snapshot is small, and this drops entries for anything
            // deleted since the last pass without tracking what was indexed before.
            try? await index.deleteAppEntities(ofType: SavedQueryEntity.self)
            try? await index.deleteAppEntities(ofType: MonitorEntity.self)
            try? await index.indexAppEntities(queryEntities)
            try? await index.indexAppEntities(monitorEntities)
        }
    }
}

struct OpenSavedQueryIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Saved Query"
    static let description = IntentDescription("Opens a saved query in the DB Connect SQL console.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    @Parameter(title: "Query") var query: SavedQueryEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$query) in DB Connect")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppNavigation.shared.open(.savedQuery(query.id))
        return .result()
    }
}

struct OpenMonitorIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Monitor"
    static let description = IntentDescription("Opens a monitor and its latest status in DB Connect.")
    static let supportedModes: IntentModes = [.foreground(.immediate)]

    @Parameter(title: "Monitor") var monitor: MonitorEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$monitor) in DB Connect")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        AppNavigation.shared.open(.monitor(monitor.id))
        return .result()
    }
}

struct RunMonitorsIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Monitors Now"
    static let description = IntentDescription("Checks every enabled DB Connect monitor on this device now.")
    static let supportedModes: IntentModes = [.background]

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let container = await DB_ConnectApp.runtime.loadIfNeeded() else {
            throw IntentRuntimeError.storeUnavailable
        }
        let summary: MonitorRunSummary
        if #available(iOS 27.0, macOS 27.0, *) {
            summary = try await runWithExtendedTime(container)
        } else {
            summary = await MonitorRunCoordinator.shared.run(container: container, force: true)
        }
        WidgetSnapshotPublisher.publish(container: container)
        return .result(dialog: "\(summary.message)")
    }
}

/// Each monitor is a round trip to its database, so checking several can exceed the 30 seconds an
/// intent normally gets in the background.
@available(iOS 27.0, macOS 27.0, *)
extension RunMonitorsIntent: LongRunningIntent, CancellableIntent {
    fileprivate func runWithExtendedTime(_ container: ModelContainer) async throws -> MonitorRunSummary {
        let stop = StopFlag()
        let progress = progress
        return try await performBackgroundTask {
            await MonitorRunCoordinator.shared.run(
                container: container,
                force: true,
                shouldStop: { stop.isSet }
            ) { completed, total in
                progress.totalUnitCount = Int64(total)
                progress.completedUnitCount = Int64(completed)
            }
        } onCancel: { _ in
            // Stop before the next monitor; the ones already checked keep their results.
            stop.set()
        }
    }
}

/// Carries the intent's cancellation callback, which may arrive on any thread, to the runner's
/// check between monitors.
private nonisolated final class StopFlag: Sendable {
    private let state = Mutex(false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }
}

/// Turns monitors on or off for this device only — the same switch as the editor's "Run on this
/// device" toggle.
@available(iOS 27.0, macOS 27.0, *)
struct SetMonitorsEnabledIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Monitors On or Off"
    static let description = IntentDescription("Turns DB Connect monitors on or off on this device. Other devices keep their own setting.")
    static let supportedModes: IntentModes = [.background]
    // Writes to the shared local SwiftData store through the app runtime.
    static var allowedExecutionTargets: ExecutionTargets { .main }

    // Identifiers are all this needs: it edits the SwiftData models directly, so resolving each
    // monitor into an entity first would be wasted work.
    @Parameter(title: "Monitors") var monitors: EntityCollection<MonitorEntity>
    @Parameter(title: "State", displayName: Bool.IntentDisplayName(true: "On", false: "Off"))
    var isEnabled: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Turn \(\.$monitors) \(\.$isEnabled) on this device")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let container = await DB_ConnectApp.runtime.loadIfNeeded() else {
            throw IntentRuntimeError.storeUnavailable
        }
        let context = ModelContext(container)
        let ids = monitors.identifiers
        let matches = try context.fetch(FetchDescriptor<Monitor>(predicate: #Predicate { ids.contains($0.id) }))

        let device = DeviceIdentity.current
        for monitor in matches {
            monitor.setEnabled(isEnabled, on: device, in: context)
        }
        try context.save()
        WidgetSnapshotPublisher.publish(container: container)

        let count = matches.count
        return .result(dialog: "Turned \(isEnabled ? "on" : "off") \(count) monitor\(count == 1 ? "" : "s") on this device.")
    }
}

private enum IntentRuntimeError: LocalizedError {
    case storeUnavailable

    var errorDescription: String? {
        "DB Connect could not open its local data store."
    }
}

struct DBConnectShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSavedQueryIntent(),
            phrases: [
                "Open \(\.$query) in \(.applicationName)",
                "Show \(\.$query) in \(.applicationName)"
            ],
            shortTitle: "Open Saved Query",
            systemImageName: "text.page"
        )
        AppShortcut(
            intent: OpenMonitorIntent(),
            phrases: ["Open \(\.$monitor) in \(.applicationName)"],
            shortTitle: "Open Monitor",
            systemImageName: "bell.badge"
        )
        AppShortcut(
            intent: RunMonitorsIntent(),
            phrases: [
                "Run my \(.applicationName) monitors",
                "Check my \(.applicationName) monitors"
            ],
            shortTitle: "Run Monitors Now",
            systemImageName: "play.circle"
        )
    }
}
