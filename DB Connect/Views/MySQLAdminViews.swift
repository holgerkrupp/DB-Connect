import SwiftUI

struct MySQLTableInspectorView: View {
    let session: any DatabaseSession
    let target: GrantTableTarget

    @Environment(\.dismiss) private var dismiss

    @State private var metadata: MySQLTableMetadata?
    @State private var relations: [MySQLForeignKeyRelation] = []
    @State private var triggers: [MySQLTriggerInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    DatabaseLoadingView("Loading MySQL metadata…")
                } else if let errorMessage {
                    ContentUnavailableView("Cannot Load Table Details", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else {
                    List {
                        if let metadata {
                            ForEach(metadata.sections) { section in
                                Section(section.title) {
                                    ForEach(section.fields) { field in
                                        LabeledContent(field.label, value: field.value)
                                    }
                                }
                            }
                        }

                        Section("Relations") {
                            if relations.isEmpty {
                                Text("No foreign-key relations.").foregroundStyle(.secondary)
                            } else {
                                ForEach(relations) { relation in
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(relation.constraintName)
                                            .font(.headline)
                                        Text(relationSummary(relation))
                                            .font(.callout)
                                        Text("ON UPDATE \(relation.updateRule) · ON DELETE \(relation.deleteRule)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }

                        Section("Triggers") {
                            if triggers.isEmpty {
                                Text("No triggers on this table.").foregroundStyle(.secondary)
                            } else {
                                ForEach(triggers) { trigger in
                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(trigger.name).font(.headline)
                                            Spacer(minLength: 8)
                                            Text("\(trigger.timing) \(trigger.event)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text("Definer: \(trigger.definer)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if let created = trigger.created {
                                            Text("Created: \(created)")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(trigger.body)
                                            .font(.caption.monospaced())
                                            .textSelection(.enabled)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(target.table)
            .navigationSubtitle(target.database)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button("Reload", systemImage: "arrow.clockwise") {
                        Task { await load() }
                    }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 500)
        #endif
        .task { await load() }
    }

    private func relationSummary(_ relation: MySQLForeignKeyRelation) -> String {
        switch relation.direction {
        case .outgoing:
            return "\(relation.table.qualifiedName).\(relation.column) → \(relation.referenced.qualifiedName).\(relation.referencedColumn)"
        case .incoming:
            return "\(relation.table.qualifiedName).\(relation.column) references this table’s \(relation.referencedColumn)"
        }
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            async let metadata = session.mysqlTableMetadata(for: target)
            async let relations = session.mysqlForeignKeyRelations(for: target)
            async let triggers = session.mysqlTriggers(for: target)
            self.metadata = try await metadata
            self.relations = try await relations
            self.triggers = try await triggers
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}

struct MySQLServerAdminView: View {
    let session: any DatabaseSession
    let capability: MySQLAdminCapability

    @Environment(\.dismiss) private var dismiss

    enum Tab: String, CaseIterable, Identifiable {
        case variables = "Variables"
        case processes = "Processes"

        var id: String { rawValue }
    }

    @State private var tab: Tab = .variables
    @State private var variables: [MySQLServerVariable] = []
    @State private var processes: [MySQLProcessInfo] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var showsFlushConfirm = false
    @State private var statusMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    DatabaseLoadingView(tab == .variables ? "Loading variables…" : "Loading processes…")
                } else if let errorMessage {
                    ContentUnavailableView("Cannot Load MySQL Administration", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                } else {
                    List {
                        if let statusMessage {
                            Section {
                                Label(statusMessage, systemImage: "checkmark.circle.fill")
                                    .foregroundStyle(.green)
                            }
                        }

                        switch tab {
                        case .variables:
                            Section(variablesSectionTitle) {
                                if filteredVariables.isEmpty {
                                    Text("No variables match the current filter.").foregroundStyle(.secondary)
                                } else {
                                    ForEach(filteredVariables) { variable in
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text(variable.name)
                                                    .font(.headline)
                                                Spacer(minLength: 8)
                                                Text(variable.isGlobal ? "Global" : "Session")
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Text(variable.value)
                                                .font(.caption.monospaced())
                                                .textSelection(.enabled)
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                            }
                        case .processes:
                            Section(processSectionTitle) {
                                if filteredProcesses.isEmpty {
                                    Text("No sessions match the current filter.").foregroundStyle(.secondary)
                                } else {
                                    ForEach(filteredProcesses) { process in
                                        VStack(alignment: .leading, spacing: 4) {
                                            HStack {
                                                Text("#\(process.id)")
                                                    .font(.headline)
                                                Text(process.user)
                                                    .font(.headline)
                                                Spacer(minLength: 8)
                                                Text(process.command)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Text("\(process.host) · \(process.database ?? "no database") · \(process.seconds)s")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            if let state = process.state, !state.isEmpty {
                                                Text(state)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            if let info = process.info, !info.isEmpty {
                                                Text(info)
                                                    .font(.caption.monospaced())
                                                    .lineLimit(4)
                                                    .textSelection(.enabled)
                                            }
                                        }
                                        .padding(.vertical, 2)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("MySQL Admin")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $tab) {
                        ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(minWidth: 220)
                }
                ToolbarItemGroup(placement: .secondaryAction) {
                    Button("Reload", systemImage: "arrow.clockwise") {
                        Task { await load() }
                    }
                    if capability.canFlushPrivileges {
                        Button("Flush Privileges…", systemImage: "lock.rotation") {
                            showsFlushConfirm = true
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: tab == .variables ? "Filter variables" : "Filter processes")
        .confirmationDialog("Flush privileges now?", isPresented: $showsFlushConfirm, titleVisibility: .visible) {
            Button("Flush Privileges", role: .destructive) {
                Task { await flushPrivileges() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This tells MySQL or MariaDB to reload grant tables immediately. Use it when account or privilege changes made outside DB Connect need to take effect now.")
        }
        #if os(macOS)
        .frame(minWidth: 720, minHeight: 520)
        #endif
        .task(id: tab) { await load() }
    }

    private var filteredVariables: [MySQLServerVariable] {
        if searchText.isEmpty { return variables }
        return variables.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.value.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var filteredProcesses: [MySQLProcessInfo] {
        if searchText.isEmpty { return processes }
        return processes.filter {
            "\($0.id)".contains(searchText)
                || $0.user.localizedCaseInsensitiveContains(searchText)
                || $0.host.localizedCaseInsensitiveContains(searchText)
                || ($0.database?.localizedCaseInsensitiveContains(searchText) == true)
                || $0.command.localizedCaseInsensitiveContains(searchText)
                || ($0.state?.localizedCaseInsensitiveContains(searchText) == true)
                || ($0.info?.localizedCaseInsensitiveContains(searchText) == true)
        }
    }

    private var variablesSectionTitle: String {
        let count = filteredVariables.count
        return "Server Variables (\(count))"
    }

    private var processSectionTitle: String {
        let count = filteredProcesses.count
        let visibility = capability.processVisibility == .allSessions ? "all sessions" : "visible sessions"
        return "Processes (\(count), \(visibility))"
    }

    private func load() async {
        isLoading = true
        errorMessage = nil
        statusMessage = nil
        do {
            switch tab {
            case .variables:
                variables = try await session.mysqlServerVariables()
            case .processes:
                processes = try await session.mysqlProcesses()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func flushPrivileges() async {
        do {
            try await session.mysqlFlushPrivileges()
            statusMessage = "Privileges reloaded."
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
