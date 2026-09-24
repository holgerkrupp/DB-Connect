import SwiftUI
import SwiftData

struct ContentView: View {
    let purchaseManager: PurchaseManager

    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Connection.sortOrder), SortDescriptor(\Connection.createdAt)])
    private var connections: [Connection]
    @Query private var savedQueries: [SavedQuery]

    @Environment(\.appNavigation) private var navigation
    @Environment(\.monitorScheduler) private var scheduler

    @State private var selection: SidebarItem?
    @State private var showsNewConnection = false
    @State private var showsPaywall = false
    @State private var pendingPaidAction: PaidAction?
    @State private var editingConnection: Connection?
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
        NavigationSplitView {
            List(selection: $selection) {
                Section("Connections") {
                    ForEach(connections) { connection in
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
                                // Only meaningful for the connection that is actually open.
                                if selectedConnection?.id == connection.id {
                                    Button("Close Connection", systemImage: "xmark.circle") {
                                        selection = nil
                                    }
                                }
                                Divider()
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    delete(connection)
                                }
                            }
                            .swipeActions(edge: .leading) {
                                Button("Edit", systemImage: "pencil") {
                                    editingConnection = connection
                                }
                                .tint(.blue)
                            }
                    }
                    .onDelete(perform: deleteConnections)
                }

                Section {
                    Label("Monitors", systemImage: "bell.badge")
                        .tag(SidebarItem.monitors)
                }
            }
            .navigationTitle("Connections")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Add Connection", systemImage: "plus") {
                        requestNewConnection()
                    }
                    .help("Add a database connection")
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
            .safeAreaBar(edge: .bottom) {
                SyncStatusView()
                    .bottomBar()
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
            ConnectionFormView(purchaseManager: purchaseManager)
        }
        .sheet(item: $editingConnection) { connection in
            ConnectionFormView(purchaseManager: purchaseManager, existing: connection)
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
                Image(systemName: DriverRegistry.symbol(for: connection.driverID))
            }
            .badge(connection.isReadOnly ? Text(Image(systemName: "lock")) : nil)

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
}

#Preview {
    ContentView(purchaseManager: PurchaseManager())
        .modelContainer(for: [Connection.self, SavedQuery.self, QueryFavorite.self], inMemory: true)
}
