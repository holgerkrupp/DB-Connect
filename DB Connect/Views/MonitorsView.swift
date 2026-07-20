import SwiftUI
import SwiftData

/// List of monitors, with this device's participation shown on each row.
struct MonitorsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.monitorScheduler) private var scheduler
    @Query(sort: \Monitor.createdAt) private var monitors: [Monitor]
    @Query private var savedQueries: [SavedQuery]

    @State private var editingMonitor: Monitor?
    @State private var historyMonitor: Monitor?
    @State private var showsNewMonitor = false
    @State private var notificationsDenied = false

    private let device = DeviceIdentity.current

    var body: some View {
        List {
            if notificationsDenied {
                Section {
                    Label {
                        Text("Notifications are turned off for DB Connect. Monitors will still run and record history, but they cannot alert you.")
                            .font(.callout)
                    } icon: {
                        Image(systemName: "bell.slash").foregroundStyle(.orange)
                    }
                }
            }

            ForEach(monitors) { monitor in
                MonitorRow(monitor: monitor, deviceID: device.id)
                    .contentShape(.rect)
                    .onTapGesture { editingMonitor = monitor }
                    .swipeActions(edge: .leading) {
                        Button("History", systemImage: "chart.xyaxis.line") {
                            historyMonitor = monitor
                        }
                        .tint(.blue)
                    }
                    .contextMenu {
                        Button("Show History", systemImage: "chart.xyaxis.line") {
                            historyMonitor = monitor
                        }
                        Button("Edit", systemImage: "pencil") { editingMonitor = monitor }
                    }
            }
            .onDelete(perform: delete)
        }
        .navigationTitle("Monitors")
        .overlay {
            if monitors.isEmpty {
                ContentUnavailableView {
                    Label("No Monitors", systemImage: "bell.badge")
                } description: {
                    Text(savedQueries.isEmpty
                         ? "Save a query first, then you can watch it for changes."
                         : "Watch a saved query and get notified when its result changes.")
                }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Add Monitor", systemImage: "plus") { showsNewMonitor = true }
                    .disabled(savedQueries.isEmpty)
            }
            ToolbarItem {
                Button("Run Now", systemImage: "play.circle") {
                    Task { await scheduler?.runDue(force: true) }
                }
                .disabled(monitors.isEmpty)
            }
        }
        .sheet(isPresented: $showsNewMonitor) {
            MonitorEditorView(monitor: nil)
        }
        .sheet(item: $editingMonitor) { monitor in
            MonitorEditorView(monitor: monitor)
        }
        .sheet(item: $historyMonitor) { monitor in
            MonitorHistoryView(monitor: monitor)
        }
        .task {
            await NotificationService.requestAuthorization()
            notificationsDenied = await !NotificationService.isAuthorized()
        }
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(monitors[index])
        }
        try? modelContext.save()
    }
}

struct MonitorRow: View {
    let monitor: Monitor
    let deviceID: String

    private var activation: MonitorActivation? { monitor.activation(for: deviceID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(monitor.title.isEmpty ? "Untitled Monitor" : monitor.title)
                    .font(.headline)
                Spacer()
                if let activation, activation.isEnabled {
                    Label("On", systemImage: "bell.fill")
                        .font(.caption)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(.green)
                }
            }

            Text(descriptionText)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                if let value = activation?.lastValue {
                    Label(MonitorRow.format(value), systemImage: "number")
                        .monospacedDigit()
                }
                if let lastRun = activation?.lastRunAt {
                    Label(lastRun.formatted(.relative(presentation: .numeric)), systemImage: "clock")
                }
                if !monitor.enabledDeviceNames.isEmpty {
                    Label(monitor.enabledDeviceNames.joined(separator: ", "), systemImage: "iphone.and.arrow.forward")
                        .lineLimit(1)
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)

            if let activation, activation.recentSamples(limit: 30).count > 1 {
                MonitorSparkline(samples: activation.recentSamples(limit: 30))
            }

            if let error = activation?.lastErrorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 3)
    }

    private var descriptionText: String {
        let rule = monitor.rule
        let subject = monitor.query?.title ?? "query"
        let condition = rule.kind.usesThreshold
            ? "\(rule.kind.title) \(MonitorRow.format(rule.threshold))"
            : rule.kind.title
        return "\(subject) · every \(monitor.intervalMinutes) min · \(condition.lowercased())"
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int64(value)) : String(format: "%.2f", value)
    }
}
