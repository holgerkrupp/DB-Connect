import SwiftUI

enum WorkspaceMode: String, CaseIterable {
    case tables = "Tables"
    case sql = "SQL"
}

struct WorkspaceModePicker: View {
    @Binding var selection: WorkspaceMode
    var compact = false

    var body: some View {
        Picker("Workspace", selection: $selection) {
            ForEach(WorkspaceMode.allCases, id: \.self) { Text($0.rawValue) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(
            minWidth: compact ? 100 : 150,
            idealWidth: compact ? 110 : 190,
            maxWidth: compact ? 120 : 220
        )
    }
}

/// Owns the live `DatabaseSession` for one connection and switches between the table browser
/// and the SQL console.
struct ConnectionDetailView: View {
    typealias Mode = WorkspaceMode

    let connection: Connection

    @State private var session: (any DatabaseSession)?
    @State private var tables: [TableDescriptor] = []
    @State private var selectedTable: TableDescriptor?
    @State private var mode: WorkspaceMode = .tables
    @State private var connectionError: String?
    @State private var databases: [String] = []
    @State private var activeDatabase: String?
    @State private var isSwitching = false
    @State private var showsUsers = false
    @State private var userAdmin: UserAdminCapability = .none
    @State private var schemaAdmin: SchemaAdminCapability = .none
    @State private var showsNewTable = false
    @State private var showsNewDatabase = false
    @State private var transferOperation: TransferOperation?
    @State private var isConnecting = false
    @State private var isLoadingSchema = false
    /// Invalidates an older async connection attempt when the user retries or leaves the view.
    @State private var connectionAttemptID = UUID()
    /// Lives here rather than in the console so an in-progress query survives a trip to the
    /// table browser and back.
    @State private var consoleDraft = ConsoleDraft()

    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.appNavigation) private var navigation
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
                    Button("Retry") { connectIfNeeded() }
                }
            } else if let session {
                connectedBody(session)
            } else {
                ProgressView("Connecting…")
            }
        }
        .navigationTitle(connection.name)
        .navigationSubtitle(activeDatabase ?? "")
        #if os(iOS)
        .navigationBarTitleDisplayMode(horizontalSizeClass == .compact ? .inline : .automatic)
        #endif
        .toolbar {
            #if os(macOS)
            if let session {
                ToolbarItem {
                    Button("Tables", systemImage: "sidebar.squares.left") {
                        withAnimation { showsTableList.toggle() }
                    }
                    .help(showsTableList ? "Hide the table list" : "Show the table list")
                }
                ToolbarSpacer(.flexible)
                ToolbarItemGroup {
                    serverControlItems(for: session)
                }
                ToolbarSpacer(.fixed)
                
                ToolbarItemGroup(placement: .primaryAction) {
                    modePicker(for: session)
                        .frame(width: 160)
                }
            }
            #else
            if horizontalSizeClass == .compact, let session {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Group {
                        serverControlItems(for: session)
                    }
                    .labelStyle(.iconOnly)
                }
            }
            #endif
        }
        .sheet(isPresented: $showsUsers) {
            if let session {
                if session.capabilities.supportsGranularPrivileges {
                    UserAdminView(
                        session: session,
                        databases: databases,
                        title: connection.name,
                        onDismiss: { showsUsers = false }
                    )
                } else {
                    UserManagementView(session: session, databases: databases)
                }
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
        .sheet(item: $transferOperation) { operation in
            if let session {
                DataTransferView(
                    session: session,
                    dialect: DriverRegistry.dialect(for: connection.driverID),
                    database: activeDatabase ?? connection.database,
                    tables: tables,
                    selectedTable: selectedTable,
                    initialOperation: operation,
                    canImport: !connection.isReadOnly
                        && session.capabilities.canRunArbitrarySQL
                        && DriverRegistry.dialect(for: connection.driverID) != nil,
                    canCreateTable: !connection.isReadOnly && schemaAdmin.canCreateTable,
                    onSchemaChange: { Task { await reloadTables() } }
                )
            }
        }
        .focusedSceneValue(\.connectionActions, menuActions)
        // Compact NavigationSplitView can retain the detail when Back merely hides it. Start
        // explicitly on every appearance because a completed `.task` is not reliably restarted
        // when that retained detail is shown again.
        .onAppear {
            connectIfNeeded()
            applyNavigationRequest()
        }
        .onChange(of: navigation.request?.id) { _, _ in applyNavigationRequest() }
        .onDisappear {
            connectionAttemptID = UUID()
            isConnecting = false
            isLoadingSchema = false
            let closing = session
            session = nil
            Task { await closing?.close() }
        }
    }

    private func applyNavigationRequest() {
        guard let request = navigation.request,
              case .savedQuery(let queryID) = request.destination,
              let query = (connection.savedQueries ?? []).first(where: { $0.id == queryID })
        else { return }

        consoleDraft.sql = query.sql
        mode = .sql
        navigation.consume(request.id)
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
                        schemaAdmin: schemaAdmin,
                        onNewTable: { showsNewTable = true }
                    )
                    .frame(minWidth: 220, idealWidth: 280, maxWidth: 400)
                }
                workspacePane(session)
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
            // Without this the split view sizes to its content's ideal width and sits centred,
            // leaving a gap beside the connection sidebar in SQL mode.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #else
            workspacePane(session)
            #endif
        }
    }

    /// Keeps workspace controls with the pane they affect. On macOS the table list is a sibling
    /// column and therefore retains its own unobstructed filter; on compact devices this same
    /// container naturally fills the pushed detail screen.
    @ViewBuilder
    private func workspacePane(_ session: any DatabaseSession) -> some View {
        #if os(macOS)
        pane(session)
        #else
        VStack(spacing: 0) {
            workspaceBar(session)
            pane(session)
        }
        #endif
    }

    /// Compact navigation bars host both the connection actions and mode selector. Regular-width
    /// layouts keep their larger controls in this dedicated strip.
    @ViewBuilder
    private func workspaceBar(_ session: any DatabaseSession) -> some View {
        if horizontalSizeClass != .compact {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    modePicker(for: session)
                    Spacer(minLength: 8)
                    serverControls(for: session)
                        .buttonStyle(.glass)
                }

                VStack(spacing: 8) {
                    modePicker(for: session)
                        .frame(maxWidth: .infinity)
                    HStack(spacing: 12) {
                        Spacer(minLength: 0)
                        serverControls(for: session)
                            .buttonStyle(.glass)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func modePicker(for session: any DatabaseSession) -> some View {
        // Drivers without arbitrary SQL (PostgREST, and any future REST driver) get no console
        // selector at all, rather than one whose SQL pane fails on every Run.
        if session.capabilities.canRunArbitrarySQL {
            WorkspaceModePicker(selection: $mode)
        }
    }

    private func serverControls(for session: any DatabaseSession) -> some View {
        HStack(spacing: 8) {
            serverControlItems(for: session)
        }
    }

    /// Individual siblings so macOS can place each control natively in a `ToolbarItemGroup`.
    /// The inline compact layout wraps these same views in the `HStack` above.
    @ViewBuilder
    private func serverControlItems(for session: any DatabaseSession) -> some View {
        if !databases.isEmpty {
            Picker(selection: databaseBinding) {
                ForEach(databases, id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            } label: {
                Label(activeDatabase ?? "Database", systemImage: "cylinder.split.1x2")
                    .lineLimit(1)
            }
            .pickerStyle(.menu)
            .disabled(isSwitching)

            if isSwitching {
                ProgressView()
            }
        }



        Menu("Connection Actions", systemImage: "ellipsis.circle") {
            Button("Import Data…", systemImage: "square.and.arrow.down") {
                transferOperation = .import
            }
            .disabled(connection.isReadOnly || !session.capabilities.canRunArbitrarySQL)
            Button("Export Data…", systemImage: "square.and.arrow.up") {
                transferOperation = .export
            }
            .disabled(tables.isEmpty)
            Divider()
            if schemaAdmin.canCreateTable {
                Button("New Table", systemImage: "tablecells.badge.ellipsis") {
                    showsNewTable = true
                }
            }
            if schemaAdmin.canCreateDatabase {
                Button("New Database", systemImage: "cylinder.split.1x2") {
                    showsNewDatabase = true
                }
            }
            if schemaAdmin.canCreateTable || schemaAdmin.canCreateDatabase {
                Divider()
            }
            // Show the capability even when this account cannot use it; the disabled button's
            // help explains why the feature is unavailable.
            if session.capabilities.supportsUserManagement {
                Button("Users", systemImage: "person.2") { openUserManager() }
                    //.labelStyle(.iconOnly)
                    .disabled(!userAdmin.isAvailable)
                    .help(userAdmin.isAvailable
                          ? "Manage server accounts"
                          : "This account is not allowed to manage users")
            }
            Button("Reload Schema", systemImage: "arrow.clockwise") {
                Task { await reloadTables() }
            }
            Button("Reconnect", systemImage: "bolt.horizontal.circle") {
                reconnect()
            }
        }
        .labelStyle(.iconOnly)
    }

    /// The main working area: browser or console, depending on mode.
    @ViewBuilder
    private func pane(_ session: any DatabaseSession) -> some View {
        Group {
            if isLoadingSchema {
                ProgressView("Loading schema…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch session.capabilities.canRunArbitrarySQL ? mode : .tables {
                case .tables:
                    TableBrowserView(
                        session: session,
                        connection: connection,
                        tables: tables,
                        selectedTable: $selectedTable,
                        workspaceMode: $mode,
                        showsWorkspaceModePicker: horizontalSizeClass == .compact
                            && session.capabilities.canRunArbitrarySQL,
                        showsTablePicker: !usesTableListColumn
                    )
                case .sql:
                    SQLConsoleView(
                        session: session,
                        connection: connection,
                        draft: consoleDraft,
                        workspaceMode: $mode,
                        showsWorkspaceModePicker: horizontalSizeClass == .compact
                    )
                }
            }
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

    /// A granular account manager gets its own window where the device supports that. On a
    /// single-window device the same manager is presented in the sheet configured above; only
    /// drivers without granular privileges use the simpler `UserManagementView`.
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

    private func connectIfNeeded() {
        guard session == nil, !isConnecting else { return }
        isConnecting = true
        Task { await connect() }
    }

    private func connect(overrideDatabase: String? = nil) async {
        let attemptID = UUID()
        connectionAttemptID = attemptID
        isConnecting = true
        defer {
            if connectionAttemptID == attemptID {
                isConnecting = false
            }
        }
        connectionError = nil
        isLoadingSchema = false

        // Retry can be offered after schema discovery fails, by which point a database session
        // already exists. Never replace that session without first closing it.
        let previousSession = session
        session = nil
        await previousSession?.close()

        guard connectionAttemptID == attemptID else { return }
        guard let driver = DriverRegistry.driver(for: connection.driverID) else {
            connectionError = "Unknown driver “\(connection.driverID)”."
            return
        }

        var candidate: (any DatabaseSession)?
        do {
            let secret = try KeychainSecretStore().secret(for: connection.id)
            restoreFileAccessIfNeeded()

            var config = connection.config
            if let overrideDatabase { config.database = overrideDatabase }

            let newSession = try await driver.connect(config: config, secret: secret)
            candidate = newSession
            guard connectionAttemptID == attemptID else {
                await newSession.close()
                return
            }

            // A completed handshake is a live connection. Publish it now instead of leaving the
            // UI on “Connecting…” while the app runs several schema and privilege queries.
            session = newSession
            isLoadingSchema = true

            // MySQLNIO's socket connect has a deadline, but a server can accept the socket and
            // then stop answering discovery queries. Bound that phase and close the channel so
            // the in-flight query is released rather than leaving the UI spinning indefinitely.
            let schemaTimeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, connectionAttemptID == attemptID else { return }
                connectionAttemptID = UUID()
                session = nil
                isConnecting = false
                isLoadingSchema = false
                connectionError = "The server connected, but did not return its schema within 20 seconds. Check the network and try again."
                await newSession.close()
            }
            defer { schemaTimeout.cancel() }

            var resolvedDatabase = await newSession.currentDatabase
            let resolvedDatabases = (try? await newSession.databases()) ?? []

            // User management is a server-wide privilege, not a per-database one, so probe it
            // here — before the early return below. Connecting without a default database (as a
            // server-level admin does) took the early-return path and left this at `.none`,
            // which disabled the Users button for accounts that can in fact manage users.
            let resolvedUserAdmin = await newSession.userAdmin

            // Connecting without a database is legitimate — the user picks one from the list.
            if resolvedDatabase == nil,
               let first = resolvedDatabases.first,
               config.database.isEmpty {
                do {
                    try await newSession.use(database: first)
                    resolvedDatabase = first
                } catch DatabaseError.unsupported {
                    // PostgreSQL binds the database at connect time, so replace this temporary
                    // session with one configured for the selected database.
                    session = nil
                    isLoadingSchema = false
                    await newSession.close()
                    candidate = nil
                    guard connectionAttemptID == attemptID else { return }
                    await connect(overrideDatabase: first)
                    return
                }
            }

            let resolvedTables = try await newSession.tables()
            let resolvedSchemaAdmin = await newSession.schemaAdmin

            // The view may have disappeared, or a newer Retry may have started, during any of
            // the awaits above. In that case this attempt still owns its candidate and closes it.
            guard connectionAttemptID == attemptID else {
                await newSession.close()
                return
            }

            candidate = nil
            activeDatabase = resolvedDatabase
            consoleDraft.reset(for: resolvedDatabase ?? connection.database)
            databases = resolvedDatabases
            userAdmin = resolvedUserAdmin
            tables = resolvedTables
            selectedTable = resolvedTables.first
            schemaAdmin = resolvedSchemaAdmin
            isLoadingSchema = false
        } catch {
            if connectionAttemptID == attemptID {
                session = nil
                isLoadingSchema = false
            }
            await candidate?.close()
            guard connectionAttemptID == attemptID else { return }
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
            importData: !connection.isReadOnly
                && session.capabilities.canRunArbitrarySQL
                && DriverRegistry.dialect(for: connection.driverID) != nil
                ? { transferOperation = .import } : nil,
            exportData: tables.isEmpty ? nil : { transferOperation = .export },
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
        connectionAttemptID = UUID()
        isLoadingSchema = false
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
        let previousID = selectedTable?.id
        tables = refreshed
        if let name, let match = refreshed.first(where: { $0.name == name }) {
            selectedTable = match
        } else if let previousID,
                  let previous = refreshed.first(where: { $0.id == previousID }) {
            selectedTable = previous
        } else {
            selectedTable = refreshed.first
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
