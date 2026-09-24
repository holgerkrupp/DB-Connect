#if os(macOS)
import AppKit
import SwiftData
import SwiftUI

/// A compact operational surface for people who leave DB Connect running as a monitor.
struct MonitorMenuBarView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.monitorScheduler) private var scheduler
    @Environment(\.openWindow) private var openWindow
    @Query(sort: \Monitor.createdAt) private var monitors: [Monitor]

    @State private var isRunning = false
    @State private var runMessage: String?

    private let device = DeviceIdentity.current

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if monitors.isEmpty {
                ContentUnavailableView {
                    Label("No Monitors", systemImage: "bell.slash")
                } description: {
                    Text("Create a monitor to see its status here.")
                }
                .frame(height: 170)
            } else {
                summary
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(monitors) { monitor in
                            monitorRow(monitor)
                            if monitor.id != monitors.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 310)
            }

            Divider()
            footer
        }
        .frame(width: 360)
    }

    private var header: some View {
        HStack {
            Label("DB Connect Monitors", systemImage: "bell.badge.fill")
                .font(.headline)
            Spacer()
            if isRunning {
                ProgressView().controlSize(.small)
            }
            Button("Check All Now", systemImage: "arrow.clockwise") {
                runAll()
            }
            .labelStyle(.iconOnly)
            .disabled(isRunning || enabledCount == 0)
            .help("Check all enabled monitors now")
        }
        .padding(12)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Label("\(enabledCount) active", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(enabledCount > 0 ? .green : .secondary)
                if errorCount > 0 {
                    Label("\(errorCount) need attention", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption.weight(.medium))

            if let runMessage {
                Text(runMessage)
                    .font(.caption)
                    .foregroundStyle(errorCount > 0 ? .orange : .secondary)
            } else if let lastCheck {
                Text("Last successful check \(lastCheck.formatted(.relative(presentation: .numeric)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("No successful checks yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func monitorRow(_ monitor: Monitor) -> some View {
        let activation = monitor.activation(for: device.id)
        return HStack(spacing: 10) {
            Button {
                open(monitor)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: statusSymbol(for: activation))
                        .foregroundStyle(statusColor(for: activation))
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(monitor.title.isEmpty ? "Untitled Monitor" : monitor.title)
                                .font(.callout.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            if let value = activation?.lastValue {
                                Text(MonitorRow.format(value))
                                    .font(.callout.monospacedDigit().weight(.semibold))
                            }
                        }
                        Text(rowDetail(monitor, activation: activation))
                            .font(.caption)
                            .foregroundStyle(activation?.lastErrorMessage == nil ? Color.secondary : Color.orange)
                            .lineLimit(1)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Toggle("Run", isOn: enabledBinding(for: monitor))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var footer: some View {
        HStack {
            Button("Open Monitors", systemImage: "macwindow") {
                AppNavigation.shared.open(.monitors)
                openWindow(id: DB_ConnectApp.mainWindowID)
                NSApp.activate()
            }
            Spacer()
            Button("Quit DB Connect") { NSApp.terminate(nil) }
        }
        .padding(10)
    }

    private var enabledCount: Int {
        monitors.filter { $0.activation(for: device.id)?.isEnabled == true }.count
    }

    private var errorCount: Int {
        monitors.filter { $0.activation(for: device.id)?.lastErrorMessage != nil }.count
    }

    private var lastCheck: Date? {
        monitors.compactMap { $0.activation(for: device.id)?.lastRunAt }.max()
    }

    private func enabledBinding(for monitor: Monitor) -> Binding<Bool> {
        Binding {
            monitor.activation(for: device.id)?.isEnabled == true
        } set: { enabled in
            monitor.setEnabled(enabled, on: device, in: modelContext)
            try? modelContext.save()
            WidgetSnapshotPublisher.publish(container: DB_ConnectApp.appModelContainer)
            if enabled {
                Task { await scheduler?.runDue() }
            }
        }
    }

    private func rowDetail(_ monitor: Monitor, activation: MonitorActivation?) -> String {
        if let error = activation?.lastErrorMessage { return error }
        guard activation?.isEnabled == true else { return "Off on this Mac" }
        if let date = activation?.lastRunAt {
            return "Checked \(date.formatted(.relative(presentation: .numeric))) · \(monitor.scheduleDescription)"
        }
        return "Waiting for first check · \(monitor.scheduleDescription)"
    }

    private func statusSymbol(for activation: MonitorActivation?) -> String {
        if activation?.lastErrorMessage != nil { return "exclamationmark.triangle.fill" }
        return activation?.isEnabled == true ? "checkmark.circle.fill" : "pause.circle.fill"
    }

    private func statusColor(for activation: MonitorActivation?) -> Color {
        if activation?.lastErrorMessage != nil { return .orange }
        return activation?.isEnabled == true ? .green : .secondary
    }

    private func open(_ monitor: Monitor) {
        AppNavigation.shared.open(.monitor(monitor.id))
        openWindow(id: DB_ConnectApp.mainWindowID)
        NSApp.activate()
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
}
#endif
