import SwiftUI

/// Owns the live `DatabaseSession` for one connection and switches between the table browser
/// and the SQL console.
struct ConnectionDetailView: View {
    let connection: Connection

    enum Mode: String, CaseIterable {
        case tables = "Tables"
        case sql = "SQL"
    }

    @State private var session: (any DatabaseSession)?
    @State private var tables: [TableDescriptor] = []
    @State private var selectedTable: TableDescriptor?
    @State private var mode: Mode = .tables
    @State private var connectionError: String?
    @State private var databases: [String] = []
    @State private var activeDatabase: String?
    @State private var isSwitching = false
    @State private var showsEditor = false
    @State private var showsUsers = false
    @State private var canManageUsers = false

    var body: some View {
        Group {
            if let connectionError {
                ContentUnavailableView {
                    Label("Connection Failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(connectionError)
                } actions: {
                    Button("Retry") { Task { await connect() } }
                }
            } else if let session {
                connectedBody(session)
            } else {
                ProgressView("Connecting…")
            }
        }
        .navigationTitle(connection.name)
        .navigationSubtitle(activeDatabase ?? "")
        .sheet(isPresented: $showsEditor) {
            ConnectionFormView(existing: connection)
        }
        .toolbar {
            if !databases.isEmpty {
                ToolbarItem {
                    Picker("Database", selection: databaseBinding) {
                        ForEach(databases, id: \.self) { name in
                            Text(name).tag(Optional(name))
                        }
                    }
                    .disabled(isSwitching)
                }
            }
            // Only shown when the server says this account may actually manage users.
            if canManageUsers {
                ToolbarItem {
                    Button("Users", systemImage: "person.2") { showsUsers = true }
                }
            }
            ToolbarItem {
                Button("Edit Connection", systemImage: "slider.horizontal.3") {
                    showsEditor = true
                }
            }
        }
        .sheet(isPresented: $showsUsers) {
            if let session {
                UserManagementView(session: session, databases: databases)
            }
        }
        .task { await connect() }
        .onDisappear {
            let closing = session
            session = nil
            Task { await closing?.close() }
        }
    }

    @ViewBuilder
    private func connectedBody(_ session: any DatabaseSession) -> some View {
        Group {
            switch session.capabilities.canRunArbitrarySQL ? mode : .tables {
            case .tables:
                TableBrowserView(
                    session: session,
                    connection: connection,
                    tables: tables,
                    selectedTable: $selectedTable
                )
            case .sql:
                SQLConsoleView(session: session, connection: connection)
            }
        }
        .toolbar {
            // Drivers without arbitrary SQL (PostgREST, and any future REST driver) get no
            // console at all, rather than one that fails on every Run.
            if session.capabilities.canRunArbitrarySQL {
                ToolbarItem(placement: .principal) {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
    }

    private var databaseBinding: Binding<String?> {
        Binding(
            get: { activeDatabase },
            set: { newValue in
                guard let newValue, newValue != activeDatabase else { return }
                Task { await switchDatabase(to: newValue) }
            }
        )
    }

    private func connect(overrideDatabase: String? = nil) async {
        connectionError = nil
        guard let driver = DriverRegistry.driver(for: connection.driverID) else {
            connectionError = "Unknown driver “\(connection.driverID)”."
            return
        }

        do {
            let secret = try KeychainSecretStore().secret(for: connection.id)
            restoreFileAccessIfNeeded()

            var config = connection.config
            if let overrideDatabase { config.database = overrideDatabase }

            let newSession = try await driver.connect(config: config, secret: secret)
            session = newSession
            activeDatabase = await newSession.currentDatabase
            databases = (try? await newSession.databases()) ?? []

            // Connecting without a database is legitimate — the user picks one from the list.
            if activeDatabase == nil, let first = databases.first, config.database.isEmpty {
                await switchDatabase(to: first)
                return
            }

            tables = try await newSession.tables()
            selectedTable = tables.first
            canManageUsers = await newSession.userAdmin.isAvailable
        } catch {
            connectionError = error.localizedDescription
        }
    }

    /// Switch in-session where the driver allows it, otherwise reconnect.
    ///
    /// MySQL can `USE` another database on the open connection; PostgreSQL binds a connection to
    /// one database for its lifetime, so reconnecting is the only correct route there.
    private func switchDatabase(to name: String) async {
        guard let session else { return }
        isSwitching = true
        defer { isSwitching = false }

        do {
            try await session.use(database: name)
            activeDatabase = name
            tables = try await session.tables()
            selectedTable = tables.first
        } catch DatabaseError.unsupported {
            let closing = session
            self.session = nil
            await closing.close()
            await connect(overrideDatabase: name)
        } catch {
            connectionError = error.localizedDescription
        }
    }

    /// For file-based connections in the sandbox, re-arm access from the stored bookmark.
    private func restoreFileAccessIfNeeded() {
        #if os(macOS)
        guard let bookmark = connection.fileBookmark else { return }
        var stale = false
        if let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope],
            bookmarkDataIsStale: &stale
        ) {
            // Balanced by process exit; a longer-lived session manager will own this in phase 2.
            _ = url.startAccessingSecurityScopedResource()
            if stale, let fresh = try? url.bookmarkData(options: [.withSecurityScope]) {
                connection.fileBookmark = fresh
            }
        }
        #endif
    }
}
