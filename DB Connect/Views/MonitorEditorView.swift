import SwiftUI
import SwiftData

/// Create or edit a monitor, shown inline in the Monitors detail pane rather than in a sheet.
///
/// The query is edited here too: pick an existing saved query or write a new one (connection,
/// database and SQL) without a detour through the console. `onSaved`, `onDelete` and `onCancel`
/// let the parent move its selection when a monitor is created, removed, or a draft is abandoned.
struct MonitorEditorView: View {
    var monitor: Monitor?
    var onSaved: (Monitor) -> Void = { _ in }
    var onDelete: (Monitor) -> Void = { _ in }
    var onCancel: (() -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SavedQuery.title) private var savedQueries: [SavedQuery]
    @Query(sort: [SortDescriptor(\Connection.sortOrder), SortDescriptor(\Connection.createdAt)])
    private var connections: [Connection]

    @State private var title = ""
    @State private var ruleKind: MonitorRule.Kind = .changedByAtLeast
    @State private var threshold = 1.0
    @State private var intervalMinutes = 60
    @State private var schedulePreset: SchedulePreset = .hourly
    @State private var scheduleKind: MonitorScheduleKind = .interval
    @State private var customIntervalValue = 1
    @State private var customIntervalUnit: IntervalUnit = .hours
    @State private var scheduledTime = Self.dateForTime(hour: 9, minute: 0)
    @State private var comparisonColumn = ""
    @State private var cooldownMinutes = 0
    @State private var quietStart = 0
    @State private var quietEnd = 0
    @State private var showsNotificationLimits = false
    @State private var runsOnThisDevice = true
    @State private var messageTemplate = ""
    @State private var fieldDrafts: [NotificationTemplateEditor.FieldDraft] = []
    @State private var showsHistory = false

    // Inline query editing. `querySource` decides whether Save reuses an existing query or
    // creates a fresh one; the rest mirror the fields of the query being written.
    @State private var querySource: QuerySource = .new
    @State private var queryTitle = ""
    @State private var queryConnection: Connection?
    @State private var queryDatabase = ""
    @State private var querySQL = ""
    @State private var databaseOptions: [String] = []
    @State private var isLoadingDatabases = false

    private let device = DeviceIdentity.current

    /// Whether the monitor watches an existing saved query or a new one written here.
    enum QuerySource: Hashable {
        case new
        case existing(SavedQuery)
    }

    /// Common schedules stay one click away. Anything outside this set uses the custom controls.
    private enum SchedulePreset: String, CaseIterable, Identifiable {
        case hourly
        case sixHours
        case twelveHours
        case daily
        case weekly
        case custom

        var id: String { rawValue }

        var title: String {
            switch self {
            case .hourly: "Every hour"
            case .sixHours: "Every 6 hours"
            case .twelveHours: "Every 12 hours"
            case .daily: "Every day"
            case .weekly: "Every week"
            case .custom: "Custom…"
            }
        }

        var interval: Int? {
            switch self {
            case .hourly: 60
            case .sixHours: 360
            case .twelveHours: 720
            case .daily: 1_440
            case .weekly: 10_080
            case .custom: nil
            }
        }

        init(intervalMinutes: Int, scheduleKind: MonitorScheduleKind) {
            guard scheduleKind == .interval,
                  let match = Self.allCases.first(where: { $0.interval == intervalMinutes }) else {
                self = .custom
                return
            }
            self = match
        }
    }

    private enum IntervalUnit: String, CaseIterable, Identifiable {
        case minutes
        case hours

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var multiplier: Int { self == .minutes ? 1 : 60 }
    }

