import AppIntents
import SwiftUI
import SwiftData
import TipKit

/// Master–detail view of monitors: the list is the sidebar and the selected monitor's editor
/// fills the detail pane. Creating, editing and deleting all happen here rather than in sheets.
struct MonitorsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.monitorScheduler) private var scheduler
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.appNavigation) private var navigation
    @Query(sort: \Monitor.createdAt) private var monitors: [Monitor]
    @Query private var savedQueries: [SavedQuery]

    @State private var selection: Selection?
    @State private var notificationsDenied = false
    @State private var isRunning = false
    @State private var runMessage: String?
    /// Set to route a delete request through one confirmation, wherever it came from (the list's
    /// swipe/context menu or the editor's Delete button).
    @State private var monitorToDelete: Monitor?
    #if os(macOS)
    @AppStorage(AppSettings.Key.showMonitorMenuBar) private var showsMonitorMenuBar = false
    #endif

    private let device = DeviceIdentity.current
    private let glanceTip = MonitorGlanceTip()

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
                isPresented: $monitorToDelete.isPresent(),
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
                await refreshNotificationAuthorization(requestIfNeeded: true)
                applyNavigationRequest()
            }
            .onChange(of: navigation.request?.id) { _, _ in applyNavigationRequest() }
            // The glance tip is only worth showing once something is actually being checked.
            .task(id: enabledMonitorCount) {
                MonitorGlanceTip.hasEnabledMonitor = enabledMonitorCount > 0
            }
            #if os(macOS)
            .task(id: showsMonitorMenuBar) {
                if showsMonitorMenuBar {
                    glanceTip.invalidate(reason: .actionPerformed)
                }
            }
            #endif
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                // System Settings changes notification authorization while this view remains
                // alive. Refresh when the app becomes active so the banner does not stay stale.
                Task { await refreshNotificationAuthorization() }
            }
    }

    private func applyNavigationRequest() {
        guard let request = navigation.request,
              case .monitor(let monitorID) = request.destination,
              let monitor = monitors.first(where: { $0.id == monitorID }) else { return }
        selection = .existing(monitor)
        navigation.consume(request.id)
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) { runNowButton }
        }
        #else
        NavigationStack {
            sidebar
                .navigationTitle("Monitors")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) { runNowButton }
                }
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

            if !monitors.isEmpty {
                overviewBar
                glanceTipView
                Divider()
            }

            List(selection: $selection) {
                ForEach(monitors) { monitor in
                    MonitorRow(monitor: monitor, deviceID: device.id)
                        // On-screen awareness: Siri can act on the monitor a person is looking at.
                        .appEntityIdentifier(EntityIdentifier(for: MonitorEntity.self, identifier: monitor.id))
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
        .safeAreaBar(edge: .bottom) { addBar }
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
        .buttonStyle(.glass)
        .help("Create a monitor and build a query, or reuse one you already saved")
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

    @ViewBuilder
    private var glanceTipView: some View {
        #if os(macOS)
        TipView(glanceTip) { action in
            if action.id == MonitorGlanceTip.showInMenuBarActionID {
                showsMonitorMenuBar = true
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 9)
        #else
        TipView(glanceTip)
            .padding(.horizontal, 12)
            .padding(.bottom, 9)
        #endif
    }

    private var enabledMonitorCount: Int {
        monitors.filter { $0.activation(for: device.id)?.isEnabled == true }.count
    }

    private func refreshNotificationAuthorization(requestIfNeeded: Bool = false) async {
        if requestIfNeeded {
            await NotificationService.requestAuthorization()
        }
        notificationsDenied = await !NotificationService.isAuthorized()
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Monitors", systemImage: "bell.badge")
        } description: {
            Text(savedQueries.isEmpty
                 ? "Build a query here and have DB Connect check it automatically."
                 : "Watch a saved query and get notified when its result changes.")
        } actions: {
            Button("New Monitor", systemImage: "plus") { selection = .draft }
        }
    }

    private var overviewBar: some View {
        let activations = monitors.compactMap { $0.activation(for: device.id) }
        let enabled = activations.filter(\.isEnabled).count
        let errors = activations.filter { $0.lastErrorMessage != nil }.count

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 12) {
                Label("\(enabled) active", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(enabled > 0 ? .green : .secondary)
                if errors > 0 {
                    Label("\(errors) need attention", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            if let runMessage {
                Text(runMessage)
                    .foregroundStyle(errors > 0 ? .orange : .secondary)
                    .lineLimit(2)
            } else {
                Text(enabled == 0
                     ? "Turn on a monitor to start checking it on this device."
                     : "Checks run while DB Connect is available on this device.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            .appEntityIdentifier(EntityIdentifier(for: MonitorEntity.self, identifier: monitor.id))
        }
    }

    private var runNowButton: some View {
        Button {
            runAll()
        } label: {
            if isRunning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Checking monitors")
            } else {
                Label("Check Now", systemImage: "play.fill")
            }
        }
        .disabled(monitors.isEmpty || isRunning)
        .help("Check every enabled monitor on this device now")
    }

    private func runAll() {
        isRunning = true
        runMessage = nil
        Task {
            let summary = await scheduler?.runDue(force: true)
            runMessage = summary?.message
            isRunning = false
        }
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
        return "\(subject) · \(monitor.scheduleDescription) · \(condition.lowercased())"
    }

    static func format(_ value: Double) -> String {
        value == value.rounded() ? String(Int64(value)) : String(format: "%.2f", value)
    }
}
