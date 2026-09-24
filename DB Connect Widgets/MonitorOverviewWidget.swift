import SwiftUI
import WidgetKit

struct MonitorOverviewEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct MonitorOverviewProvider: TimelineProvider {
    func placeholder(in context: Context) -> MonitorOverviewEntry {
        MonitorOverviewEntry(
            date: .now,
            snapshot: WidgetSnapshot(
                updatedAt: .now,
                queries: [],
                monitors: [
                    .init(
                        id: UUID(),
                        title: "Open Tickets",
                        queryTitle: "Count open tickets",
                        connectionName: "Production",
                        isEnabled: true,
                        value: 12,
                        lastRunAt: .now.addingTimeInterval(-300),
                        lastNotifiedAt: nil,
                        errorMessage: nil
                    )
                ]
            )
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (MonitorOverviewEntry) -> Void) {
        completion(MonitorOverviewEntry(date: .now, snapshot: WidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MonitorOverviewEntry>) -> Void) {
        let entry = MonitorOverviewEntry(date: .now, snapshot: WidgetSnapshot.load())
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

struct MonitorOverviewWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MonitorOverviewEntry

    private var monitors: [WidgetSnapshot.MonitorStatus] { entry.snapshot.monitors }
    private var enabled: [WidgetSnapshot.MonitorStatus] { monitors.filter(\.isEnabled) }
    private var errors: [WidgetSnapshot.MonitorStatus] { monitors.filter { $0.errorMessage != nil } }

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text(inlineSummary)
            case .accessoryRectangular:
                accessoryContent
            default:
                systemContent
            }
        }
        .widgetURL(URL(string: "db-connect://monitor"))
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var inlineSummary: String {
        if !errors.isEmpty { return "DB Connect: \(errors.count) monitor\(errors.count == 1 ? "" : "s") need attention" }
        return "DB Connect: \(enabled.count) monitor\(enabled.count == 1 ? "" : "s") active"
    }

    private var accessoryContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("DB Connect", systemImage: errors.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.headline)
            Text(errors.isEmpty ? "\(enabled.count) active monitors" : "\(errors.count) need attention")
                .font(.caption)
            if let latest = enabled.compactMap(\.lastRunAt).max() {
                Text("Checked \(latest, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var systemContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Monitors", systemImage: "bell.badge.fill")
                    .font(.headline)
                Spacer()
                Label("\(enabled.count) active", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }

            if monitors.isEmpty {
                ContentUnavailableView {
                    Label("No Monitors", systemImage: "bell.slash")
                } description: {
                    Text("Create one in DB Connect")
                }
            } else {
                VStack(spacing: 7) {
                    ForEach(Array(sortedMonitors.prefix(family == .systemLarge ? 7 : 3))) { status in
                        HStack(spacing: 7) {
                            Image(systemName: symbol(for: status))
                                .foregroundStyle(color(for: status))
                            Text(status.title)
                                .lineLimit(1)
                            Spacer()
                            if let value = status.value {
                                Text(value.formatted(.number.precision(.fractionLength(0...2))))
                                    .monospacedDigit()
                                    .fontWeight(.semibold)
                            } else {
                                Text(status.isEnabled ? "Waiting" : "Off")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .font(.callout)
                    }
                }
                if monitors.count > (family == .systemLarge ? 7 : 3) {
                    Text("+ \(monitors.count - (family == .systemLarge ? 7 : 3)) more")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)
            if let latest = enabled.compactMap(\.lastRunAt).max() {
                Text("Last successful check \(latest, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var sortedMonitors: [WidgetSnapshot.MonitorStatus] {
        monitors.sorted { lhs, rhs in
            let lhsRank = lhs.errorMessage != nil ? 0 : (lhs.isEnabled ? 1 : 2)
            let rhsRank = rhs.errorMessage != nil ? 0 : (rhs.isEnabled ? 1 : 2)
            return lhsRank == rhsRank
                ? lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                : lhsRank < rhsRank
        }
    }

    private func symbol(for status: WidgetSnapshot.MonitorStatus) -> String {
        if status.errorMessage != nil { return "exclamationmark.triangle.fill" }
        return status.isEnabled ? "checkmark.circle.fill" : "pause.circle.fill"
    }

    private func color(for status: WidgetSnapshot.MonitorStatus) -> Color {
        if status.errorMessage != nil { return .orange }
        return status.isEnabled ? .green : .secondary
    }
}

struct MonitorOverviewWidget: Widget {
    let kind = "DBConnect.MonitorOverview"

    private var families: [WidgetFamily] {
        #if os(iOS)
        [.systemMedium, .systemLarge, .accessoryInline, .accessoryRectangular]
        #else
        [.systemMedium, .systemLarge]
        #endif
    }

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: MonitorOverviewProvider()) { entry in
            MonitorOverviewWidgetView(entry: entry)
        }
        .configurationDisplayName("Monitor Overview")
        .description("See active monitors, recent values, and problems at a glance.")
        .supportedFamilies(families)
    }
}
