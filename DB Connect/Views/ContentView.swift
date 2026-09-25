import SwiftUI
import SwiftData

struct ContentView: View {
    let purchaseManager: PurchaseManager

    @Environment(\.modelContext) private var modelContext
    @Query private var connections: [Connection]
    @Query private var favoriteGroups: [ConnectionFavoriteGroup]
    @Query private var savedQueries: [SavedQuery]

    @Environment(\.appNavigation) private var navigation
    @Environment(\.monitorScheduler) private var scheduler

    @State private var selection: SidebarItem?
    @State private var showsNewConnection = false
    @State private var showsPaywall = false
    @State private var pendingPaidAction: PaidAction?
    @State private var editingConnection: Connection?
    @State private var favoriteSearch = ""
    @State private var showsNewFavoriteGroup = false
    @State private var groupNameDraft = ""
    @State private var groupToRename: ConnectionFavoriteGroup?
    @State private var groupToDelete: ConnectionFavoriteGroup?
    @State private var favoriteToTag: Connection?
    @State private var favoriteTagDraft = ""
    /// A menu item is far easier to hit by accident than a context menu, and deleting a
    /// connection also drops its Keychain entry, so the menu route confirms first.
    @State private var connectionToDelete: Connection?
    @State private var showsOnboarding = false
    @AppStorage(DBConnectOnboarding.releaseDefaultsKey)
    private var lastSeenOnboardingRelease = 0
    #if os(iOS)
    @State private var showsSettings = false
    #endif

    /// The sidebar mixes connections with the monitors section, so selection needs one type.
    enum SidebarItem: Hashable {
        case connection(Connection)
        case monitors
    }

    private enum PaidAction {
        case addConnection
        case duplicate(UUID)
    }

    var body: some View {
        #if os(macOS)
        MacConnectionLauncherView(purchaseManager: purchaseManager)
        #else
        mobileBody
        #endif
    }

    #if os(iOS)
    private var mobileBody: some View {
        NavigationSplitView {
            List(selection: $selection) {
                favoriteSection(groupID: nil, title: "Favorites")

                ForEach(orderedFavoriteGroups) { group in
                    if !connections(in: group.id).isEmpty || favoriteSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Section {
                            ForEach(connections(in: group.id)) { connection in
                                favoriteRow(connection)
                            }
                            .onMove { offsets, destination in
                                moveConnections(in: group.id, from: offsets, to: destination)
                            }
                            .onDelete { offsets in
                                deleteConnections(connections(in: group.id), at: offsets)
                            }
                        } header: {
                            favoriteGroupHeader(group)
                        }
                    }
                }

                Section {
                    Label("Monitors", systemImage: "bell.badge")
                        .tag(SidebarItem.monitors)
                }
            }
            .searchable(text: $favoriteSearch, placement: .sidebar, prompt: "Search Favorites")
            .navigationTitle("Favorites")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Add Connection", systemImage: "plus") {
                        requestNewConnection()
                    }
                    .help("Add a database connection")

