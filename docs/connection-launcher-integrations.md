# Connection and launcher integration decisions

This is the integration record for the current DB Connect connection model and
macOS launcher. The supported product is the native macOS and iPhone/iPad app
plus the existing WidgetKit extension. No watchOS target or new system
capability is added by this document.

The integration boundary is deliberate: connection definitions and other
durable records use a local SwiftData store; credentials stay in Keychain;
transient Quick Connect and Vault lease values stay in memory. CloudKit is an
optional future sync integration and is not part of launch or normal operation.
Stable UUIDs and `AppNavigation` are shared by app, widget, Spotlight, and
App Intent entry points.

| Area | Decision | Privacy and behavior boundary |
| --- | --- | --- |
| Spotlight | **Keep the existing index** for saved queries and monitors. | Index only user-recognizable titles/status metadata through the existing App Entities and centralized routes. Do not index connection hosts, usernames, SQL text, result rows, or credentials. Reindex after changes and remove stale entries. |
| App Intents / Shortcuts | **Keep the existing intents** for opening saved queries/monitors and explicitly running or enabling monitors. | Use the SwiftData UUID as the stable entity identifier and revalidate it at execution time. Do not automate Quick Connect or expose credentials: connecting is a sensitive, foreground workflow. |
| Widgets | **Keep the existing monitor and saved-query widgets.** | The App Group snapshot is a cache, not a second source of truth. It carries titles, connection labels, and monitor status, but not credentials, hosts, usernames, SQL, or result sets. Error text must remain sanitized before it reaches a widget or lock screen. |
| Deep links | **Keep the existing `db-connect://` scheme** and typed `AppNavigation` parser. | Query, monitor, and run-monitor routes use UUIDs, reject malformed input, and remain pending until the destination is available. There is no verified web domain, so Universal Links are not added; URL opening never silently connects or performs destructive work. |
| Transferable / ShareLink | **No new connection sharing surface.** | A connection definition is a private endpoint and its secret is a separate credential. Sharing/exporting it by default would make accidental disclosure too easy. Existing copy/paste and standard file import flows remain available where they are useful, with incoming data treated as untrusted. |
| Handoff | **Not added.** | Scene restoration covers local continuity. CloudKit sync is not required, and there is no useful secure Handoff payload for a transient password, SSH key, or Vault lease. |
| Notifications | **Keep monitor notifications.** | Permission is requested in the monitor workflow, with user-controlled templates and throttling. Notification actions should carry only a route/UUID and revalidate state in the app; notification text must not include credentials or unnecessary query/result data. Live Activities are not added because periodic database checks are not a finite, continuously changing activity. |
| Files / Finder / Quick Look | **Use existing importers and security-scoped bookmarks** for SQLite databases, certificates, and SSH keys. | Files are inputs to app-owned records, not an accidental document format. Validate type, access, and lifetime; keep bookmarks device-specific. No document type, Open With registration, or Quick Look extension is added until a portable DB Connect document has a real user workflow. |
| State restoration | **Restore useful launcher UI state only.** | `@SceneStorage` restores search and selection/sidebar context. Pending deep-link navigation is centralized in `AppNavigation`. Passwords, API keys, SSH material, Vault tokens/leases, and Quick Connect drafts are never persisted as restoration state. |
| Accessibility | **Use standard SwiftUI controls and equivalent actions.** | Favorite color and group have accessible text equivalents; drag reorder has menu/keyboard alternatives; destructive actions are labeled and confirmed. Verify VoiceOver, keyboard navigation, focus, Dynamic Type, and reduced motion on supported targets. |
| Localization | **Keep strings localization-ready and searches locale-aware.** | User-facing launcher labels, menu actions, errors, intent metadata, notifications, and accessibility values belong in the project’s String Catalog workflow. Search and ordering use locale-aware comparisons; no locale-specific persistence format is introduced. |
| Privacy | **Keep one shared data policy.** | Local SwiftData stores definitions, Keychain stores secrets, Vault tokens are device-only, and widgets/Spotlight/URLs/restoration receive only minimum metadata. Deletion must remove related secrets, indexes, snapshots, and stale routes without deleting remote databases or SQLite files. |

## Why no new capabilities are added

The existing targets already provide the useful system surfaces for this
product: WidgetKit, App Intents/Shortcuts, Spotlight indexing, monitor
notifications, file import, and a custom deep-link scheme. The launcher adds
discoverable controls and keyboard/menu alternatives within those surfaces.

Adding a Share extension, Handoff activity, new widget family, Universal Link,
document type, Live Activity, watch target, App Group, entitlement, or
background mode would either duplicate app state, broaden the supported target
matrix, or create a new path for sensitive connection data without a concrete
user job. Those additions therefore remain out of scope until a specific
workflow, privacy boundary, migration, and target decision is documented.

Future integration work must continue to use the shared model and stable UUID
routes, preserve CloudKit-compatible defaults/migrations, and update indexes,
widget snapshots, notifications, and restoration state when records are
renamed, deleted, or no longer authorized.