    var body: some View {
        Form {
                Section("Monitor") {
                    TextField("Title", text: $title)
                }

                querySection

                Section {
                    Picker("Notify me when", selection: $ruleKind) {
                        ForEach(MonitorRule.Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    if ruleKind.usesThreshold {
                        LabeledContent(thresholdLabel) {
                            HStack(spacing: 5) {
                                TextField(value: $threshold, format: .number) {
                                    Text(thresholdLabel)
                                }
                                .labelsHidden()
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                                if ruleKind == .changedByPercent {
                                    Text("%")
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if ruleKind.readsValue {
                        TextField("Result column (optional)", text: $comparisonColumn)
                    }
                } header: {
                    Text("Condition")
                } footer: {
                    Text(conditionFooter)
                }

                NotificationTemplateEditor(
                    template: $messageTemplate,
                    fields: $fieldDrafts,
                    savedQueries: savedQueries
                )

                Section {
                    Picker("Run query", selection: $schedulePreset) {
                        ForEach(SchedulePreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }

                    if schedulePreset == .custom {
                        Picker("Custom schedule", selection: $scheduleKind) {
                            Text("Repeat at an interval").tag(MonitorScheduleKind.interval)
                            Text("At a set time each day").tag(MonitorScheduleKind.dailyTime)
                        }

                        if scheduleKind == .interval {
                            LabeledContent("Repeat every") {
                                HStack(spacing: 8) {
                                    TextField("Amount", value: $customIntervalValue, format: .number)
                                        .labelsHidden()
                                        .multilineTextAlignment(.trailing)
                                        .frame(width: 64)
                                    Picker("Unit", selection: $customIntervalUnit) {
                                        ForEach(IntervalUnit.allCases) { unit in
                                            Text(unit.title).tag(unit)
                                        }
                                    }
                                    .labelsHidden()
                                    .fixedSize()
                                }
                            }
                        } else {
                            DatePicker(
                                "Run every day at",
                                selection: $scheduledTime,
                                displayedComponents: .hourAndMinute
                            )
                        }
                    }

                    DisclosureGroup(isExpanded: $showsNotificationLimits) {
                        Picker("Repeat alerts", selection: $cooldownMinutes) {
                            Text("Every time the condition is met").tag(0)
                            Text("At most once every 15 minutes").tag(15)
                            Text("At most once an hour").tag(60)
                            Text("At most once every 6 hours").tag(360)
                            Text("At most once a day").tag(1_440)
                            if ![0, 15, 60, 360, 1_440].contains(cooldownMinutes) {
                                Text("At most once every \(cooldownMinutes) minutes").tag(cooldownMinutes)
                            }
                        }

                        Picker("Quiet from", selection: $quietStart) {
                            ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) }
                        }
                        Picker("Quiet until", selection: $quietEnd) {
                            ForEach(0..<24, id: \.self) { Text("\($0):00").tag($0) }
                        }

                        Text(notificationLimitsFooter)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } label: {
                        Text("Notification limits (optional)")
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    Text(scheduleFooter)
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
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaBar(edge: .bottom) { actionBar }
        .sheet(isPresented: $showsHistory) {
            if let monitor { MonitorHistoryView(monitor: monitor) }
        }
        .onAppear(perform: populate)
        .onChange(of: querySource) { _, newValue in
            adopt(newValue)
        }
        .onChange(of: schedulePreset) { _, preset in
            apply(preset)
        }
        .onChange(of: customIntervalValue) { _, _ in
            updateCustomInterval()
        }
        .onChange(of: customIntervalUnit) { _, _ in
            updateCustomInterval()
        }
        .onChange(of: scheduleKind) { _, _ in
            updateCustomInterval()
        }
        // List databases whenever the target connection changes, so the picker can offer them.
        // A failure just leaves the free-text field, which still lets the name be typed by hand.
        .task(id: queryConnection?.id) { await loadDatabases() }
    }

    // MARK: Query section

    @ViewBuilder
    private var querySection: some View {
        Section {
            Picker("Query", selection: $querySource) {
                Text("New query…").tag(QuerySource.new)
                ForEach(savedQueries) { query in
                    Text(query.title.isEmpty ? "Untitled" : query.title).tag(QuerySource.existing(query))
                }
            }

            TextField("Query name", text: $queryTitle, prompt: Text(title.isEmpty ? "Same as monitor" : title))

            Picker("Connection", selection: $queryConnection) {
                Text("Choose…").tag(Optional<Connection>.none)
                ForEach(connections) { connection in
                    Text(connection.name.isEmpty ? "Untitled" : connection.name).tag(Optional(connection))
                }
            }

            databaseField
        } header: {
            Text("Query")
        } footer: {
            Text("The database is stored with the query so the monitor selects it before running — a server connection has no database of its own to fall back on.")
        }

        Section("SQL") {
            SQLEditorView(text: $querySQL, tables: [])
                .frame(minHeight: 120)
        }
    }

    /// Free-text database name with a menu of what the connection actually exposes. Free text is
    /// the reliable path (credentials may not have synced, or the account may not list databases);
    /// the menu is the convenience when they have.
    private var databaseField: some View {
        HStack(spacing: 6) {
            TextField("Database", text: $queryDatabase)
            if isLoadingDatabases {
                DatabaseLoadingIndicator(size: 13)
            } else {
                Menu {
                    if databaseOptions.isEmpty {
                        Text("No databases listed")
                    } else {
                        ForEach(databaseOptions, id: \.self) { name in
                            Button(name) { queryDatabase = name }
                        }
                    }
                    Divider()
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task { await loadDatabases() }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose from the databases on this connection")
            }
        }
    }

    // MARK: Chrome

    /// Names the pane so the detail area does not read as headerless, and mirrors the edited
    /// title live so a rename is visible before it is saved.
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: monitor == nil ? "bell.badge" : "bell.fill")
                .foregroundStyle(.tint)
            Text(monitor == nil
                 ? "New Monitor"
                 : (title.isEmpty ? "Untitled Monitor" : title))
                .font(.headline)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            if let monitor {
                Button("Delete", systemImage: "trash", role: .destructive) { onDelete(monitor) }
                Button("History", systemImage: "chart.xyaxis.line") { showsHistory = true }
                    .disabled((monitor.activations ?? []).isEmpty)
            }
            Spacer()
            if let onCancel {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
            Button(monitor == nil ? "Create Monitor" : "Save") { save() }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .buttonStyle(.glass)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var canSave: Bool {
        !title.isEmpty
            && queryConnection != nil
            && !querySQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var activationSymbol: String {
        switch device.kind {
        case "mac": "laptopcomputer"
        case "ipad": "ipad"
        default: "iphone"
        }
    }

    private var thresholdLabel: String {
        switch ruleKind {
        case .changedByAtLeast: "Minimum change"
        case .changedByPercent: "Minimum change"
        case .above: "Notify above"
        case .below: "Notify below"
        default: "Threshold"
        }
    }

    private var conditionFooter: String {
        switch ruleKind {
        case .returnsRows:
            "Notifies when the query returns one or more rows. No numeric value is needed."
        case .noData:
            "Notifies when the query returns no rows. No numeric value is needed."
        case .changed, .changedByAtLeast, .changedByPercent:
            "DB Connect compares the first value in the first row with the previous run. The first run establishes a baseline. Enter a result column only when the value is elsewhere."
        case .above, .below:
            "DB Connect checks the first value in the first row. Enter a result column only when the value is elsewhere."
        }
    }

    /// The honest bit: on iOS the interval is a request, not a guarantee.
    private var scheduleFooter: String {
        #if os(macOS)
        "\(scheduleSummary). Runs while DB Connect is open."
        #else
        "\(scheduleSummary). iOS decides when background checks run, so intervals and clock times are requests rather than guarantees. DB Connect also checks when you open the app."
        #endif
    }

    private var scheduleSummary: String {
        if scheduleKind == .dailyTime, schedulePreset == .custom {
            return "Runs every day at \(scheduledTime.formatted(date: .omitted, time: .shortened))"
        }
        let minutes = schedulePreset.interval ?? intervalMinutes
        switch minutes {
        case 60: return "Runs every hour"
        case 360: return "Runs every 6 hours"
        case 720: return "Runs every 12 hours"
        case 1_440: return "Runs every day"
        case 10_080: return "Runs every week"
        default:
            if minutes.isMultiple(of: 60) {
                return "Runs every \(minutes / 60) hours"
            }
            return "Runs every \(minutes) minutes"
        }
    }

    private var notificationLimitsFooter: String {
        quietStart == quietEnd
            ? "Quiet hours are off. Set different start and end times to silence notifications while monitors keep recording."
            : "Notifications are silenced during quiet hours. Checks and value history continue."
    }

    // MARK: State

    private func populate() {
        // Query fields first, so a new monitor lands on a connection ready to write against.
        if let query = monitor?.query {
            querySource = .existing(query)
            queryTitle = query.title
            queryConnection = query.connection
            queryDatabase = query.database
            querySQL = query.sql
        } else {
            querySource = .new
            queryConnection = connections.first
        }

        guard let monitor else { return }
        title = monitor.title
        ruleKind = MonitorRule.Kind(rawValue: monitor.ruleType) ?? .changed
        threshold = monitor.threshold
        intervalMinutes = monitor.intervalMinutes
        scheduleKind = monitor.scheduleKind
        schedulePreset = SchedulePreset(
            intervalMinutes: monitor.intervalMinutes,
            scheduleKind: monitor.scheduleKind
        )
        configureCustomInterval(from: monitor.intervalMinutes)
        scheduledTime = Self.dateForTime(
            hour: monitor.scheduledMinuteOfDay / 60,
            minute: monitor.scheduledMinuteOfDay % 60
        )
        comparisonColumn = monitor.comparisonColumn ?? ""
        cooldownMinutes = monitor.cooldownMinutes
        quietStart = monitor.quietHoursStart
        quietEnd = monitor.quietHoursEnd
        showsNotificationLimits = monitor.cooldownMinutes > 0
            || monitor.quietHoursStart != monitor.quietHoursEnd
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

    /// Load the selected query's fields into the editor, or clear them for a new one. The
    /// connection is kept when switching to a new query — it is almost always the same one.
    private func adopt(_ source: QuerySource) {
        switch source {
        case .existing(let query):
            queryTitle = query.title
            queryConnection = query.connection
            queryDatabase = query.database
            querySQL = query.sql
        case .new:
            queryTitle = ""
            queryDatabase = ""
            querySQL = ""
        }
    }

    private func loadDatabases() async {
        guard let connection = queryConnection,
              let driver = DriverRegistry.driver(for: connection.driverID) else {
            databaseOptions = []
            return
        }
        isLoadingDatabases = true
        defer { isLoadingDatabases = false }

        let secret = try? KeychainSecretStore().secret(for: connection.id)
        guard let session = try? await driver.connect(config: connection.config, secret: secret) else {
            databaseOptions = []
            return
        }
        databaseOptions = (try? await session.databases()) ?? []
        await session.close()
    }

    private func save() {
        // The query the monitor will watch — reused or freshly created — updated to match the
        // editor so a database fix here also repairs the query for the console and any sibling.
        let query: SavedQuery
        switch querySource {
        case .existing(let existing):
            query = existing
        case .new:
            query = SavedQuery(title: "", sql: "")
            modelContext.insert(query)
        }
        query.title = queryTitle.isEmpty ? title : queryTitle
        query.sql = querySQL
        query.database = queryDatabase
        query.connection = queryConnection

        let target = monitor ?? Monitor(title: title, query: query)
        target.title = title
        target.query = query
        target.ruleType = ruleKind.rawValue
        target.threshold = threshold
        target.intervalMinutes = intervalMinutes
        target.scheduleKind = schedulePreset == .custom ? scheduleKind : .interval
        let timeComponents = Calendar.current.dateComponents([.hour, .minute], from: scheduledTime)
        target.scheduledMinuteOfDay = (timeComponents.hour ?? 9) * 60 + (timeComponents.minute ?? 0)
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
        onSaved(target)
    }

    private func apply(_ preset: SchedulePreset) {
        guard let interval = preset.interval else { return }
        scheduleKind = .interval
        intervalMinutes = interval
        configureCustomInterval(from: interval)
    }

    private func configureCustomInterval(from minutes: Int) {
        if minutes.isMultiple(of: 60) {
            customIntervalUnit = .hours
            customIntervalValue = max(1, minutes / 60)
        } else {
            customIntervalUnit = .minutes
            customIntervalValue = max(1, minutes)
        }
    }

    private func updateCustomInterval() {
        guard schedulePreset == .custom, scheduleKind == .interval else { return }
        intervalMinutes = min(max(1, customIntervalValue) * customIntervalUnit.multiplier, 525_600)
    }

    private static func dateForTime(hour: Int, minute: Int) -> Date {
        Calendar.current.date(
            bySettingHour: min(max(hour, 0), 23),
            minute: min(max(minute, 0), 59),
            second: 0,
            of: .now
        ) ?? .now
    }
}
