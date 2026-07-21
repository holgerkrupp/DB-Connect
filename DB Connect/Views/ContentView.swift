import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Connection.sortOrder), SortDescriptor(\Connection.createdAt)])
    private var connections: [Connection]

    @State private var selection: SidebarItem?
    @State private var showsNewConnection = false
    @State private var editingConnection: Connection?
    /// A menu item is far easier to hit by accident than a context menu, and deleting a
    /// connection also drops its Keychain entry, so the menu route confirms first.
    @State private var connectionToDelete: Connection?
    #if os(iOS)
    @State private var showsSettings = false
    #endif

    /// The sidebar mixes connections with the monitors section, so selection needs one type.
    enum SidebarItem: Hashable {
        case connection(Connection)
        case monitors
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
                                    duplicate(connection)
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
            .navigationTitle("DB Connect")
            .toolbar {
                ToolbarItem {
                    Button("Add Connection", systemImage: "plus") {
                        showsNewConnection = true
                    }
                }
                #if os(iOS)
                // macOS gets the standard Settings window from the app menu instead.
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gearshape") {
                        showsSettings = true
                    }
                }
                #endif
            }
            .safeAreaInset(edge: .bottom) {
                SyncStatusView()
                    .bottomBar()
            }
        } detail: {
            switch selection {
            case .connection(let connection):
                ConnectionDetailView(connection: connection)
                    .id(connection.id)   // rebuild sessions when switching connections
            case .monitors:
                MonitorsView()
            case nil:
                ContentUnavailableView("Select a Connection", systemImage: "cylinder.split.1x2")
            }
        }
        .sheet(isPresented: $showsNewConnection) {
            ConnectionFormView()
        }
        .sheet(item: $editingConnection) { connection in
            ConnectionFormView(existing: connection)
        }
        .confirmationDialog(
            "Delete “\(connectionToDelete?.name ?? "")”?",
            isPresented: .constant(connectionToDelete != nil),
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
            newConnection: { showsNewConnection = true },
            editSelected: selectedConnection.map { connection in
                { editingConnection = connection }
            },
            duplicateSelected: selectedConnection.map { connection in
                { duplicate(connection) }
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
        #if os(iOS)
        .sheet(isPresented: $showsSettings) {
            SettingsSheet()
        }
        #endif
    }

    /// The connection the menu commands act on. Nil while the Monitors section is selected,
    /// which is what greys those items out.
    private var selectedConnection: Connection? {
        if case .connection(let connection) = selection { return connection }
        return nil
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
            let connection = connections[index]
            try? KeychainSecretStore().delete(for: connection.id)
            modelContext.delete(connection)
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
        #if os(macOS)
        .onHover { isHovering = $0 }
        #endif
    }

    private var subtitle: String {
        switch DriverRegistry.style(for: connection.driverID) {
        case .file:
            (connection.database as NSString).lastPathComponent
        case .httpEndpoint:
            URL(string: connection.host)?.host() ?? connection.host
        case .server:
            "\(connection.username)@\(connection.host):\(connection.port)"
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Connection.self, SavedQuery.self], inMemory: true)
}
