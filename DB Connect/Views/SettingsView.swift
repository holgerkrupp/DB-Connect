import SwiftUI

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

    var id: String { rawValue }

    var title: String {
        switch self {
        case .editor: "Editor"
        case .names: "Names"
        case .history: "History"
        }
    }

    var symbol: String {
        switch self {
        case .editor: "curlybraces"
        case .names: "text.magnifyingglass"
        case .history: "clock.arrow.circlepath"
        }
    }

    var tint: Color {
        switch self {
        case .editor: .indigo
        case .names: .teal
        case .history: .orange
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
