import Foundation

/// The small, non-secret portion of the macOS launcher that is safe to restore between launches.
/// It deliberately contains no draft fields or credentials.
nonisolated enum LauncherSelectionState: Hashable, Sendable {
    case quickConnect
    case favorite(UUID)
    case monitors
}

nonisolated enum LauncherStateRestoration {
    static func encode(_ selection: LauncherSelectionState?) -> String {
        guard let selection else { return "quickConnect" }
        switch selection {
        case .quickConnect: return "quickConnect"
        case .monitors: return "monitors"
        case .favorite(let id): return "favorite:\(id.uuidString)"
        }
    }

    static func decode(_ rawValue: String, availableFavoriteIDs: Set<UUID>) -> LauncherSelectionState {
        switch rawValue {
        case "monitors": return .monitors
        case "quickConnect": return .quickConnect
        default:
            let prefix = "favorite:"
            guard rawValue.hasPrefix(prefix),
                  let id = UUID(uuidString: String(rawValue.dropFirst(prefix.count))),
                  availableFavoriteIDs.contains(id) else { return .quickConnect }
            return .favorite(id)
        }
    }

    /// A saved favorite may use its Keychain secret when no secret was entered in the editor.
    /// Any typed value is runtime-only until the user explicitly saves the favorite.
    static func usesRuntimeSecret(selection: LauncherSelectionState?, hasTypedSecret: Bool) -> Bool {
        guard !hasTypedSecret else { return true }
        if case .favorite = selection { return false }
        return true
    }
}
