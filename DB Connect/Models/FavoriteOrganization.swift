import Foundation

/// The optional color marker shown next to a favorite. The raw value is persisted rather than
/// the platform `Color`, keeping the CloudKit record portable across Apple platforms.
nonisolated enum FavoriteColor: String, Sendable, Hashable, CaseIterable, Identifiable {
    case none
    case red
    case orange
    case yellow
    case green
    case blue
    case purple
    case pink
    case gray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: "No Color"
        case .red: "Red"
        case .orange: "Orange"
        case .yellow: "Yellow"
        case .green: "Green"
        case .blue: "Blue"
        case .purple: "Purple"
        case .pink: "Pink"
        case .gray: "Gray"
        }
    }
}

/// Search input is kept as a value type so filtering can be tested without opening SwiftData.
/// `range(of:options:locale:)` gives users case- and diacritic-insensitive, locale-aware search.
nonisolated struct FavoriteSearchFields: Sendable, Equatable {
    var name: String
    var host: String
    var username: String
    var database: String
    var driver: String
    var tag: String
    var group: String

    init(
        name: String = "",
        host: String = "",
        username: String = "",
        database: String = "",
        driver: String = "",
        tag: String = "",
        group: String = ""
    ) {
        self.name = name
        self.host = host
        self.username = username
        self.database = database
        self.driver = driver
        self.tag = tag
        self.group = group
    }

    func matches(_ query: String, locale: Locale = .current) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return [name, host, username, database, driver, tag, group].contains { value in
            value.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: locale
            ) != nil
        }
    }
}

/// Stable ordering used by the launcher. Existing records have `favoriteOrder == 0`, so their
/// legacy `sortOrder`/creation order remains intact until the user explicitly reorders a group.
nonisolated struct FavoriteOrderingKey: Sendable, Equatable {
    var favoriteOrder: Int
    var legacyOrder: Int
    var createdAt: Date
    var stableID: String

    static func orderedBefore(_ lhs: Self, _ rhs: Self) -> Bool {
        switch (lhs.favoriteOrder, rhs.favoriteOrder) {
        case (0, 0):
            break
        case (0, _):
            return false
        case (_, 0):
            return true
        default:
            if lhs.favoriteOrder != rhs.favoriteOrder {
                return lhs.favoriteOrder < rhs.favoriteOrder
            }
        }

        if lhs.legacyOrder != rhs.legacyOrder {
            return lhs.legacyOrder < rhs.legacyOrder
        }
        if lhs.createdAt != rhs.createdAt {
            return lhs.createdAt < rhs.createdAt
        }
        return lhs.stableID < rhs.stableID
    }
}

nonisolated enum FavoriteGroupSemantics {
    /// Group deletion only clears the membership reference; the favorite record remains intact.
    static func groupID(afterRemoving removedGroupID: UUID, from connectionGroupID: UUID?) -> UUID? {
        connectionGroupID == removedGroupID ? nil : connectionGroupID
    }
}
