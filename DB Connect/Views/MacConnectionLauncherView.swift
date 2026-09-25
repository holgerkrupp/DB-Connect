#if os(macOS)
import SwiftUI
import SwiftData
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

/// The connection-first Mac entry point. A favorite is only loaded into the draft editor until
/// the user explicitly chooses Connect; this keeps selecting a row from opening a network session.
struct MacConnectionLauncherView: View {
    let purchaseManager: PurchaseManager

    @Environment(\.modelContext) private var modelContext
    @Environment(\.appNavigation) private var navigation
    @Environment(\.monitorScheduler) private var scheduler
    @Query private var connections: [Connection]
    @Query private var favoriteGroups: [ConnectionFavoriteGroup]

    @State private var selection: LauncherSelectionState? = .quickConnect
    @SceneStorage("launcher.favoriteSearch") private var search = ""
    @SceneStorage("launcher.selection") private var restoredSelection = "quickConnect"
    @FocusState private var searchFocused: Bool
    @State private var draft = ConnectionDraft()
    @State private var secrets = ConnectionSecretDraft()
    @State private var activeConnection: Connection?
    @State private var activeSecret: Secret?
    @State private var activeRuntimeConfig: ConnectionConfig?
    @State private var activeVaultProvider: VaultMySQLEphemeralCredentialProvider?
    @State private var vaultTask: Task<Void, Never>?
    @State private var isVaultConnecting = false
    @State private var showsMonitors = false
    @State private var editorError: String?
    @State private var groupNameDraft = ""
    @State private var showsNewGroup = false
    @State private var groupToRename: ConnectionFavoriteGroup?
    @State private var groupToDelete: ConnectionFavoriteGroup?
    @State private var favoriteToTag: Connection?
    @State private var favoriteTagDraft = ""
    @State private var connectionToDelete: Connection?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                TextField("Search Favorites", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .focused($searchFocused)
                    .accessibilityLabel("Search favorites")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)

