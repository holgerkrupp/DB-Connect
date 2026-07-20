import SwiftUI
import SwiftData

/// Create or edit a monitor, including this device's participation.
struct MonitorEditorView: View {
    var monitor: Monitor?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \SavedQuery.title) private var savedQueries: [SavedQuery]

    @State private var title = ""
    @State private var selectedQuery: SavedQuery?
    @State private var ruleKind: MonitorRule.Kind = .changedByAtLeast
    @State private var threshold = 1.0
    @State private var intervalMinutes = 60
    @State private var comparisonColumn = ""
    @State private var cooldownMinutes = 0
    @State private var quietStart = 0
    @State private var quietEnd = 0
    @State private var runsOnThisDevice = true
    @State private var messageTemplate = ""
    @State private var fieldDrafts: [NotificationTemplateEditor.FieldDraft] = []

    private let device = DeviceIdentity.current

    var body: some View {
        NavigationStack {
            Form {
                Section("Monitor") {
                    TextField("Title", text: $title)
                    Picker("Query", selection: $selectedQuery) {
                        Text("Choose…").tag(Optional<SavedQuery>.none)
                        ForEach(savedQueries) { query in
                            Text(query.title).tag(Optional(query))
                        }
                    }
                }

                Section {
                    Picker("Notify when", selection: $ruleKind) {
                        ForEach(MonitorRule.Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    if ruleKind.usesThreshold {
                        HStack {
                            Text(ruleKind == .changedByPercent ? "Percent" : "Value")
                            Spacer()
                            TextField("Threshold", value: $threshold, format: .number)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                        }
                    }
                    TextField("Column (optional)", text: $comparisonColumn)
                } header: {
                    Text("Condition")
                } footer: {
                    Text("Leave the column blank to use the first value of the first row — what SELECT COUNT(*) returns.")
                }

                NotificationTemplateEditor(
                    template: $messageTemplate,
                    fields: $fieldDrafts,
                    savedQueries: savedQueries
                )

                Section {
                    Stepper("Every \(intervalMinutes) minutes", value: $intervalMinutes, in: 1...1440, step: 5)
                    Stepper(
                        cooldownMinutes == 0 ? "No repeat limit" : "At most once per \(cooldownMinutes) min",
                        value: $cooldownMinutes, in: 0...1440, step: 5
                    )
                } header: {
                    Text("Schedule")
                } footer: {
                    Text(scheduleFooter)
                }

                Section {
                    Picker("Quiet from", selection: $quietStart) {
                        ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) }
                    }
                    Picker("Quiet until", selection: $quietEnd) {
                        ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) }
                    }
                } header: {
                    Text("Quiet Hours")
                } footer: {
                    Text(quietStart == quietEnd
                         ? "Set different times to silence notifications overnight. Monitors keep running and recording."
                         : "Notifications are suppressed between these hours. The value is still recorded, so the next comparison stays accurate.")
                }

                Section {
                    Toggle(isOn: $runsOnThisDevice) {
                        Label("Run on \(device.name)", systemImage: activationSymbol)
                    }
                    if let monitor {
                        ForEach((monitor.activations ?? []).filter { $0.deviceID != device.id }) { other in
                            LabeledContent {
                                Text(other.isEnabled ? "On" : "Off")
                                    .foregroundStyle(other.isEnabled ? .green : .secondary)
                            } label: {
                                Label(other.deviceName, systemImage: other.symbolName)
                            }
                            .font(.callout)
                        }
                    }
                } header: {
                    Text("Devices")
                } footer: {
                    Text("Each device decides for itself whether to run this monitor, and keeps its own history. Enabling it on several devices means several notifications.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(monitor == nil ? "New Monitor" : "Edit Monitor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(selectedQuery == nil || title.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 520)
        #endif
        .onAppear(perform: populate)
    }

    private var activationSymbol: String {
        switch device.kind {
        case "mac": "laptopcomputer"
        case "ipad": "ipad"
        default: "iphone"
        }
    }

    /// The honest bit: on iOS the interval is a request, not a guarantee.
    private var scheduleFooter: String {
        #if os(macOS)
        "While DB Connect is running, this interval is kept accurately."
        #else
        "iOS decides when background checks actually run — often less than once an hour, and not at all if the app is rarely opened. The monitor is always checked when you open the app."
        #endif
    }

    private func populate() {
        guard let monitor else { return }
        title = monitor.title
        selectedQuery = monitor.query
        ruleKind = MonitorRule.Kind(rawValue: monitor.ruleType) ?? .changed
        threshold = monitor.threshold
        intervalMinutes = monitor.intervalMinutes
        comparisonColumn = monitor.comparisonColumn ?? ""
        cooldownMinutes = monitor.cooldownMinutes
        quietStart = monitor.quietHoursStart
        quietEnd = monitor.quietHoursEnd
        runsOnThisDevice = monitor.activation(for: device.id)?.isEnabled ?? false
        messageTemplate = monitor.messageTemplate
        fieldDrafts = (monitor.fields ?? [])
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { field in
                NotificationTemplateEditor.FieldDraft(
                    token: field.token,
                    query: field.query,
                    column: field.column ?? "",
                    format: field.format
                )
            }
    }

    private func save() {
        let target = monitor ?? Monitor(title: title, query: selectedQuery)
        target.title = title
        target.query = selectedQuery
        target.ruleType = ruleKind.rawValue
        target.threshold = threshold
        target.intervalMinutes = intervalMinutes
        target.comparisonColumn = comparisonColumn.isEmpty ? nil : comparisonColumn
        target.cooldownMinutes = cooldownMinutes
        target.quietHoursStart = quietStart
        target.quietHoursEnd = quietEnd
        target.messageTemplate = messageTemplate

        if monitor == nil {
            modelContext.insert(target)
        }

        // Replace the field set wholesale: it is small, and diffing drafts against models would
        // add order-tracking complexity for no user-visible benefit.
        for existing in target.fields ?? [] {
            modelContext.delete(existing)
        }
        for (index, draft) in fieldDrafts.enumerated() where !draft.token.isEmpty {
            let field = MonitorField(token: draft.token, query: draft.query)
            field.column = draft.column.isEmpty ? nil : draft.column
            field.formatRaw = draft.format.rawValue
            field.sortOrder = index
            field.monitor = target
            modelContext.insert(field)
        }

        // This device's activation row — created lazily, so a device that never opts in
        // does not clutter every monitor with an empty record.
        if let existing = target.activation(for: device.id) {
            existing.isEnabled = runsOnThisDevice
            // Re-enabling starts a fresh baseline; a stale one would produce a bogus first delta.
            if !runsOnThisDevice { existing.lastValue = nil }
        } else if runsOnThisDevice {
            let activation = MonitorActivation(device: device, isEnabled: true)
            activation.monitor = target
            modelContext.insert(activation)
        }

        try? modelContext.save()
        dismiss()
    }
}
