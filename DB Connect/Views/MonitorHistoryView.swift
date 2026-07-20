import SwiftUI
import Charts

/// Compact history line for a monitor activation, used inside list rows.
struct MonitorSparkline: View {
    let samples: [MonitorSample]
    var height: CGFloat = 28

    var body: some View {
        if samples.count < 2 {
            // A single point is not a trend; showing a flat line would imply history that
            // does not exist yet.
            Color.clear.frame(height: height)
        } else {
            Chart(samples) { sample in
                AreaMark(
                    x: .value("Time", sample.at),
                    y: .value("Value", sample.value)
                )
                .foregroundStyle(.tint.opacity(0.15))

                LineMark(
                    x: .value("Time", sample.at),
                    y: .value("Value", sample.value)
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.tint)

                if sample.didFire {
                    PointMark(
                        x: .value("Time", sample.at),
                        y: .value("Value", sample.value)
                    )
                    .symbolSize(24)
                    .foregroundStyle(.orange)
                }
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(height: height)
        }
    }
}

/// Full history for one monitor, with each participating device shown separately.
///
/// Devices are kept apart rather than merged because each keeps its own baseline — averaging
/// them would invent a series that no device ever actually observed.
struct MonitorHistoryView: View {
    let monitor: Monitor

    @Environment(\.dismiss) private var dismiss
    private let device = DeviceIdentity.current

    var body: some View {
        NavigationStack {
            List {
                if activations.isEmpty {
                    ContentUnavailableView(
                        "No History Yet",
                        systemImage: "chart.xyaxis.line",
                        description: Text("History appears once this monitor has run at least twice on a device.")
                    )
                }

                ForEach(activations) { activation in
                    Section {
                        let samples = activation.recentSamples()

                        if samples.count < 2 {
                            Text(samples.isEmpty ? "Not run yet" : "One reading so far")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        } else {
                            chart(for: samples)
                                .frame(height: 160)
                                .padding(.vertical, 4)
                        }

                        statistics(for: activation, samples: samples)
                    } header: {
                        HStack {
                            Label(activation.deviceName, systemImage: activation.symbolName)
                            if activation.deviceID == device.id {
                                Text("(this device)").foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(activation.isEnabled ? "Running" : "Paused")
                                .foregroundStyle(activation.isEnabled ? .green : .secondary)
                        }
                        .font(.caption)
                        .textCase(nil)
                    }
                }
            }
            .navigationTitle(monitor.title.isEmpty ? "History" : monitor.title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 460)
        #endif
    }

    private var activations: [MonitorActivation] {
        // This device first — it is the one the user is most likely asking about.
        (monitor.activations ?? []).sorted { lhs, rhs in
            if lhs.deviceID == device.id { return true }
            if rhs.deviceID == device.id { return false }
            return lhs.deviceName < rhs.deviceName
        }
    }

    private func chart(for samples: [MonitorSample]) -> some View {
        Chart(samples) { sample in
            AreaMark(
                x: .value("Time", sample.at),
                y: .value("Value", sample.value)
            )
            .foregroundStyle(.tint.opacity(0.12))

            LineMark(
                x: .value("Time", sample.at),
                y: .value("Value", sample.value)
            )
            .interpolationMethod(.monotone)

            if sample.didFire {
                PointMark(
                    x: .value("Time", sample.at),
                    y: .value("Value", sample.value)
                )
                .foregroundStyle(.orange)
                .symbolSize(60)
                .annotation(position: .top, spacing: 2) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.orange)
                }
            }

            // The threshold only means something for the rules that compare against it.
            if monitor.rule.kind.usesThreshold,
               monitor.rule.kind == .above || monitor.rule.kind == .below {
                RuleMark(y: .value("Threshold", monitor.threshold))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    .foregroundStyle(.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading)
        }
    }

    @ViewBuilder
    private func statistics(for activation: MonitorActivation, samples: [MonitorSample]) -> some View {
        let values = samples.map(\.value)
        let fired = samples.filter(\.didFire).count

        LabeledContent("Current") {
            Text(activation.lastValue.map(MonitorRow.format) ?? "—").monospacedDigit()
        }
        if let minimum = values.min(), let maximum = values.max(), values.count > 1 {
            LabeledContent("Range") {
                Text("\(MonitorRow.format(minimum)) – \(MonitorRow.format(maximum))").monospacedDigit()
            }
        }
        LabeledContent("Readings") {
            Text("\(samples.count)").monospacedDigit()
        }
        LabeledContent("Notifications") {
            Text("\(fired)").monospacedDigit()
        }
        if let lastRun = activation.lastRunAt {
            LabeledContent("Last check") {
                Text(lastRun.formatted(.relative(presentation: .numeric)))
            }
        }
        if let error = activation.lastErrorMessage {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}
