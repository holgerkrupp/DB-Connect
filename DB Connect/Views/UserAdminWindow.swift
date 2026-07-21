import SwiftUI
import SwiftData

/// Hosts `UserAdminView` in its own window (Mac and iPad).
///
/// A live `DatabaseSession` is an actor and cannot be handed across SwiftUI scenes, so the window
/// receives only the connection's stable `UUID` and opens its *own* session from the saved config
/// and keychain secret — the same path `ConnectionDetailView` uses. This is a second connection to
/// the server, independent of the one backing the main window, and it is closed when the window
/// goes away.
struct UserAdminWindow: View {
    /// Scene identifier shared between the `WindowGroup` declaration and the `openWindow` call.
    static let sceneID = "user-admin"

    let connectionID: UUID?

    @Environment(\.modelContext) private var modelContext

    @State private var session: (any DatabaseSession)?
    @State private var databases: [String] = []
    @State private var windowTitle = "Users"
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let session {
                UserAdminView(session: session, databases: databases, title: windowTitle)
            } else if let errorMessage {
                ContentUnavailableView {
                    Label("Cannot Open User Manager", systemImage: "person.slash")
                } description: {
                    Text(errorMessage)
                } actions: {
                    Button("Retry") { Task { await connect() } }
                }
            } else {
                ProgressView("Connecting…")
            }
        }
        #if os(macOS)
        .frame(minWidth: 780, minHeight: 520)
        #endif
        .task(id: connectionID) { await connect() }
        .onDisappear {
            let closing = session
            session = nil
            Task { await closing?.close() }
        }
    }

    private func connect() async {
        errorMessage = nil
        guard let connectionID, let connection = fetchConnection(connectionID) else {
            errorMessage = "This connection is no longer available."
            return
        }
        guard let driver = DriverRegistry.driver(for: connection.driverID) else {
            errorMessage = "Unknown driver “\(connection.driverID)”."
            return
        }
        windowTitle = connection.name
        do {
            let secret = try KeychainSecretStore().secret(for: connection.id)
            let newSession = try await driver.connect(config: connection.config, secret: secret)
            databases = (try? await newSession.databases()) ?? []
            session = newSession
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func fetchConnection(_ id: UUID) -> Connection? {
        let descriptor = FetchDescriptor<Connection>(predicate: #Predicate { $0.id == id })
        return try? modelContext.fetch(descriptor).first
    }
}
