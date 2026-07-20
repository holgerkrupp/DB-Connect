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

    private func connect() async {
        connectionError = nil
        guard let driver = DriverRegistry.driver(for: connection.driverID) else {
            connectionError = "Unknown driver “\(connection.driverID)”."
            return
        }

        do {
            let secret = try KeychainSecretStore().secret(for: connection.id)
            restoreFileAccessIfNeeded()
            let newSession = try await driver.connect(config: connection.config, secret: secret)
            session = newSession
            tables = try await newSession.tables()
            if selectedTable == nil { selectedTable = tables.first }
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
