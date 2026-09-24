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
    @Environment(\.monitorScheduler) private var scheduler
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
    @State private var isChecking = false
    @State private var checkMessage: String?
    @State private var autoSaveTask: Task<Void, Never>?
    @State private var lastSavedSnapshot = AutoSaveSnapshot.empty

    // Inline query editing. `querySource` decides whether the monitor reuses an existing query or
    // creates a fresh one; the rest mirror the fields of the query being written.
    @State private var querySource: QuerySource = .new
    @State private var queryTitle = ""
    @State private var queryConnection: Connection?
    @State private var queryDatabase = ""
    @State private var querySQL = ""
    @State private var queryDraft = ConsoleDraft()
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

    /// A compact copy of the editor state used to debounce auto-save without diffing models.
    private struct AutoSaveSnapshot: Equatable {
        struct FieldSnapshot: Equatable {
            let id: UUID
            let token: String
            let queryID: UUID?
            let column: String
            let formatRaw: String
        }

        let title: String
        let ruleType: String
        let threshold: Double
        let intervalMinutes: Int
        let schedulePreset: String
        let scheduleKind: String
        let scheduledMinuteOfDay: Int
        let comparisonColumn: String
        let cooldownMinutes: Int
        let quietStart: Int
        let quietEnd: Int
        let runsOnThisDevice: Bool
        let messageTemplate: String
        let queryUsesExisting: Bool
        let selectedQueryID: UUID?
        let queryTitle: String
        let queryConnectionID: UUID?
        let queryDatabase: String
        let querySQL: String
        let fieldDrafts: [FieldSnapshot]

        static let empty = AutoSaveSnapshot(
            title: "",
            ruleType: MonitorRule.Kind.changedByAtLeast.rawValue,
            threshold: 1,
            intervalMinutes: 60,
            schedulePreset: SchedulePreset.hourly.rawValue,
            scheduleKind: MonitorScheduleKind.interval.rawValue,
            scheduledMinuteOfDay: 9 * 60,
            comparisonColumn: "",
            cooldownMinutes: 0,
            quietStart: 0,
            quietEnd: 0,
            runsOnThisDevice: true,
            messageTemplate: "",
            queryUsesExisting: false,
            selectedQueryID: nil,
            queryTitle: "",
            queryConnectionID: nil,
            queryDatabase: "",
            querySQL: "",
            fieldDrafts: []
        )
    }

    var body: some View {
        Form {
                Section("Monitor") {
                    TextField("Title", text: $title)
                    if monitor == nil, !canSave {
                        Label(validationMessage, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if monitor != nil { statusSection }

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
        .toolbar { toolbarContent }
        .sheet(isPresented: $showsHistory) {
            if let monitor { MonitorHistoryView(monitor: monitor) }
        }
        .onAppear(perform: populate)
        .onDisappear { autoSaveTask?.cancel() }
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
        .onAppear {
            if queryDraft.sql != querySQL {
                queryDraft.sql = querySQL
            }
        }
        .onChange(of: querySQL) { _, newValue in
            if queryDraft.sql != newValue {
                queryDraft.sql = newValue
            }
        }
        .onChange(of: queryDraft.sql) { _, newValue in
            if querySQL != newValue {
                querySQL = newValue
            }
        }
        .onChange(of: autoSaveSnapshot) { _, snapshot in
            scheduleAutoSave(for: snapshot)
        }
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
            SQLEditorView(
                draft: queryDraft,
                tables: [],
                favorites: [],
                favoriteContext: QueryFavoriteContext(
                    connectionName: queryConnection?.name ?? "",
                    databaseName: queryDatabase,
                    tableName: nil
                )
            )
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if monitor == nil, let onCancel {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        if let monitor {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    checkNow(monitor)
                } label: {
                    if isChecking {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Check Now", systemImage: "play.fill")
                    }
                }
                .disabled(isChecking || !runsOnThisDevice)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("History", systemImage: "chart.xyaxis.line") { showsHistory = true }
                    .disabled((monitor.activations ?? []).isEmpty)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Delete", systemImage: "trash", role: .destructive) { onDelete(monitor) }
            }
        }
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && queryConnection != nil
            && !querySQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var validationMessage: String {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Give this monitor a name to continue."
        }
        if queryConnection == nil {
            return "Choose the database connection this query should use."
        }
        return "Enter the SQL query DB Connect should check."
    }

    @ViewBuilder
    private var statusSection: some View {
        if let activation = monitor?.activation(for: device.id) {
            Section("Status on \(device.name)") {
                LabeledContent("Monitoring") {
                    Label(
                        activation.isEnabled ? "On" : "Off",
                        systemImage: activation.isEnabled ? "checkmark.circle.fill" : "pause.circle.fill"
                    )
                    .foregroundStyle(activation.isEnabled ? .green : .secondary)
                }
                if let value = activation.lastValue {
                    LabeledContent("Latest value", value: MonitorRow.format(value))
                        .monospacedDigit()
                }
                if let date = activation.lastRunAt {
                    LabeledContent("Last successful check") {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let error = activation.lastErrorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let checkMessage {
                    Text(checkMessage)
                        .font(.caption)
                        .foregroundStyle(activation.lastErrorMessage == nil ? Color.secondary : Color.orange)
                }
            }
        } else {
            Section("Status on \(device.name)") {
                Label("This monitor is off on this device.", systemImage: "pause.circle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var autoSaveSnapshot: AutoSaveSnapshot {
        AutoSaveSnapshot(
            title: title,
            ruleType: ruleKind.rawValue,
            threshold: threshold,
            intervalMinutes: intervalMinutes,
            schedulePreset: schedulePreset.rawValue,
            scheduleKind: scheduleKind.rawValue,
            scheduledMinuteOfDay: scheduledMinuteOfDay,
            comparisonColumn: comparisonColumn,
            cooldownMinutes: cooldownMinutes,
            quietStart: quietStart,
            quietEnd: quietEnd,
            runsOnThisDevice: runsOnThisDevice,
            messageTemplate: messageTemplate,
            queryUsesExisting: selectedQueryID != nil,
            selectedQueryID: selectedQueryID,
            queryTitle: queryTitle,
            queryConnectionID: queryConnection?.id,
            queryDatabase: queryDatabase,
            querySQL: querySQL,
            fieldDrafts: fieldDrafts.map {
                AutoSaveSnapshot.FieldSnapshot(
                    id: $0.id,
                    token: $0.token,
                    queryID: $0.query?.id,
                    column: $0.column,
                    formatRaw: $0.format.rawValue
                )
            }
        )
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

        if let monitor {
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
        lastSavedSnapshot = autoSaveSnapshot
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

        let config = connection.config
        let storedSecret = try? KeychainSecretStore().secret(for: connection.id)
        let secret = try? ConnectionRuntimeSecretResolver.resolve(config: config, secret: storedSecret)
        guard let session = try? await driver.connect(config: config, secret: secret) else {
            databaseOptions = []
            return
        }
        databaseOptions = (try? await session.databases()) ?? []
        await session.close()
    }

    private func save(notifySelection: Bool) {
        // The query the monitor will watch — reused or freshly created — updated to match the
        // editor so a database fix here also repairs the query for the console and any sibling.
        let query: SavedQuery
        let createdNewQuery: Bool
        switch querySource {
        case .existing(let existing):
            query = existing
            createdNewQuery = false
        case .new:
            query = SavedQuery(title: "", sql: "")
            modelContext.insert(query)
            createdNewQuery = true
        }
        query.title = queryTitle.isEmpty ? title : queryTitle
        query.sql = querySQL
        query.database = queryDatabase
        query.connection = queryConnection
        if createdNewQuery {
            querySource = .existing(query)
        }

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

        target.setEnabled(runsOnThisDevice, on: device, in: modelContext)

        try? modelContext.save()
        lastSavedSnapshot = autoSaveSnapshot
        if notifySelection {
            onSaved(target)
        }
    }

    private func scheduleAutoSave(for snapshot: AutoSaveSnapshot) {
        autoSaveTask?.cancel()
        guard snapshot != lastSavedSnapshot else { return }

        autoSaveTask = Task {
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                let current = autoSaveSnapshot
                guard current == snapshot, current != lastSavedSnapshot, canSave else { return }
                save(notifySelection: monitor == nil)
            }
        }
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

    private func checkNow(_ monitor: Monitor) {
        // Commit the SQL and condition currently on screen so Check Now always tests what the
        // user sees, not the last debounced auto-save from a fraction of a second ago.
        if canSave, autoSaveSnapshot != lastSavedSnapshot {
            autoSaveTask?.cancel()
            save(notifySelection: false)
        }
        isChecking = true
        checkMessage = nil
        Task {
            let summary = await scheduler?.run(monitorID: monitor.id)
            checkMessage = summary?.message
            isChecking = false
        }
    }

    private static func dateForTime(hour: Int, minute: Int) -> Date {
        Calendar.current.date(
            bySettingHour: min(max(hour, 0), 23),
            minute: min(max(minute, 0), 59),
            second: 0,
            of: .now
        ) ?? .now
    }

    private var selectedQueryID: UUID? {
        guard case .existing(let query) = querySource else { return nil }
        return query.id
    }

    private var scheduledMinuteOfDay: Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: scheduledTime)
        return (components.hour ?? 9) * 60 + (components.minute ?? 0)
    }
}
