import SwiftUI
import SwiftData

/// Master–detail view of monitors: the list is the sidebar and the selected monitor's editor
/// fills the detail pane. Creating, editing and deleting all happen here rather than in sheets.
struct MonitorsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.monitorScheduler) private var scheduler
    @Query(sort: \Monitor.createdAt) private var monitors: [Monitor]
    @Query private var savedQueries: [SavedQuery]

    @State private var selection: Selection?
    @State private var notificationsDenied = false
    /// Set to route a delete request through one confirmation, wherever it came from (the list's
    /// swipe/context menu or the editor's Delete button).
    @State private var monitorToDelete: Monitor?

    private let device = DeviceIdentity.current

    /// The detail pane shows either an existing monitor's editor or a blank one for a new monitor.
    /// A separate `.draft` case keeps the new-monitor form from being confused with any saved row.
    enum Selection: Hashable {
        case draft
        case existing(Monitor)
    }

    var body: some View {
        content
            .confirmationDialog(
                "Delete “\(monitorToDelete?.title.isEmpty == false ? monitorToDelete!.title : "this monitor")”?",
                isPresented: .constant(monitorToDelete != nil),
                titleVisibility: .visible
            ) {
                Button("Delete Monitor", role: .destructive) {
                    if let monitorToDelete { performDelete(monitorToDelete) }
                    monitorToDelete = nil
                }
                Button("Cancel", role: .cancel) { monitorToDelete = nil }
            } message: {
                Text("This removes the monitor and its recorded history on every device. The saved query it watches is untouched.")
            }
            .task {
                await NotificationService.requestAuthorization()
                notificationsDenied = await !NotificationService.isAuthorized()
            }
    }

    @ViewBuilder
    private var content: some View {
        #if os(macOS)
        HSplitView {
            sidebar
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 460)
            detail
                .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Monitors")
        .toolbar { runNowButton }
        #else
        NavigationStack {
            sidebar
                .navigationTitle("Monitors")
                .toolbar { runNowButton }
                .navigationDestination(item: $selection) { selection in
                    editor(for: selection)
                        .navigationTitle(selection.isDraft ? "New Monitor" : "Edit Monitor")
                        #if !os(macOS)
                        .navigationBarTitleDisplayMode(.inline)
                        #endif
                }
        }
        #endif
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            if notificationsDenied {
                notificationsBanner
                Divider()
            }

            List(selection: $selection) {
                ForEach(monitors) { monitor in
                    MonitorRow(monitor: monitor, deviceID: device.id)
                        .tag(Selection.existing(monitor))
                        .swipeActions(edge: .trailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                monitorToDelete = monitor
                            }
                        }
                        .contextMenu {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                monitorToDelete = monitor
                            }
                        }
                }
            }
            .listStyle(.sidebar)
            .overlay {
                if monitors.isEmpty { emptyState }
            }
        }
        .frame(maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) { addBar }
    }

    private var addBar: some View {
        Button {
            selection = .draft
        } label: {
            Label("New Monitor", systemImage: "plus")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Without this the hit area is only the text; the empty stretch beside it looks
                // clickable but is not.
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .disabled(savedQueries.isEmpty)
        .help(savedQueries.isEmpty ? "Save a query first, then you can watch it." : "Create a monitor")
        .bottomBar()
    }

    private var notificationsBanner: some View {
        Label {
            Text("Notifications are turned off for DB Connect. Monitors will still run and record history, but they cannot alert you.")
                .font(.caption)
        } icon: {
            Image(systemName: "bell.slash").foregroundStyle(.orange)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Monitors", systemImage: "bell.badge")
        } description: {
            Text(savedQueries.isEmpty
                 ? "Save a query first, then you can watch it for changes."
                 : "Watch a saved query and get notified when its result changes.")
        } actions: {
            if !savedQueries.isEmpty {
                Button("New Monitor", systemImage: "plus") { selection = .draft }
            }
        }
    }

    // MARK: Detail

    /// The macOS detail column. On iOS the same editor is reached by pushing — see `content`.
    @ViewBuilder
    private var detail: some View {
        if let selection {
            editor(for: selection)
        } else {
            ContentUnavailableView(
                "No Monitor Selected",
                systemImage: "bell.badge",
                description: Text(monitors.isEmpty
                                  ? "Create a monitor to watch a saved query."
                                  : "Select a monitor to edit it, or create a new one.")
            )
        }
    }

    @ViewBuilder
    private func editor(for selection: Selection) -> some View {
        switch selection {
        case .draft:
            MonitorEditorView(
                monitor: nil,
                onSaved: { self.selection = .existing($0) },
                onCancel: { self.selection = nil }
            )
            // A fresh identity so the form starts blank and does not inherit a previous monitor's
            // field state.
            .id(Selection.draft)
        case .existing(let monitor):
            MonitorEditorView(
                monitor: monitor,
                onSaved: { self.selection = .existing($0) },
                onDelete: { monitorToDelete = $0 }
            )
            // Rebuild when a different monitor is selected so its values load via `onAppear`.
            .id(monitor.id)
        }
    }

    private var runNowButton: some View {
        Button("Run Now", systemImage: "play.circle") {
            Task { await scheduler?.runDue(force: true) }
        }
        .disabled(monitors.isEmpty)
    }

    // MARK: Deletion

    private func performDelete(_ monitor: Monitor) {
        if selection == .existing(monitor) { selection = nil }
        modelContext.delete(monitor)
        try? modelContext.save()
    }
}

private extension MonitorsView.Selection {
    var isDraft: Bool {
        if case .draft = self { return true }
        return false
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
