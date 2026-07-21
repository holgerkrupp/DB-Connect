import AppIntents
import SwiftUI
import WidgetKit

struct WidgetMonitorEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Monitor")
    static let defaultQuery = WidgetMonitorQuery()

    let id: UUID
    let title: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(detail)",
            image: .init(systemName: "bell.badge")
        )
    }

    init(_ status: WidgetSnapshot.MonitorStatus) {
        id = status.id
        title = status.title
        detail = "\(status.queryTitle) · \(status.connectionName)"
    }
}

struct WidgetMonitorQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [WidgetMonitorEntity] {
        let wanted = Set(identifiers)
        return WidgetSnapshot.load().monitors
            .filter { wanted.contains($0.id) }
            .map(WidgetMonitorEntity.init)
    }

    func suggestedEntities() async throws -> [WidgetMonitorEntity] {
        WidgetSnapshot.load().monitors.map(WidgetMonitorEntity.init)
    }

    func defaultResult() async -> WidgetMonitorEntity? {
        WidgetSnapshot.load().monitors.first.map(WidgetMonitorEntity.init)
    }
}

struct SelectMonitorIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Monitor Status"
    static let description = IntentDescription("Choose a DB Connect monitor to keep an eye on.")

    @Parameter(title: "Monitor") var monitor: WidgetMonitorEntity?
}

struct MonitorEntry: TimelineEntry {
    let date: Date
    let status: WidgetSnapshot.MonitorStatus?
    let hasMonitors: Bool
}

struct MonitorTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> MonitorEntry {
        MonitorEntry(
            date: .now,
            status: .init(
                id: UUID(),
                title: "Open Tickets",
                queryTitle: "Count open tickets",
                connectionName: "Production",
                isEnabled: true,
                value: 12,
                lastRunAt: .now.addingTimeInterval(-300),
                lastNotifiedAt: nil,
                errorMessage: nil
            ),
            hasMonitors: true
        )
    }

    func snapshot(for configuration: SelectMonitorIntent, in context: Context) async -> MonitorEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: SelectMonitorIntent, in context: Context) async -> Timeline<MonitorEntry> {
        let entry = entry(for: configuration)
        // The app asks WidgetKit to reload after every run or edit. This fallback keeps relative
        // dates from going stale if the app remains closed for a long time.
        return Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60)))
    }

    private func entry(for configuration: SelectMonitorIntent) -> MonitorEntry {
        let snapshot = WidgetSnapshot.load()
        let selected = configuration.monitor.flatMap { chosen in
            snapshot.monitors.first { $0.id == chosen.id }
        } ?? snapshot.monitors.first
        return MonitorEntry(date: .now, status: selected, hasMonitors: !snapshot.monitors.isEmpty)
    }
}

struct MonitorWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MonitorEntry

    var body: some View {
        Group {
            if let status = entry.status {
                monitor(status)
                    .widgetURL(URL(string: "db-connect://monitor/\(status.id.uuidString)"))
            } else {
                ContentUnavailableView {
                    Label("No Monitors", systemImage: "bell.slash")
                } description: {
                    Text("Create one in DB Connect")
                }
                .widgetURL(URL(string: "db-connect://monitor"))
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func monitor(_ status: WidgetSnapshot.MonitorStatus) -> some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            HStack {
                Label("DB Connect", systemImage: "cylinder.split.1x2")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: stateSymbol(for: status))
                    .foregroundStyle(stateColor(for: status))
            }

            Text(status.title)
                .font(.headline)
                .lineLimit(2)

            if let value = status.value {
                Text(value.formatted(.number.precision(.fractionLength(0...2))))
                    .font(.system(.title, design: .rounded, weight: .bold))
                    .minimumScaleFactor(0.7)
            } else {
                Text(status.isEnabled ? "Waiting for first run" : "Disabled")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            if family != .systemSmall {
                Text("\(status.queryTitle) · \(status.connectionName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let error = status.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(family == .systemSmall ? 1 : 2)
            } else if let lastRunAt = status.lastRunAt {
                Text("Checked \(lastRunAt, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func stateSymbol(for status: WidgetSnapshot.MonitorStatus) -> String {
        if status.errorMessage != nil { return "exclamationmark.triangle.fill" }
        return status.isEnabled ? "checkmark.circle.fill" : "pause.circle.fill"
    }

    private func stateColor(for status: WidgetSnapshot.MonitorStatus) -> Color {
        if status.errorMessage != nil { return .orange }
        return status.isEnabled ? .green : .secondary
    }
}

struct MonitorWidget: Widget {
    let kind = "DBConnect.Monitor"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectMonitorIntent.self,
            provider: MonitorTimelineProvider()
        ) { entry in
            MonitorWidgetView(entry: entry)
        }
        .configurationDisplayName("Monitor Status")
        .description("Shows the latest value and health of a saved-query monitor.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
