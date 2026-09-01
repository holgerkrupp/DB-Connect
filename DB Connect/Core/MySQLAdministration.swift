import Foundation

nonisolated enum MySQLProcessVisibility: String, Sendable, Hashable {
    case ownSessions
    case allSessions
}

/// MySQL- and MariaDB-specific admin affordances. Kept separate from the general driver
/// capability flags so MySQL-only features never leak into other drivers' UI.
nonisolated struct MySQLAdminCapability: Sendable, Hashable {
    let canInspectTableMetadata: Bool
    let canViewServerVariables: Bool
    let canViewServerProcesses: Bool
    let canFlushPrivileges: Bool
    let supportsContextualHelp: Bool
    let processVisibility: MySQLProcessVisibility

    static let none = MySQLAdminCapability(
        canInspectTableMetadata: false,
        canViewServerVariables: false,
        canViewServerProcesses: false,
        canFlushPrivileges: false,
        supportsContextualHelp: false,
        processVisibility: .ownSessions
    )

    var showsTableInspector: Bool { canInspectTableMetadata }
    var showsServerAdministration: Bool { canViewServerVariables || canViewServerProcesses || canFlushPrivileges }
    var isAvailable: Bool { showsTableInspector || showsServerAdministration || supportsContextualHelp }
}

nonisolated struct MySQLMetadataField: Identifiable, Hashable, Sendable {
    let label: String
    let value: String

    var id: String { label }
}

nonisolated struct MySQLMetadataSection: Identifiable, Hashable, Sendable {
    let title: String
    let fields: [MySQLMetadataField]

    var id: String { title }
}

nonisolated struct MySQLTableMetadata: Sendable, Hashable {
    let target: GrantTableTarget
    let sections: [MySQLMetadataSection]
}

nonisolated struct MySQLForeignKeyRelation: Identifiable, Hashable, Sendable {
    nonisolated enum Direction: String, Sendable, Hashable {
        case outgoing
        case incoming
    }

    let constraintName: String
    let direction: Direction
    let column: String
    let table: GrantTableTarget
    let referenced: GrantTableTarget
    let referencedColumn: String
    let updateRule: String
    let deleteRule: String

    var id: String { "\(direction.rawValue):\(constraintName):\(column):\(table.id):\(referenced.id):\(referencedColumn)" }
}

nonisolated struct MySQLTriggerInfo: Identifiable, Hashable, Sendable {
    let name: String
    let timing: String
    let event: String
    let body: String
    let definer: String
    let created: String?
    let sqlMode: String?

    var id: String { name }
}

nonisolated struct MySQLServerVariable: Identifiable, Hashable, Sendable {
    let name: String
    let value: String
    let isGlobal: Bool

    var id: String { name }
}

nonisolated struct MySQLProcessInfo: Identifiable, Hashable, Sendable {
    let id: Int64
    let user: String
    let host: String
    let database: String?
    let command: String
    let seconds: Int64
    let state: String?
    let info: String?
}

nonisolated enum MySQLAdminCapabilityResolver {
    static func resolve(from grantLines: [String]) -> MySQLAdminCapability {
        let grants = MySQLGrantParser.parse(grantLines)
        let canSeeAllProcesses = grants.global.contains("PROCESS") || grants.global.contains("SUPER")

        return MySQLAdminCapability(
            canInspectTableMetadata: true,
            canViewServerVariables: true,
            canViewServerProcesses: true,
            canFlushPrivileges: grants.global.contains("RELOAD") || grants.global.contains("SUPER"),
            supportsContextualHelp: false,
            processVisibility: canSeeAllProcesses ? .allSessions : .ownSessions
        )
    }
}
