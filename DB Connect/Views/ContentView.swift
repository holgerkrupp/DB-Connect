import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Connection.sortOrder), SortDescriptor(\Connection.createdAt)])
    private var connections: [Connection]

    @State private var selection: SidebarItem?
    @State private var showsNewConnection = false
    @State private var editingConnection: Connection?

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
                        ConnectionRow(connection: connection)
                            .tag(SidebarItem.connection(connection))
                            .contextMenu {
                                Button("Edit…", systemImage: "pencil") {
                                    editingConnection = connection
                                }
                                Button("Duplicate", systemImage: "plus.square.on.square") {
                                    duplicate(connection)
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
            }
            .safeAreaInset(edge: .bottom) {
                SyncStatusView()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
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

    var body: some View {
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
