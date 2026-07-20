import Foundation

/// The one place that knows which drivers exist. Adding a driver means adding one line here.
nonisolated enum DriverRegistry {
    static let all: [any DatabaseDriver] = [
        SQLiteDriver(),
        MySQLDriver(),
        PostgresDriver(),
        SupabaseDriver()
    ]

    static func driver(for id: String) -> (any DatabaseDriver)? {
        all.first { type(of: $0).id == id }
    }

    static func displayName(for id: String) -> String {
        all.first { type(of: $0).id == id }.map { type(of: $0).displayName } ?? id
    }

    /// How the connection form should present a driver — the shape of its config, not its wire protocol.
    enum ConnectionStyle {
        /// A local file chosen by the user.
        case file
        /// Host, port, database, username, password.
        case server
        /// A project URL plus an API key.
        case httpEndpoint
    }

    static func style(for id: String) -> ConnectionStyle {
        switch id {
        case SQLiteDriver.id: .file
        case SupabaseDriver.id: .httpEndpoint
        default: .server
        }
    }

    static func defaultPort(for id: String) -> Int {
        switch id {
        case PostgresDriver.id: PostgresDriver.defaultPort
        case MySQLDriver.id: MySQLDriver.defaultPort
        default: 0
        }
    }

    static func symbol(for id: String) -> String {
        switch id {
        case SQLiteDriver.id: "internaldrive"
        case SupabaseDriver.id: "bolt.horizontal.circle"
        default: "server.rack"
        }
    }
}
