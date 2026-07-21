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
    @State private var comparisonColumn = ""
    @State private var cooldownMinutes = 0
    @State private var quietStart = 0
    @State private var quietEnd = 0
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

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Monitor") {
                    TextField("Title", text: $title)
                }

                querySection

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

            actionBar
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .sheet(isPresented: $showsHistory) {
            if let monitor { MonitorHistoryView(monitor: monitor) }
        }
        .onAppear(perform: populate)
        .onChange(of: querySource) { _, newValue in
            adopt(newValue)
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
                ProgressView().controlSize(.small)
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
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
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
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
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

    /// The honest bit: on iOS the interval is a request, not a guarantee.
    private var scheduleFooter: String {
        #if os(macOS)
        "While DB Connect is running, this interval is kept accurately."
        #else
        "iOS decides when background checks actually run — often less than once an hour, and not at all if the app is rarely opened. The monitor is always checked when you open the app."
        #endif
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
        defer { Task { await session.close() } }
        databaseOptions = (try? await session.databases()) ?? []
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
}
