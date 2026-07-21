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
    @State private var showsUsers = false
    @State private var userAdmin: UserAdminCapability = .none
    @State private var schemaAdmin: SchemaAdminCapability = .none
    @State private var showsNewTable = false
    @State private var showsNewDatabase = false
    /// Lives here rather than in the console so an in-progress query survives a trip to the
    /// table browser and back.
    @State private var consoleDraft = ConsoleDraft()

    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    #if os(macOS)
    /// Remembered across launches — a column the user closed should stay closed.
    @AppStorage("detail.showsTableList") private var showsTableList = true
    #endif

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
        .toolbar {
            #if !os(macOS)
            // iOS has no table list column, so the database selector stays in the toolbar.
            // On macOS it lives above the table list — see `TableListView`.
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
            #endif
            // Shown whenever the driver has user management at all, and disabled with an
            // explanation when this particular account may not use it. Hiding it outright left
            // people looking for a feature they could not find.
            if session?.capabilities.supportsUserManagement == true {
                ToolbarItem {
                    Button("Users", systemImage: "person.2") { openUserManager() }
                        .disabled(!userAdmin.isAvailable)
                        .help(userAdmin.isAvailable
                              ? "Manage server accounts"
                              : "This account is not allowed to manage users")
                }
            }
        }
        .sheet(isPresented: $showsUsers) {
            if let session {
                UserManagementView(session: session, databases: databases)
            }
        }
        .sheet(isPresented: $showsNewTable) {
            if let session, let dialect = DriverRegistry.dialect(for: connection.driverID) {
                NewTableView(
                    session: session,
                    dialect: dialect,
                    schema: session.capabilities.supportsSchemas ? selectedTable?.schema : nil
                ) { created in
                    Task { await reloadTables(selecting: created) }
                }
            }
        }
        .sheet(isPresented: $showsNewDatabase) {
            if let session, let dialect = DriverRegistry.dialect(for: connection.driverID) {
                NewDatabaseView(session: session, dialect: dialect, existing: databases) { created in
                    Task {
                        databases = (try? await session.databases()) ?? databases
                        await switchDatabase(to: created)
                    }
                }
            }
        }
        .focusedSceneValue(\.connectionActions, menuActions)
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
            #if os(macOS)
            // A third column beside the connection sidebar. HSplitView rather than a nested
            // NavigationSplitView: the session and its table list are owned here, and nesting
            // navigation split views fights over toolbar placement.
            HSplitView {
                if showsTableList {
                    TableListView(
                        tables: tables,
                        selection: $selectedTable,
                        databases: databases,
                        activeDatabase: databaseBinding,
                        isSwitchingDatabase: isSwitching,
                        schemaAdmin: schemaAdmin,
                        onNewTable: { showsNewTable = true },
                        onNewDatabase: { showsNewDatabase = true }
                    )
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
                }
                pane(session)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            // Without this the split view sizes to its content's ideal width and sits centred,
            // leaving a gap beside the connection sidebar in SQL mode.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #else
            pane(session)
            #endif
        }
        .toolbar {
            #if os(macOS)
            ToolbarItem {
                Button("Tables", systemImage: "sidebar.squares.left") {
                    withAnimation { showsTableList.toggle() }
                }
                .help(showsTableList ? "Hide the table list" : "Show the table list")
            }
            #endif
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

    /// The main working area: browser or console, depending on mode.
    @ViewBuilder
    private func pane(_ session: any DatabaseSession) -> some View {
        switch session.capabilities.canRunArbitrarySQL ? mode : .tables {
        case .tables:
            TableBrowserView(
                session: session,
                connection: connection,
                tables: tables,
                selectedTable: $selectedTable,
                showsTablePicker: !usesTableListColumn
            )
        case .sql:
            SQLConsoleView(session: session, connection: connection, draft: consoleDraft)
        }
    }

    /// Whether the table list is shown as its own column rather than as a picker in the browser.
    private var usesTableListColumn: Bool {
        #if os(macOS)
        showsTableList
        #else
        false
        #endif
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

    /// Whether the rich, windowed account manager applies: a driver that models the full
    /// privilege set, on a platform that can open a second window. Otherwise the simpler sheet
    /// (`UserManagementView`) is used — iPhone, or drivers without granular privileges.
    private var usesUserAdminWindow: Bool {
        supportsMultipleWindows && (session?.capabilities.supportsGranularPrivileges ?? false)
    }

    private func openUserManager() {
        if usesUserAdminWindow {
            openWindow(id: UserAdminWindow.sceneID, value: connection.id)
        } else {
            showsUsers = true
        }
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
            consoleDraft.reset(for: activeDatabase ?? connection.database)
            databases = (try? await newSession.databases()) ?? []

            // User management is a server-wide privilege, not a per-database one, so probe it
            // here — before the early return below. Connecting without a default database (as a
            // server-level admin does) took the early-return path and left this at `.none`,
            // which disabled the Users button for accounts that can in fact manage users.
            userAdmin = await newSession.userAdmin

            // Connecting without a database is legitimate — the user picks one from the list.
            if activeDatabase == nil, let first = databases.first, config.database.isEmpty {
                await switchDatabase(to: first)
                return
            }

            tables = try await newSession.tables()
            selectedTable = tables.first
            schemaAdmin = await newSession.schemaAdmin
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
            // Results and cached schema came from the old database; the query text is kept,
            // since it is the user's own writing.
            consoleDraft.reset(for: name)
            tables = try await session.tables()
            selectedTable = tables.first
            // Schema privileges are commonly granted per database, so what the user may do here
            // is not what they could do in the database they just left.
            schemaAdmin = await session.schemaAdmin
        } catch DatabaseError.unsupported {
            let closing = session
            self.session = nil
            await closing.close()
            await connect(overrideDatabase: name)
        } catch {
            connectionError = error.localizedDescription
        }
    }

    /// What the menu bar may do while this connection is open. Nil until the session is live,
    /// which is what greys the whole set out during connect and after a failure.
    private var menuActions: ConnectionActions? {
        guard let session else { return nil }
        return ConnectionActions(
            mode: session.capabilities.canRunArbitrarySQL ? mode : .tables,
            setMode: { mode = $0 },
            canRunSQL: session.capabilities.canRunArbitrarySQL,
            databases: databases,
            activeDatabase: activeDatabase,
            switchDatabase: { name in Task { await switchDatabase(to: name) } },
            // Nil rather than present-but-disabled where the account may not do it, so the menu
            // item greys out through the same path as "no connection open".
            newTable: schemaAdmin.canCreateTable ? { showsNewTable = true } : nil,
            newDatabase: schemaAdmin.canCreateDatabase ? { showsNewDatabase = true } : nil,
            manageUsers: session.capabilities.supportsUserManagement && userAdmin.isAvailable
                ? { openUserManager() } : nil,
            reloadSchema: { Task { await reloadTables() } },
            reconnect: reconnect,
            isTableListShown: tableListIsShown,
            toggleTableList: toggleTableList
        )
    }

    /// No table list column outside macOS, so these are inert there.
    private var tableListIsShown: Bool {
        #if os(macOS)
        showsTableList
        #else
        false
        #endif
    }

    private func toggleTableList() {
        #if os(macOS)
        withAnimation { showsTableList.toggle() }
        #endif
    }

    /// Tear the session down and dial again — the manual counterpart to the Retry button that
    /// appears after a failure, for when a connection has gone stale rather than failed outright.
    private func reconnect() {
        let closing = session
        session = nil
        Task {
            await closing?.close()
            await connect()
        }
    }

    /// Re-read the schema, optionally selecting a table by name once it appears.
    private func reloadTables(selecting name: String? = nil) async {
        guard let session else { return }
        guard let refreshed = try? await session.tables() else { return }
        tables = refreshed
        if let name, let match = refreshed.first(where: { $0.name == name }) {
            selectedTable = match
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