                sidebarList
            }
            .navigationTitle("Connections")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu("Favorite Actions", systemImage: "ellipsis.circle") {
                        Button("New Group", systemImage: "folder.badge.plus") {
                            groupNameDraft = ""
                            showsNewGroup = true
                        }
                        Button("New Favorite", systemImage: "plus") { newFavorite() }
                        if let selectedConnection {
                            Divider()
                            Button("Edit Favorite…", systemImage: "pencil") { editSelected() }
                            Button("Duplicate Favorite", systemImage: "plus.square.on.square") { duplicateSelected() }
                            Button("Delete Favorite…", systemImage: "trash", role: .destructive) {
                                connectionToDelete = selectedConnection
                            }
                        }
                    }
                }
            }
        } detail: {
            if let activeConnection {
                ConnectionDetailView(
                    connection: activeConnection,
                    runtimeSecret: activeSecret,
                    runtimeConfig: activeRuntimeConfig,
                    runtimeCredentialProvider: activeVaultProvider,
                    onCloseConnection: closeActiveConnection,
                    onConnectionFailed: connectionFailed
                )
                .id(activeConnection.id)
            } else if showsMonitors {
                MonitorsView()
            } else {
                launcherEditor
            }
        }
        .onChange(of: selection) { _, newValue in
            select(newValue)
        }
        .task { handleNavigationRequest() }
        .onChange(of: navigation.request?.id) { _, _ in handleNavigationRequest() }
        .onAppear { restoreLauncherSelection() }
        .onChange(of: selection) { _, newValue in persistLauncherSelection(newValue) }
        .confirmationDialog(
            "Delete “\(connectionToDelete?.name ?? "")”?",
            isPresented: $connectionToDelete.isPresent(),
            titleVisibility: .visible
        ) {
            Button("Delete Favorite", role: .destructive) {
                if let connectionToDelete { deleteFavorite(connectionToDelete) }
                connectionToDelete = nil
            }
            Button("Cancel", role: .cancel) { connectionToDelete = nil }
        } message: {
            Text("This removes the saved connection and its stored credentials. The database itself is untouched.")
        }
        .alert("New Favorite Group", isPresented: $showsNewGroup) {
            TextField("Group name", text: $groupNameDraft)
            Button("Create", action: createGroup)
            Button("Cancel", role: .cancel) { groupNameDraft = "" }
        } message: {
            Text("Create a folder for organizing saved connections.")
        }
        .alert("Rename Favorite Group", isPresented: $groupToRename.isPresent()) {
            TextField("Group name", text: $groupNameDraft)
            Button("Rename", action: renameGroup)
            Button("Cancel", role: .cancel) { groupToRename = nil }
        }
        .confirmationDialog(
            "Remove “\(groupToDelete?.name ?? "")”?",
            isPresented: $groupToDelete.isPresent(),
            titleVisibility: .visible
        ) {
            Button("Remove Group", role: .destructive) {
                if let groupToDelete { removeGroup(groupToDelete) }
                groupToDelete = nil
            }
            Button("Cancel", role: .cancel) { groupToDelete = nil }
        } message: {
            Text("Favorites in this group will remain saved and move to Favorites.")
        }
        .alert("Set Favorite Tag", isPresented: $favoriteToTag.isPresent()) {
            TextField("Tag", text: $favoriteTagDraft)
            Button("Save", action: saveFavoriteTag)
            Button("Cancel", role: .cancel) { favoriteToTag = nil }
        }
        .focusedSceneValue(\.launcherActions, LauncherActions(
            newFavorite: newFavorite,
            focusSearch: { searchFocused = true },
            connect: connectCurrentDraft,
            canConnect: canConnect,
            discardDraft: discardDraft,
            saveFavorite: saveCurrentFavorite,
            canSaveFavorite: canSaveFavorite,
            editSelected: selectedConnection.map { _ in { editSelected() } },
            duplicateSelected: selectedConnection.map { _ in { duplicateSelected() } },
            deleteSelected: selectedConnection.map { _ in { connectionToDelete = selectedConnection } }
        ))
        .frame(minWidth: 900, minHeight: 620)
    }

    private var sidebarList: some View {
        List(selection: $selection) {
            Section {
                Label("Quick Connect", systemImage: "bolt.horizontal.circle")
                    .tag(LauncherSelectionState.quickConnect)
            }
            ungroupedSection
            groupedSections
            Section {
                Label("Monitors", systemImage: "bell.badge")
                    .tag(LauncherSelectionState.monitors)
            }
        }
        .listStyle(.sidebar)
    }

    private var orderedGroups: [ConnectionFavoriteGroup] {
        favoriteGroups.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    @ViewBuilder
    private func groupSection(_ group: ConnectionFavoriteGroup) -> some View {
        let members = connections(in: group.id)
        Section {
            if members.isEmpty {
                Text("No favorites")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("No favorites in this group")
            } else {
                ForEach(members) { connection in
                    favoriteRow(connection)
                }
                .onMove { offsets, destination in
                    moveConnections(in: group.id, from: offsets, to: destination)
                }
            }
        } header: {
            HStack {
                Text(group.name)
                Spacer()
                Menu("Group Actions", systemImage: "ellipsis.circle") {
                    Button("Rename Group…", systemImage: "pencil") {
                        groupNameDraft = group.name
                        groupToRename = group
                    }
                    Button("Remove Group…", systemImage: "trash", role: .destructive) {
                        groupToDelete = group
                    }
                }
                .accessibilityLabel("Actions for group \(group.name)")
            }
        }
    }

    @ViewBuilder
    private var ungroupedSection: some View {
        Section("Favorites") {
            ForEach(ungroupedConnections, id: \.id) { connection in
                AnyView(favoriteRow(connection))
            }
            .onMove { offsets, destination in
                moveConnections(in: nil, from: offsets, to: destination)
            }
        }
    }

    @ViewBuilder
    private var groupedSections: some View {
        ForEach(orderedGroups, id: \.id) { group in
            AnyView(groupSection(group))
        }
    }

    private var ungroupedConnections: [Connection] {
        filteredConnections.filter { connection in
            connection.favoriteGroupID == nil || !favoriteGroups.contains(where: { $0.id == connection.favoriteGroupID })
        }
    }

    private func connections(in groupID: UUID) -> [Connection] {
        filteredConnections.filter { $0.favoriteGroupID == groupID }
    }

    private func connections(in groupID: UUID?) -> [Connection] {
        filteredConnections.filter { $0.favoriteGroupID == groupID }
    }

    private var filteredConnections: [Connection] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return connections
            .filter { connection in
                guard !needle.isEmpty else { return true }
                return FavoriteSearchFields(
                    name: connection.name,
                    host: connection.host,
                    username: connection.username,
                    database: connection.database,
                    driver: DriverRegistry.displayName(for: connection.driverID),
                    tag: connection.favoriteTag,
                    group: favoriteGroups.first(where: { $0.id == connection.favoriteGroupID })?.name ?? ""
                ).matches(needle)
            }
            .sorted {
                FavoriteOrderingKey.orderedBefore(
                    FavoriteOrderingKey(
                        favoriteOrder: $0.favoriteOrder,
                        legacyOrder: $0.sortOrder,
                        createdAt: $0.createdAt,
                        stableID: $0.id.uuidString
                    ),
                    FavoriteOrderingKey(
                        favoriteOrder: $1.favoriteOrder,
                        legacyOrder: $1.sortOrder,
                        createdAt: $1.createdAt,
                        stableID: $1.id.uuidString
                    )
                )
            }
    }

    private func favoriteRow(_ connection: Connection) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(connection.name.isEmpty ? "Untitled Connection" : connection.name)
                Text(connectionSubtitle(connection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: DriverRegistry.symbol(for: connection.driverID))
                .foregroundStyle(favoriteColor(for: connection.favoriteColorValue))
        }
        .tag(LauncherSelectionState.favorite(connection.id))
        .help("Edit this favorite, then choose Connect")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(favoriteAccessibilityLabel(connection))
        .contextMenu {
            Button("Edit Favorite…", systemImage: "pencil") { editSelected(connection) }
            Button("Duplicate Favorite", systemImage: "plus.square.on.square") { duplicate(connection) }
            favoriteMoveMenu(for: connection)
            favoriteReorderMenu(for: connection)
            Menu("Color", systemImage: "circle.fill") {
                ForEach(FavoriteColor.allCases) { color in
                    Button(color.title) { setFavoriteColor(color, for: connection) }
                }
            }
            Button("Set Tag…", systemImage: "tag") {
                favoriteTagDraft = connection.favoriteTag
                favoriteToTag = connection
            }
            Divider()
            Button("Delete Favorite", systemImage: "trash", role: .destructive) {
                connectionToDelete = connection
            }
        }
    }

    private func connectionSubtitle(_ connection: Connection) -> String {
        switch DriverRegistry.style(for: connection.driverID) {
        case .file: return (connection.database as NSString).lastPathComponent
        case .httpEndpoint: return connection.host
        case .server: return connection.host.isEmpty ? DriverRegistry.displayName(for: connection.driverID) : connection.host
        }
    }

    private func favoriteColor(for color: FavoriteColor) -> Color {
        switch color {
        case .none: return .secondary
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        }
    }

    @ViewBuilder
    private var launcherEditor: some View {
        VStack(spacing: 0) {
            if isVaultConnecting {
                HStack {
                    ProgressView()
                    Text("Signing in to Vault…")
                    Spacer()
                    Button("Cancel") { vaultTask?.cancel() }
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Signing in to Vault. Cancel button available.")
            }
            QuickConnectEditorView(
                draft: $draft,
                secrets: $secrets,
                onConnect: connect,
                onSaveFavorite: saveFavorite,
                canSaveFavorite: canSaveFavorite
            )
            .id(selection)
            if let editorError {
                Text(editorError)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }
        }
    }

    private var canSaveFavorite: Bool {
        draft.canSave(secrets: secrets)
    }

    private var canConnect: Bool {
        guard draft.canSave(secrets: secrets) else { return false }
        if selectedConnection != nil { return true }
        return connections.isEmpty || purchaseManager.isUnlocked
    }

    private func newFavorite() {
        selection = .quickConnect
        draft = ConnectionDraft()
        secrets = ConnectionSecretDraft()
        activeConnection = nil
        activeSecret = nil
        activeRuntimeConfig = nil
        activeVaultProvider = nil
        editorError = nil
    }

    private var selectedConnection: Connection? {
        guard case .favorite(let id) = selection else { return nil }
        return connections.first(where: { $0.id == id })
    }

    private func connectCurrentDraft() {
        connect(draft: draft, secrets: secrets)
    }

    private func saveCurrentFavorite() {
        saveFavorite(draft: draft, secrets: secrets)
    }

    private func discardDraft() {
        if let selectedConnection {
            draft = ConnectionDraft(connection: selectedConnection)
            secrets = ConnectionSecretDraft(stored: try? KeychainSecretStore().secret(for: selectedConnection.id))
        } else {
            draft = ConnectionDraft()
            secrets = ConnectionSecretDraft()
        }
        editorError = nil
    }

    private func editSelected() {
        guard selectedConnection != nil else { return }
        activeConnection = nil
        showsMonitors = false
    }

    private func editSelected(_ connection: Connection) {
        selection = .favorite(connection.id)
        editSelected()
    }

    private func duplicateSelected() {
        guard let selectedConnection else { return }
        duplicate(selectedConnection)
    }

    private func duplicate(_ connection: Connection) {
        var copy = ConnectionDraft(connection: connection)
        copy.id = nil
        copy.name = copy.name.isEmpty ? "Copy" : "\(copy.name) Copy"
        draft = copy
        secrets = ConnectionSecretDraft()
        selection = .quickConnect
        activeConnection = nil
        showsMonitors = false
        editorError = nil
    }

    private func restoreLauncherSelection() {
        let ids = Set(connections.map(\.id))
        let restored = LauncherStateRestoration.decode(restoredSelection, availableFavoriteIDs: ids)
        if selection != restored { selection = restored }
    }

    private func persistLauncherSelection(_ value: LauncherSelectionState?) {
        restoredSelection = LauncherStateRestoration.encode(value)
    }

    private func favoriteAccessibilityLabel(_ connection: Connection) -> String {
        let name = connection.name.isEmpty ? "Untitled Connection" : connection.name
        let color = connection.favoriteColorValue.title
        let tag = connection.favoriteTag.isEmpty ? "No tag" : "Tag \(connection.favoriteTag)"
        let group = favoriteGroups.first(where: { $0.id == connection.favoriteGroupID })?.name ?? "Favorites"
        return "\(name), \(connectionSubtitle(connection)), \(group), \(color), \(tag)"
    }

    @ViewBuilder
    private func favoriteMoveMenu(for connection: Connection) -> some View {
        Menu("Move to Group", systemImage: "folder") {
            Button("Favorites") { move(connection, to: nil) }
            ForEach(orderedGroups) { group in
                Button(group.name) { move(connection, to: group.id) }
            }
        }
    }

    @ViewBuilder
    private func favoriteReorderMenu(for connection: Connection) -> some View {
        Menu("Reorder", systemImage: "arrow.up.arrow.down") {
            Button("Move Up") { reorder(connection, offset: -1) }
            Button("Move Down") { reorder(connection, offset: 1) }
        }
    }

    private func move(_ connection: Connection, to groupID: UUID?) {
        connection.favoriteGroupID = groupID
        connection.favoriteOrder = nextOrder(in: groupID)
        try? modelContext.save()
    }

    private func reorder(_ connection: Connection, offset: Int) {
        let members = connections(in: connection.favoriteGroupID)
        guard let index = members.firstIndex(where: { $0.id == connection.id }) else { return }
        let target = min(max(index + offset, 0), members.count - 1)
        guard target != index else { return }
        var reordered = members
        reordered.swapAt(index, target)
        for (position, member) in reordered.enumerated() { member.favoriteOrder = position + 1 }
        try? modelContext.save()
    }

    private func moveConnections(in groupID: UUID?, from offsets: IndexSet, to destination: Int) {
        let members = connections(in: groupID)
        guard search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var reordered = members
        reordered.move(fromOffsets: offsets, toOffset: destination)
        for (position, member) in reordered.enumerated() { member.favoriteOrder = position + 1 }
        try? modelContext.save()
    }

    private func nextOrder(in groupID: UUID?) -> Int {
        (connections(in: groupID).map(\.favoriteOrder).max() ?? 0) + 1
    }

    private func createGroup() {
        let name = groupNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        modelContext.insert(ConnectionFavoriteGroup(name: name, sortOrder: (favoriteGroups.map(\.sortOrder).max() ?? -1) + 1))
        try? modelContext.save()
        groupNameDraft = ""
    }

    private func renameGroup() {
        guard let groupToRename else { return }
        let name = groupNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        groupToRename.name = name
        try? modelContext.save()
        self.groupToRename = nil
        groupNameDraft = ""
    }

    private func removeGroup(_ group: ConnectionFavoriteGroup) {
        for connection in connections where connection.favoriteGroupID == group.id {
            connection.favoriteGroupID = nil
            connection.favoriteOrder = 0
        }
        modelContext.delete(group)
        try? modelContext.save()
    }

    private func setFavoriteColor(_ color: FavoriteColor, for connection: Connection) {
        connection.favoriteColor = color.rawValue
        try? modelContext.save()
    }

    private func saveFavoriteTag() {
        guard let favoriteToTag else { return }
        favoriteToTag.favoriteTag = favoriteTagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        try? modelContext.save()
        self.favoriteToTag = nil
    }

    private func deleteFavorite(_ connection: Connection) {
        do {
            try KeychainSecretStore().delete(for: connection.id)
            modelContext.delete(connection)
            try modelContext.save()
            selection = .quickConnect
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func select(_ newSelection: LauncherSelectionState?) {
        activeConnection = nil
        activeSecret = nil
        activeRuntimeConfig = nil
        activeVaultProvider = nil
        editorError = nil
        guard let newSelection else { return }
        switch newSelection {
        case .quickConnect:
            showsMonitors = false
            draft = ConnectionDraft()
            secrets = ConnectionSecretDraft()
        case .favorite(let id):
            showsMonitors = false
            guard let connection = connections.first(where: { $0.id == id }) else { return }
            draft = ConnectionDraft(connection: connection)
            secrets = ConnectionSecretDraft(stored: try? KeychainSecretStore().secret(for: connection.id))
        case .monitors:
            showsMonitors = true
        }
    }

    private func connect(draft: ConnectionDraft, secrets: ConnectionSecretDraft) {
        editorError = nil
        guard draft.canSave(secrets: secrets) else {
            editorError = "Complete the required connection fields before connecting."
            return
        }
        if selectedConnection == nil, !connections.isEmpty, !purchaseManager.isUnlocked {
            editorError = "Unlock DB Connect to connect with an additional favorite."
            return
        }

        if draft.authenticationMode == .vaultOIDC {
            connectVault(draft: draft)
            return
        }
        finishConnection(draft: draft, secrets: secrets)
    }

    private func finishConnection(draft: ConnectionDraft, secrets: ConnectionSecretDraft) {
        if let selectedConnection {
            activeConnection = selectedConnection
            activeRuntimeConfig = draft.config
        } else {
            let connection = Connection(
                name: draft.name.isEmpty ? "Quick Connect" : draft.name,
                driverID: draft.driverID
            )
            draft.apply(to: connection)
            activeConnection = connection
            activeRuntimeConfig = nil
        }
        activeVaultProvider = nil
        // Quick Connect credentials stay in memory and are passed directly to the workspace.
        // No SwiftData insert and no Keychain write occurs on this path.
        let existingSecret = selectedConnection.flatMap { try? KeychainSecretStore().secret(for: $0.id) }
        activeSecret = LauncherStateRestoration.usesRuntimeSecret(
            selection: selection,
            hasTypedSecret: secrets.hasTypedValues
        ) ? secrets.merged(with: existingSecret, authenticationMode: draft.authenticationMode) : nil
    }

    private func connectVault(draft: ConnectionDraft) {
        guard !isVaultConnecting else { return }
        guard let configuration = draft.vaultAuthenticationConfiguration else {
            editorError = "Enter a valid HTTPS Vault server, auth role, and database role."
            return
        }
        editorError = nil
        isVaultConnecting = true
        vaultTask = Task { @MainActor in
            defer {
                isVaultConnecting = false
                vaultTask = nil
            }
            do {
                let api = VaultHTTPClient()
                let coordinator = try VaultOIDCAuthenticationCoordinator(
                    api: api,
                    redirectURI: URL(string: "db-connect://vault/callback")!,
                    presentationAnchorProvider: {
                        guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
                            return NSWindow()
                        }
                        return window
                    }
                )
                let provider = try VaultMySQLEphemeralCredentialProvider(
                    configuration: configuration,
                    authenticator: coordinator,
                    api: api
                )
                let credentials = try await provider.credentials()
                let connection: Connection
                let baseConfig: ConnectionConfig
                if let selectedConnection {
                    connection = selectedConnection
                    baseConfig = draft.config
                } else {
                    let transient = Connection(
                        name: draft.name.isEmpty ? "Quick Connect" : draft.name,
                        driverID: draft.driverID
                    )
                    draft.apply(to: transient)
                    connection = transient
                    baseConfig = transient.config
                }
                let inputs = credentials.connectionInputs(for: baseConfig)
                activeConnection = connection
                activeRuntimeConfig = inputs.config
                activeSecret = inputs.secret
                activeVaultProvider = provider
            } catch {
                if Task.isCancelled { return }
                activeConnection = nil
                activeRuntimeConfig = nil
                activeSecret = nil
                activeVaultProvider = nil
                editorError = error.localizedDescription
            }
        }
    }

    private func saveFavorite(draft: ConnectionDraft, secrets: ConnectionSecretDraft) {
        guard draft.canSave(secrets: secrets) else { return }
        let editingExistingFavorite: Bool = {
            if case .favorite(let id) = selection { return connections.contains { $0.id == id } }
            return false
        }()
        guard editingExistingFavorite || connections.isEmpty || purchaseManager.isUnlocked else {
            editorError = "Unlock DB Connect to save more than one favorite."
            return
        }

        let connection: Connection
        if case .favorite(let id) = selection,
           let existing = connections.first(where: { $0.id == id }) {
            connection = existing
        } else {
            connection = Connection(
                name: draft.name.isEmpty ? "Untitled Connection" : draft.name,
                driverID: draft.driverID
            )
            modelContext.insert(connection)
        }
        draft.apply(to: connection)
        do {
            let existingSecret = try KeychainSecretStore().secret(for: connection.id)
            let merged = secrets.merged(with: existingSecret, authenticationMode: draft.authenticationMode)
            if merged.hasPersistedValue {
                try KeychainSecretStore().save(merged, for: connection.id)
            } else if draft.authenticationMode == .vaultOIDC {
                try KeychainSecretStore().delete(for: connection.id)
            }
            try modelContext.save()
            selection = .favorite(connection.id)
            editorError = nil
        } catch {
            editorError = error.localizedDescription
        }
    }

    private func closeActiveConnection() {
        activeConnection = nil
        activeSecret = nil
        activeRuntimeConfig = nil
        activeVaultProvider = nil
        editorError = nil
    }

    private func connectionFailed(_ message: String) {
        activeConnection = nil
        activeSecret = nil
        activeRuntimeConfig = nil
        activeVaultProvider = nil
        editorError = message
    }

    private func handleNavigationRequest() {
        guard let request = navigation.request else { return }
        switch request.destination {
        case .savedQuery(let queryID):
            guard let connection = connections.first(where: { ($0.savedQueries ?? []).contains(where: { $0.id == queryID }) }) else { return }
            selection = .favorite(connection.id)
            activeConnection = connection
            activeSecret = nil
            showsMonitors = false
            // ConnectionDetailView consumes this after loading the requested SQL into its editor.
        case .monitor, .monitors, .runMonitors:
            showsMonitors = true
            activeConnection = nil
            selection = .monitors
            if case .monitors = request.destination { navigation.consume(request.id) }
            if case .runMonitors = request.destination {
                Task { await scheduler?.runDue(force: true) }
                navigation.consume(request.id)
            }
        }
    }
}

private enum LauncherConnectionMethod: String, CaseIterable, Identifiable {
    case mysqlTCP
    case mysqlSocket
    case mysqlSSH
    case mysqlAWSIAM
    case mysqlVault
    case postgresTCP
    case postgresSSH
    case sqliteFile
    case supabaseEndpoint

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mysqlTCP: "MySQL — TCP"
        case .mysqlSocket: "MySQL — Local Socket"
        case .mysqlSSH: "MySQL — SSH Tunnel"
        case .mysqlAWSIAM: "MySQL — AWS IAM"
        case .mysqlVault: "MySQL — Vault OIDC"
        case .postgresTCP: "PostgreSQL — TCP"
        case .postgresSSH: "PostgreSQL — SSH Tunnel"
        case .sqliteFile: "SQLite — File"
        case .supabaseEndpoint: "Supabase — Endpoint"
        }
    }

    var driverID: String {
        switch self {
        case .mysqlTCP, .mysqlSocket, .mysqlSSH, .mysqlAWSIAM, .mysqlVault: MySQLDriver.id
        case .postgresTCP, .postgresSSH: PostgresDriver.id
        case .sqliteFile: SQLiteDriver.id
        case .supabaseEndpoint: SupabaseDriver.id
        }
    }
}

