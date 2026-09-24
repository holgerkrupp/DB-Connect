import SwiftUI
#if os(macOS)
import ServiceManagement
#endif

/// App preferences. Presented as a Settings window on macOS and a sheet on iOS.
///
/// macOS gets the System Settings layout — a sidebar of panes next to a grouped form — because
/// the window is shared with the rest of the system and users navigate it by muscle memory.
/// iOS has no Settings scene, so the same sections are stacked into one scrolling form.
struct SettingsView: View {
    #if os(macOS)
    @State private var pane: SettingsPane = .editor

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                NavigationLink(value: pane) {
                    Label {
                        Text(pane.title)
                    } icon: {
                        SettingsPaneIcon(pane: pane)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200, max: 240)
        } detail: {
            Form {
                switch pane {
                case .editor: EditorSettings()
                case .names: NameSettings()
                case .history: HistorySettings()
                case .connection: ConnectionSettings()
                case .monitoring: MonitoringSettings()
                }
            }
            .formStyle(.grouped)
            .navigationTitle(pane.title)
        }
        .frame(width: 720, height: 440)
    }
    #else
    var body: some View {
        Form {
            EditorSettings()
            NameSettings()
            HistorySettings()
            ConnectionSettings()
            MonitoringSettings()
        }
        .formStyle(.grouped)
    }
    #endif
}

#if os(macOS)
/// The panes in the sidebar, in the order they appear.
enum SettingsPane: String, CaseIterable, Identifiable {
    case editor
    case names
    case history
    case connection
    case monitoring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: "Editor"
        case .names: "Names"
        case .history: "History"
        case .connection: "Connection"
        case .monitoring: "Monitoring"
        }
    }

    var symbol: String {
        switch self {
        case .editor: "curlybraces"
        case .names: "text.magnifyingglass"
        case .history: "clock.arrow.circlepath"
        case .connection: "bolt.horizontal.circle"
        case .monitoring: "bell.badge"
        }
    }

    var tint: Color {
        switch self {
        case .editor: .indigo
        case .names: .teal
        case .history: .orange
        case .connection: .green
        case .monitoring: .purple
        }
    }
}

/// The tinted rounded square System Settings uses for sidebar rows.
private struct SettingsPaneIcon: View {
    let pane: SettingsPane

    var body: some View {
        Image(systemName: pane.symbol)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(pane.tint.gradient, in: .rect(cornerRadius: 5))
    }
}
#endif

// MARK: - Sections

private struct EditorSettings: View {
    @AppStorage(AppSettings.Key.syntaxHighlighting) private var syntaxHighlighting = true
    @AppStorage(AppSettings.Key.autocompleteEnabled) private var autocompleteEnabled = true

    var body: some View {
        Section("Editor") {
            Toggle("Highlight SQL syntax", isOn: $syntaxHighlighting)
            Toggle("Suggest table and column names", isOn: $autocompleteEnabled)
        }
    }
}

private struct NameSettings: View {
    @AppStorage(AppSettings.Key.highlightIdentifierIssues) private var highlightIssues = true
    @AppStorage(AppSettings.Key.identifierCorrection) private var correctionRaw = AppSettings.CorrectionMode.caseOnly.rawValue

    private var correction: AppSettings.CorrectionMode {
        AppSettings.CorrectionMode(rawValue: correctionRaw) ?? .caseOnly
    }

    var body: some View {
        Section {
            Toggle("Underline names that don't match the schema", isOn: $highlightIssues)

            Picker("Correct names automatically", selection: $correctionRaw) {
                ForEach(AppSettings.CorrectionMode.allCases) { mode in
                    Text(mode.title).tag(mode.rawValue)
                }
            }
            Text(correction.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Table and Column Names")
        } footer: {
            Text("Names are checked against the schema of the open connection. Quoted names and aliases you define in the query are never changed.")
        }
    }
}

private struct HistorySettings: View {
    @AppStorage(AppSettings.Key.recordHistory) private var recordHistory = true

    var body: some View {
        Section {
            Toggle("Record query history", isOn: $recordHistory)
        } header: {
            Text("History")
        } footer: {
            Text("History keeps the last \(QueryHistoryEntry.limitPerConnection) statements per connection, along with how long each took. Result rows are never stored.")
        }
    }
}

private struct ConnectionSettings: View {
    @AppStorage(AppSettings.Key.keepConnectionsAlive) private var keepConnectionsAlive = true

    var body: some View {
        Section {
            Toggle("Keep connections alive", isOn: $keepConnectionsAlive)
            Text("Periodically checks open connections and reconnects automatically when saved credentials are available. Actions that need a connection can still recover a stale session.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Connection")
        }
    }
}

private struct MonitoringSettings: View {
    #if os(macOS)
    @AppStorage(AppSettings.Key.showMonitorMenuBar) private var showMenuBar = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchError: String?
    #endif

    var body: some View {
        Section {
            #if os(macOS)
            Toggle("Show monitor status in the menu bar", isOn: $showMenuBar)
            Toggle("Open DB Connect at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    updateLaunchAtLogin(enabled)
                }
            if let launchError {
                Label(launchError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            #else
            LabeledContent("Home Screen widgets", value: "Available")
            LabeledContent("Shortcuts and Siri", value: "Available")
            #endif
        } header: {
            Text("Monitoring")
        } footer: {
            #if os(macOS)
            Text("Scheduled checks run while DB Connect is open. Opening it at login keeps monitoring available after you sign in; quitting the app stops checks.")
            #else
            Text("Add a DB Connect widget for at-a-glance status, or use Shortcuts to run monitors on demand. Background timing is controlled by iOS.")
            #endif
        }
    }

    #if os(macOS)
    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            launchError = error.localizedDescription
        }
    }
    #endif
}

#if os(iOS)
/// iOS has no Settings scene, so the same form is presented as a dismissible sheet.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var showsDocumentation = false
    @State private var showsOnboarding = false

    var body: some View {
        NavigationStack {
            SettingsView()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .secondaryAction) {
                        Menu("Help", systemImage: "questionmark.circle") {
                            Button("Getting Started", systemImage: "sparkles") {
                                showsOnboarding = true
                            }
                            Button("DB Connect Documentation", systemImage: "book.pages") {
                                showsDocumentation = true
                            }
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .sheet(isPresented: $showsOnboarding) {
            DBConnectOnboardingView()
        }
        .sheet(isPresented: $showsDocumentation) {
            NavigationStack {
                DBConnectDocumentationView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsDocumentation = false }
                        }
                    }
            }
        }
    }
}
#endif