                    Menu("Favorite Actions", systemImage: "ellipsis.circle") {
                        Button("New Group", systemImage: "folder.badge.plus") {
                            beginNewGroup()
                        }
                        if let selectedConnection {
                            Divider()
                            Button("Edit Favorite…", systemImage: "pencil") {
                                editingConnection = selectedConnection
                            }
                            favoriteMoveMenu(for: selectedConnection)
                            Button("Duplicate Favorite", systemImage: "plus.square.on.square") {
                                requestDuplicate(selectedConnection)
                            }
                            Button("Delete Favorite", systemImage: "trash", role: .destructive) {
                                connectionToDelete = selectedConnection
                            }
                        }
                    }
                }
                #if os(iOS)
                // macOS gets the standard Settings window from the app menu instead.
                ToolbarItem(placement: .secondaryAction) {
                    Button("Settings", systemImage: "gearshape") {
                        showsSettings = true
                    }
                }
                #endif
            }
        } detail: {
            switch selection {
            case .connection(let connection):
                ConnectionDetailView(
                    connection: connection,
                    onEditConnection: { editingConnection = connection },
                    onDeleteConnection: { connectionToDelete = connection }
                )
                    .id(connection.id)   // rebuild sessions when switching connections
            case .monitors:
                MonitorsView()
            case nil:
                ContentUnavailableView("Select a Connection", systemImage: "cylinder.split.1x2")
            }
        }
        .sheet(isPresented: $showsNewConnection) {
            ConnectionEditorView(purchaseManager: purchaseManager)
        }
        .sheet(item: $editingConnection) { connection in
            ConnectionEditorView(purchaseManager: purchaseManager, existing: connection)
        }
        .sheet(isPresented: $showsPaywall, onDismiss: completePaidActionIfUnlocked) {
            PaywallView(purchaseManager: purchaseManager)
        }
        .confirmationDialog(
            "Delete “\(connectionToDelete?.name ?? "")”?",
            isPresented: $connectionToDelete.isPresent(),
            titleVisibility: .visible
        ) {
            Button("Delete Connection", role: .destructive) {
                if let connectionToDelete { delete(connectionToDelete) }
                connectionToDelete = nil
            }
            Button("Cancel", role: .cancel) { connectionToDelete = nil }
        } message: {
            Text("This removes the connection and its stored password. The database itself is untouched.")
        }
        .confirmationDialog(
            "Delete “\(groupToDelete?.name ?? "")”?",
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
        .alert("New Favorite Group", isPresented: $showsNewFavoriteGroup) {
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
        .alert("Set Favorite Tag", isPresented: $favoriteToTag.isPresent()) {
            TextField("Tag", text: $favoriteTagDraft)
            Button("Save", action: saveFavoriteTag)
            Button("Cancel", role: .cancel) { favoriteToTag = nil }
        }
        .focusedSceneValue(\.connectionListActions, ConnectionListActions(
            newConnection: { requestNewConnection() },
            editSelected: selectedConnection.map { connection in
                { editingConnection = connection }
            },
            duplicateSelected: selectedConnection.map { connection in
                { requestDuplicate(connection) }
            },
            deleteSelected: selectedConnection.map { connection in
                { connectionToDelete = connection }
            },
            // Deselecting tears down `ConnectionDetailView`, whose `onDisappear` closes the
            // session — so this is a real hang-up, not just a change of view.
            closeSelected: selectedConnection.map { _ in
                { selection = nil }
            }
        ))
        .background { WidgetSnapshotSyncView() }
        .task { handleNavigationRequest() }
        .task { presentOnboardingIfNeeded() }
        .onChange(of: navigation.request?.id) { _, _ in handleNavigationRequest() }
        .sheet(isPresented: $showsOnboarding) {
            DBConnectOnboardingView()
        }
        #if os(iOS)
        .sheet(isPresented: $showsSettings) {
            SettingsSheet()
        }
        #endif
    }
    #endif

    private var orderedFavoriteGroups: [ConnectionFavoriteGroup] {
        favoriteGroups.sorted {
            if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    private var knownGroupIDs: Set<UUID> {
        Set(favoriteGroups.map(\.id))
    }

    private var groupNames: [UUID: String] {
        Dictionary(uniqueKeysWithValues: favoriteGroups.map { ($0.id, $0.name) })
    }

    private func connections(in groupID: UUID?) -> [Connection] {
        let filtered = connections.filter { connection in
            let belongs: Bool
            if let groupID {
                belongs = connection.favoriteGroupID == groupID
            } else {
                // A record can briefly outlive its group during concurrent edits.
                // Treat that as ungrouped rather than hiding the favorite.
                belongs = connection.favoriteGroupID == nil || !knownGroupIDs.contains(connection.favoriteGroupID!)
            }
            guard belongs else { return false }

            return FavoriteSearchFields(
                name: connection.name,
                host: connection.host,
                username: connection.username,
                database: connection.database,
                driver: "\(DriverRegistry.displayName(for: connection.driverID)) \(connection.driverID)",
                tag: connection.favoriteTag,
                group: groupID.flatMap { groupNames[$0] } ?? ""
            ).matches(favoriteSearch)
        }

        return filtered.sorted { lhs, rhs in
            FavoriteOrderingKey.orderedBefore(
                FavoriteOrderingKey(
                    favoriteOrder: lhs.favoriteOrder,
                    legacyOrder: lhs.sortOrder,
                    createdAt: lhs.createdAt,
                    stableID: lhs.id.uuidString
                ),
                FavoriteOrderingKey(
                    favoriteOrder: rhs.favoriteOrder,
                    legacyOrder: rhs.sortOrder,
                    createdAt: rhs.createdAt,
                    stableID: rhs.id.uuidString
                )
            )
        }
    }

    @ViewBuilder
    private func favoriteSection(groupID: UUID?, title: String) -> some View {
        Section(title) {
            ForEach(connections(in: groupID)) { connection in
                favoriteRow(connection)
            }
            .onMove { offsets, destination in
                moveConnections(in: groupID, from: offsets, to: destination)
            }
            .onDelete { offsets in
                deleteConnections(connections(in: groupID), at: offsets)
            }
        }
    }

    @ViewBuilder
    private func favoriteRow(_ connection: Connection) -> some View {
        ConnectionRow(connection: connection) {
            editingConnection = connection
        }
        .tag(SidebarItem.connection(connection))
        .contextMenu {
            Button("Edit…", systemImage: "pencil") {
                editingConnection = connection
            }
            Button("Duplicate", systemImage: "plus.square.on.square") {
                requestDuplicate(connection)
            }
            favoriteMoveMenu(for: connection)
            favoriteReorderMenu(for: connection)
            Menu("Color", systemImage: "circle.fill") {
                ForEach(FavoriteColor.allCases) { color in
                    Button {
                        setFavoriteColor(color, for: connection)
                    } label: {
                        Label(color.title, systemImage: color == .none ? "circle" : "circle.fill")
                    }
                }
            }
            Button("Set Tag…", systemImage: "tag") {
                favoriteTagDraft = connection.favoriteTag
                favoriteToTag = connection
            }
            // Only meaningful for the connection that is actually open.
            if selectedConnection?.id == connection.id {
                Button("Close Connection", systemImage: "xmark.circle") {
                    selection = nil
                }
            }
            Divider()
            Button("Delete", systemImage: "trash", role: .destructive) {
                connectionToDelete = connection
            }
        }
        .swipeActions(edge: .leading) {
            Button("Edit", systemImage: "pencil") {
                editingConnection = connection
            }
            .tint(.blue)
        }
    }

    @ViewBuilder
    private func favoriteGroupHeader(_ group: ConnectionFavoriteGroup) -> some View {
        HStack {
            Label(group.name.isEmpty ? "Unnamed Group" : group.name, systemImage: "folder")
            Spacer()
            Menu("Group Actions", systemImage: "ellipsis.circle") {
                Button("Rename Group", systemImage: "pencil") {
                    groupNameDraft = group.name
                    groupToRename = group
                }
                Button("Remove Group", systemImage: "trash", role: .destructive) {
                    groupToDelete = group
                }
            }
            .labelStyle(.iconOnly)
            .accessibilityLabel("Actions for \(group.name.isEmpty ? "unnamed group" : group.name)")
        }
        .contextMenu {
            Button("Rename Group", systemImage: "pencil") {
                groupNameDraft = group.name
                groupToRename = group
            }
            Button("Remove Group", systemImage: "trash", role: .destructive) {
                groupToDelete = group
            }
        }
    }

    @ViewBuilder
    private func favoriteMoveMenu(for connection: Connection) -> some View {
        Menu("Move to Group", systemImage: "folder") {
            Button("Favorites") { move(connection, to: nil) }
            if !orderedFavoriteGroups.isEmpty { Divider() }
            ForEach(orderedFavoriteGroups) { group in
                Button(group.name.isEmpty ? "Unnamed Group" : group.name) {
                    move(connection, to: group.id)
                }
            }
        }
    }

    @ViewBuilder
    private func favoriteReorderMenu(for connection: Connection) -> some View {
        let groupID = normalizedGroupID(for: connection)
        let items = connections(in: groupID)
        let position = items.firstIndex { $0.id == connection.id }
        Menu("Reorder", systemImage: "arrow.up.arrow.down") {
            Button("Move Up", systemImage: "arrow.up") {
                reorderFavorite(connection, by: -1)
            }
            .disabled(position == nil || position == 0 || !canReorderFavorites)
            Button("Move Down", systemImage: "arrow.down") {
                reorderFavorite(connection, by: 1)
            }
            .disabled(position == nil || position == items.count - 1 || !canReorderFavorites)
        }
        .disabled(!canReorderFavorites)
    }

    private func beginNewGroup() {
        groupNameDraft = ""
        showsNewFavoriteGroup = true
    }

    private func createGroup() {
        let name = groupNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            groupNameDraft = ""
            return
        }
        let order = (favoriteGroups.map(\.sortOrder).max() ?? -1) + 1
        modelContext.insert(ConnectionFavoriteGroup(name: uniqueGroupName(name), sortOrder: order))
        try? modelContext.save()
        groupNameDraft = ""
    }

    private func uniqueGroupName(_ proposed: String, excluding excludedID: UUID? = nil) -> String {
        let existing = Set(
            favoriteGroups
                .filter { $0.id != excludedID }
                .map { $0.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current) }
        )
        guard existing.contains(proposed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) else {
            return proposed
        }
        var suffix = 2
        while existing.contains("\(proposed) \(suffix)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)) {
            suffix += 1
        }
        return "\(proposed) \(suffix)"
    }

    private func renameGroup() {
        defer {
            groupToRename = nil
            groupNameDraft = ""
        }
        guard let group = groupToRename else { return }
        let name = groupNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        group.name = uniqueGroupName(name, excluding: group.id)
        try? modelContext.save()
    }

    private func removeGroup(_ group: ConnectionFavoriteGroup) {
        for connection in connections where connection.favoriteGroupID == group.id {
            connection.favoriteGroupID = FavoriteGroupSemantics.groupID(
                afterRemoving: group.id,
                from: connection.favoriteGroupID
            )
            connection.favoriteOrder = 0
        }
        modelContext.delete(group)
        try? modelContext.save()
    }

    private func move(_ connection: Connection, to groupID: UUID?) {
        connection.favoriteGroupID = groupID
        connection.favoriteOrder = nextFavoriteOrder(in: groupID, excluding: connection.id)
        try? modelContext.save()
    }

    private func moveConnections(in groupID: UUID?, from offsets: IndexSet, to destination: Int) {
        guard favoriteSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        var items = connections(in: groupID)
        items.move(fromOffsets: offsets, toOffset: destination)
        for (index, connection) in items.enumerated() {
            connection.favoriteOrder = index + 1
        }
        try? modelContext.save()
    }

    private var canReorderFavorites: Bool {
        favoriteSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func normalizedGroupID(for connection: Connection) -> UUID? {
        guard let groupID = connection.favoriteGroupID, knownGroupIDs.contains(groupID) else {
            return nil
        }
        return groupID
    }

    private func reorderFavorite(_ connection: Connection, by offset: Int) {
        guard canReorderFavorites else { return }
        let groupID = normalizedGroupID(for: connection)
        var items = connections(in: groupID)
        guard let source = items.firstIndex(where: { $0.id == connection.id }) else { return }
        let destination = source + offset
        guard items.indices.contains(destination) else { return }
        items.swapAt(source, destination)
        for (index, item) in items.enumerated() {
            item.favoriteOrder = index + 1
        }
        try? modelContext.save()
    }

    private func nextFavoriteOrder(in groupID: UUID?, excluding excludedID: UUID? = nil) -> Int {
        let orders = connections(in: groupID)
            .filter { $0.id != excludedID }
            .map(\.favoriteOrder)
        return max(orders.max() ?? 0, 0) + 1
    }

    private func setFavoriteColor(_ color: FavoriteColor, for connection: Connection) {
        connection.favoriteColor = color.rawValue
        try? modelContext.save()
    }

    private func saveFavoriteTag() {
        defer { favoriteToTag = nil }
        guard let connection = favoriteToTag else { return }
        connection.favoriteTag = favoriteTagDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        favoriteTagDraft = ""
        try? modelContext.save()
    }

    private func handleNavigationRequest() {
        guard let request = navigation.request else { return }

        switch request.destination {
        case .savedQuery(let queryID):
            guard let connection = savedQueries.first(where: { $0.id == queryID })?.connection else {
                return
            }
            selection = .connection(connection)
            // ConnectionDetailView consumes this after it has loaded the SQL into its draft.
        case .monitor:
            selection = .monitors
            // MonitorsView consumes this after selecting the requested monitor.
        case .monitors:
            selection = .monitors
            navigation.consume(request.id)
        case .runMonitors:
            selection = .monitors
            navigation.consume(request.id)
            Task { await scheduler?.runDue(force: true) }
        }
    }

    private func presentOnboardingIfNeeded() {
        guard DBConnectOnboardingPresentation.shared.claimAutomaticPresentation(
            lastSeenRelease: lastSeenOnboardingRelease
        ) else { return }
        showsOnboarding = true
    }

    /// The connection the menu commands act on. Nil while the Monitors section is selected,
    /// which is what greys those items out.
    private var selectedConnection: Connection? {
        if case .connection(let connection) = selection { return connection }
        return nil
    }

    private func requestNewConnection() {
        guard connections.isEmpty || purchaseManager.isUnlocked else {
            pendingPaidAction = .addConnection
            showsPaywall = true
            return
        }
        showsNewConnection = true
    }

    private func requestDuplicate(_ connection: Connection) {
        guard connections.isEmpty || purchaseManager.isUnlocked else {
            pendingPaidAction = .duplicate(connection.id)
            showsPaywall = true
            return
        }
        duplicate(connection)
    }

    /// Run the action only after the paywall sheet has gone away, avoiding two sheets competing
    /// for presentation during the purchase animation.
    private func completePaidActionIfUnlocked() {
        defer { pendingPaidAction = nil }
        guard purchaseManager.isUnlocked, let pendingPaidAction else { return }

        switch pendingPaidAction {
        case .addConnection:
            showsNewConnection = true
        case .duplicate(let id):
            if let connection = connections.first(where: { $0.id == id }) {
                duplicate(connection)
            }
        }
    }

    /// Copy the configuration but not the secret — a duplicate is usually a different account,
    /// and silently cloning credentials into a second Keychain entry would be surprising.
    private func duplicate(_ connection: Connection) {
        let copy = Connection(name: "\(connection.name) copy", driverID: connection.driverID)
        copy.host = connection.host
        copy.port = connection.port
        copy.database = connection.database
        copy.username = connection.username
        copy.tlsMode = connection.tlsMode
        copy.pinnedCertificatePEM = connection.pinnedCertificatePEM
        copy.certificateFingerprint = connection.certificateFingerprint
        copy.isReadOnly = connection.isReadOnly
        copy.transportMode = connection.transportMode
        copy.socketPath = connection.socketPath
        copy.authenticationMode = connection.authenticationMode
        copy.awsRegion = connection.awsRegion
        copy.sshTunnelEnabled = connection.sshTunnelEnabled
        copy.sshHost = connection.sshHost
        copy.sshPort = connection.sshPort
        copy.sshUsername = connection.sshUsername
        copy.sshAuthenticationMode = connection.sshAuthenticationMode
        copy.fileBookmark = connection.fileBookmark
        copy.fileContainerBookmark = connection.fileContainerBookmark
        copy.fileAccessOwnerDeviceID = connection.fileAccessOwnerDeviceID
        copy.fileAccessOwnerDeviceName = connection.fileAccessOwnerDeviceName
        copy.favoriteColor = connection.favoriteColor
        copy.favoriteTag = connection.favoriteTag
        copy.favoriteGroupID = connection.favoriteGroupID
        copy.favoriteOrder = nextFavoriteOrder(in: connection.favoriteGroupID)
        copy.sortOrder = connection.sortOrder + 1
        modelContext.insert(copy)
        try? modelContext.save()
        editingConnection = copy
    }

    private func delete(_ connection: Connection) {
        if case .connection(let selected) = selection, selected.id == connection.id {
            selection = nil
        }
        try? KeychainSecretStore().delete(for: connection.id)
        modelContext.delete(connection)
        try? modelContext.save()
    }

    private func deleteConnections(at offsets: IndexSet) {
        for index in offsets {
            delete(connections[index])
        }
    }

    private func deleteConnections(_ items: [Connection], at offsets: IndexSet) {
        for index in offsets {
            guard items.indices.contains(index) else { continue }
            delete(items[index])
        }
    }
}

struct ConnectionRow: View {
    let connection: Connection
    var onEdit: (() -> Void)?

    #if os(macOS)
    @State private var isHovering = false
    #endif

    var body: some View {
        HStack(spacing: 4) {
            Label {
                VStack(alignment: .leading) {
                    Text(connection.name.isEmpty ? "Untitled" : connection.name)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } icon: {
                HStack(spacing: 3) {
                    Image(systemName: DriverRegistry.symbol(for: connection.driverID))
                    if connection.favoriteColorValue != .none {
                        Circle()
                            .fill(favoriteColor(for: connection.favoriteColorValue))
                            .frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                    }
                }
            }
            .badge(connection.isReadOnly ? Text(Image(systemName: "lock")) : nil)

            if !connection.favoriteTag.isEmpty || connection.favoriteColorValue != .none {
                Text(favoriteMetadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(favoriteMetadata)
            }

            #if os(macOS)
            // Settings belong to the connection, so the way in sits on the connection's own row
            // rather than in the detail toolbar. Revealed on hover to keep the list quiet.
            if isHovering, let onEdit {
                Spacer(minLength: 4)
                Button("Edit Connection", systemImage: "slider.horizontal.3", action: onEdit)
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
                    .help("Edit this connection's settings")
            }
            #endif
        }
        .opacity(remoteSQLiteOwner == nil ? 1 : 0.65)
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var subtitle: String {
        if let remoteSQLiteOwner, DriverRegistry.style(for: connection.driverID) == .file {
            let filename = (connection.database as NSString).lastPathComponent
            return filename.isEmpty ? "Available on \(remoteSQLiteOwner)" : "\(filename) · Available on \(remoteSQLiteOwner)"
        }
        switch DriverRegistry.style(for: connection.driverID) {
        case .file:
            return (connection.database as NSString).lastPathComponent
        case .httpEndpoint:
            return URL(string: connection.host)?.host() ?? connection.host
        case .server:
            return "\(connection.username)@\(connection.host):\(connection.port)"
        }
    }

    private var remoteSQLiteOwner: String? {
        guard DriverRegistry.style(for: connection.driverID) == .file else { return nil }
        return SQLiteFileAccessRequirement.unavailableOnOtherDeviceOwner(
            path: connection.database,
            ownerDeviceID: connection.fileAccessOwnerDeviceID,
            ownerDeviceName: connection.fileAccessOwnerDeviceName,
            currentDeviceID: DeviceIdentity.identifier
        )
    }

    private var favoriteMetadata: String {
        [
            connection.favoriteColorValue == .none ? nil : connection.favoriteColorValue.title,
            connection.favoriteTag.isEmpty ? nil : "Tag: \(connection.favoriteTag)"
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    private var accessibilityLabel: String {
        let name = connection.name.isEmpty ? "Untitled" : connection.name
        let metadata = favoriteMetadata
        return metadata.isEmpty ? "\(name), \(subtitle)" : "\(name), \(subtitle), \(metadata)"
    }

    private func favoriteColor(for color: FavoriteColor) -> Color {
        switch color {
        case .none: .clear
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .gray: .gray
        }
    }
}

#Preview {
    ContentView(purchaseManager: PurchaseManager())
        .modelContainer(for: [Connection.self, ConnectionFavoriteGroup.self, SavedQuery.self, QueryFavorite.self], inMemory: true)
}
