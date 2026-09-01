import Foundation

nonisolated enum QueryFavoriteExpander {
    static func visibleFavorites(all: [QueryFavorite], for connection: Connection) -> [QueryFavorite] {
        all
            .filter { favorite in
                favorite.connection == nil || favorite.connection?.id == connection.id
            }
            .sorted { lhs, rhs in
                if lhs.scope != rhs.scope {
                    return lhs.scope == .connection
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    static func favorite(matching trigger: String, in favorites: [QueryFavorite]) -> QueryFavorite? {
        guard !trigger.isEmpty else { return nil }
        return favorites.first {
            !$0.tabTrigger.isEmpty && $0.tabTrigger.caseInsensitiveCompare(trigger) == .orderedSame
        }
    }

    static func expand(_ template: String, context: QueryFavoriteContext) -> QueryFavoriteExpansion {
        QueryFavoriteSnippetExpander.expand(template, context: context)
    }
}