private struct QuickConnectEditorView: View {
    @Binding var draft: ConnectionDraft
    @Binding var secrets: ConnectionSecretDraft
    let onConnect: (ConnectionDraft, ConnectionSecretDraft) -> Void
    let onSaveFavorite: (ConnectionDraft, ConnectionSecretDraft) -> Void
    let canSaveFavorite: Bool

    @State private var method: LauncherConnectionMethod = .mysqlTCP
    @State private var showsFileImporter = false

    var body: some View {
        Form {
            Section {
                Picker("Method", selection: $method) {
                    ForEach(LauncherConnectionMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                TextField("Name (optional)", text: $draft.name)
            }

            fields

            Section {
                HStack {
                    Button("Connect", systemImage: "bolt.horizontal.circle") {
                        onConnect(draft, secrets)
                    }
                    .keyboardShortcut(.defaultAction)
                    Spacer()
                    Button("Save Favorite", systemImage: "star") {
                        onSaveFavorite(draft, secrets)
                    }
                    .disabled(!canSaveFavorite)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Quick Connect")
        .onAppear {
            method = methodForDraft()
            synchronizeMethod()
        }
        .onChange(of: method) { _, _ in synchronizeMethod() }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: [.data, .database]) { result in
            guard case .success(let url) = result else { return }
            draft.database = url.path
            draft.bookmarkData = try? url.bookmarkData(options: [.withSecurityScope])
            draft.containerBookmarkData = try? url.deletingLastPathComponent().bookmarkData(options: [.withSecurityScope])
            draft.fileAccessOwnerDeviceID = DeviceIdentity.current.id
            draft.fileAccessOwnerDeviceName = DeviceIdentity.current.name
            if draft.name.isEmpty { draft.name = url.deletingPathExtension().lastPathComponent }
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch method {
        case .sqliteFile:
            Section("Database File") {
                HStack {
                    Text(draft.database.isEmpty ? "No file selected" : (draft.database as NSString).lastPathComponent)
                        .foregroundStyle(draft.database.isEmpty ? .secondary : .primary)
                    Spacer()
                    Button("Choose File…") { showsFileImporter = true }
                }
                Toggle("Read-only", isOn: $draft.isReadOnly)
            }
        case .supabaseEndpoint:
            Section("Endpoint") {
                TextField("Project URL", text: $draft.host)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                SecureField("API Key", text: $secrets.password)
                Toggle("Read-only", isOn: $draft.isReadOnly)
            }
        case .mysqlVault:
            Section("Vault OIDC") {
                TextField("Vault Server URL", text: $draft.vaultServerURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                TextField("Auth Mount", text: $draft.vaultAuthMount)
                TextField("Auth Role", text: $draft.vaultRole)
                TextField("Database Mount", text: $draft.vaultDatabaseMount)
                TextField("Database Role", text: $draft.vaultDatabaseRole)
                TextField("MySQL Host", text: $draft.host)
                TextField("Port", value: $draft.port, format: .number.grouping(.never))
                TextField("Database (optional)", text: $draft.database)
                Toggle("Read-only", isOn: $draft.isReadOnly)
                Picker("Encryption", selection: $draft.tlsMode) {
                    Text("Required").tag(TLSMode.required)
                    Text("Preferred").tag(TLSMode.preferred)
                    Text("Pinned certificate").tag(TLSMode.pinned)
                    Text("Disabled").tag(TLSMode.disabled)
                }
                if draft.tlsMode == .pinned {
                    TextEditor(text: $draft.certificatePEM)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 80)
                        .accessibilityLabel("Pinned certificate PEM")
                }
                Text("Vault signs you in in the system browser and leases a short-lived MySQL password. The lease is never saved in the favorite.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        default:
            Section("Server") {
                if method == .mysqlSocket {
                    TextField("Socket path", text: $draft.socketPath)
                    TextField("Database (optional)", text: $draft.database)
                } else {
                    TextField("Host", text: $draft.host)
                    TextField("Port", value: $draft.port, format: .number.grouping(.never))
                    TextField("Database (optional)", text: $draft.database)
                }
                TextField("Username", text: $draft.username)
                Toggle("Read-only", isOn: $draft.isReadOnly)
                if method == .mysqlAWSIAM {
                    TextField("AWS Region", text: $draft.awsRegion)
                    TextField("Access Key ID", text: $secrets.awsAccessKeyID)
                    SecureField("Secret Access Key", text: $secrets.awsSecretAccessKey)
                    SecureField("Session Token (optional)", text: $secrets.awsSessionToken)
                } else {
                    SecureField("Password", text: $secrets.password)
                }
            }
            if method != .mysqlSocket {
                Section("Transport Security") {
                    Picker("Encryption", selection: $draft.tlsMode) {
                        Text("Required").tag(TLSMode.required)
                        Text("Preferred").tag(TLSMode.preferred)
                        Text("Pinned certificate").tag(TLSMode.pinned)
                        Text("Disabled").tag(TLSMode.disabled)
                    }
                    if draft.tlsMode == .pinned {
                        TextEditor(text: $draft.certificatePEM)
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 80)
                            .accessibilityLabel("Pinned certificate PEM")
                    }
                }
            }

            if method == .mysqlSSH || method == .postgresSSH {
                Section("SSH Tunnel") {
                    TextField("SSH Host", text: $draft.sshHost)
                    TextField("SSH Port", value: $draft.sshPort, format: .number.grouping(.never))
                    TextField("SSH Username", text: $draft.sshUsername)
                    Picker("Authentication", selection: $draft.sshAuthenticationMode) {
                        Text("SSH Agent").tag(SSHTunnelAuthenticationMode.agent)
                        Text("Password").tag(SSHTunnelAuthenticationMode.password)
                        Text("Private Key").tag(SSHTunnelAuthenticationMode.privateKey)
                    }
                    if draft.sshAuthenticationMode == .password {
                        SecureField("SSH Password", text: $secrets.sshPassword)
                    }
                    if draft.sshAuthenticationMode == .privateKey {
                        SecureField("Private Key", text: $secrets.sshPrivateKey)
                        SecureField("Key Passphrase (optional)", text: $secrets.sshPassphrase)
                    }
                }
            }
        }
    }

    private func synchronizeMethod() {
        let wasSocket = draft.transportMode == .unixSocket
        draft.driverID = method.driverID
        switch method {
        case .mysqlSocket:
            draft.didChangeTransport(to: .unixSocket)
            draft.authenticationMode = .password
        case .mysqlAWSIAM:
            draft.didChangeTransport(to: .tcp)
            draft.authenticationMode = .awsIAM
        case .mysqlVault:
            draft.didChangeTransport(to: .tcp)
            draft.authenticationMode = .vaultOIDC
            draft.vaultAuthMount = draft.vaultAuthMount.isEmpty ? "oidc" : draft.vaultAuthMount
            draft.vaultDatabaseMount = draft.vaultDatabaseMount.isEmpty ? "database" : draft.vaultDatabaseMount
        case .mysqlSSH, .postgresSSH:
            draft.didChangeTransport(to: .tcp)
            draft.authenticationMode = .password
            draft.sshTunnelEnabled = true
        default:
            draft.didChangeTransport(to: .tcp)
            draft.authenticationMode = .password
            draft.sshTunnelEnabled = false
        }
        if wasSocket, method != .mysqlSocket { draft.tlsMode = .required }
        if draft.port == 0 {
            draft.port = DriverRegistry.defaultPort(for: method.driverID)
        }
    }

    private func methodForDraft() -> LauncherConnectionMethod {
        switch draft.driverID {
        case MySQLDriver.id:
            if draft.transportMode == .unixSocket { return .mysqlSocket }
            if draft.authenticationMode == .awsIAM { return .mysqlAWSIAM }
            if draft.sshTunnelEnabled { return .mysqlSSH }
            if draft.authenticationMode == .vaultOIDC { return .mysqlVault }
            return .mysqlTCP
        case PostgresDriver.id:
            return draft.sshTunnelEnabled ? .postgresSSH : .postgresTCP
        case SQLiteDriver.id:
            return .sqliteFile
        case SupabaseDriver.id:
            return .supabaseEndpoint
        default:
            return .mysqlTCP
        }
    }
}
#endif
