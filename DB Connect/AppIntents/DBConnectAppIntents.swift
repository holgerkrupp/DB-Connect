import AppIntents
import Foundation

struct SavedQueryEntity: AppEntity {
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

struct MonitorEntity: AppEntity {
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
        let container = DB_ConnectApp.appModelContainer
        let runner = MonitorRunner(modelContainer: container)
        let fired = await runner.runDue(force: true)
        WidgetSnapshotPublisher.publish(container: container)
        return .result(dialog: fired == 0
            ? "DB Connect finished checking your enabled monitors."
            : "DB Connect finished checking your monitors and sent \(fired) alert\(fired == 1 ? "" : "s").")
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
