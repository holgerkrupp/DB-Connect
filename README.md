# DB Connect

DB Connect is a native SwiftUI database client for Apple platforms. It provides
saved connections, query workspaces, monitors, and a macOS connection launcher
for SQLite, MySQL/MariaDB, PostgreSQL, and Supabase connections.

## Supported platforms and targets

The Xcode project is the source of truth for supported platforms:

- **DB Connect** is a native macOS app and a native iPhone/iPad app. It is not
  a Mac Catalyst target. The current deployment settings are macOS 26.5 and
  iOS 26.0.
- **DB Connect Widgets** is the existing WidgetKit app-extension target for
  the same macOS and iPhone/iPad platforms.
- **DB ConnectTests** is the unit-test bundle (currently exercised on macOS).

There is no watchOS target. The watch platform guidance in `docs/platforms/`
does not add a target or capability to this project.

## Build and test

From the repository root, inspect the available targets and schemes with:

```sh
xcodebuild -list -project "DB Connect.xcodeproj"
```

Build the app and the existing widget extension with:

```sh
xcodebuild -project "DB Connect.xcodeproj" \
  -scheme "DB Connect" -configuration Debug build
xcodebuild -project "DB Connect.xcodeproj" \
  -scheme "DB Connect Widgets" -configuration Debug build
```

Run the unit tests on macOS:

```sh
xcodebuild test -project "DB Connect.xcodeproj" \
  -scheme "DB Connect" -destination 'platform=macOS'
```

For iPhone/iPad tests, substitute an installed simulator destination, for
example `-destination 'platform=iOS Simulator,name=iPhone 16 Pro'`.

## Connection and security model

Connection definitions, saved queries, favorites, groups, and monitor
definitions are SwiftData records in a local store. CloudKit is not required
to launch or use the app; optional sync can be added later without making
startup depend on an iCloud account or network availability.

Passwords, API keys, AWS credentials, and SSH material are not fields in the
synced connection record. They are stored separately in Keychain, keyed by the
connection UUID; the connection UUID is therefore the stable join between
configuration and secret. Vault tokens are device-local Keychain items, and
short-lived Vault database leases remain in runtime memory. SQLite bookmarks
and file access are device-specific. Credentials, SQL text, result rows, and
database hosts are not placed in widget snapshots, Spotlight entities, URLs,
or launcher restoration state.

Deleting a saved connection removes its associated Keychain entry and app
record; it does not delete a remote database or a user-selected SQLite file.
Transient Quick Connect drafts are used only for the current editor/session
and are not persisted as favorites until the user explicitly chooses **Save
Favorite**.

## Launcher workflow

On macOS, the connection-first launcher provides:

1. **Quick Connect**, which opens an editor without creating a saved record or
   starting a network session.
2. **Favorites**, searchable with locale-aware matching and organized into
   groups. Favorites support deterministic manual order, color/tag metadata,
   drag reorder, and equivalent menu/keyboard actions. Group removal
   uncategorizes its connections; it never deletes them.
3. **Explicit actions** to connect, save, edit, duplicate, move, or delete a
   favorite. Selecting a favorite loads its editor; it does not connect until
   the user chooses **Connect**. A failed connection returns to the launcher
   with the editor state available for correction.
4. **Monitors**, which remains an explicit destination from the launcher.

The launcher restores only non-sensitive UI state such as search and selection.
The iPhone/iPad app keeps its adaptive sheet/navigation workflow; the
connection-first launcher is a macOS presentation of the shared domain model,
not a second persistence layer.

Existing widgets, App Intents/Shortcuts, Spotlight entries, notifications, and
`db-connect://` routes are documented in
[`docs/connection-launcher-integrations.md`](docs/connection-launcher-integrations.md).
No new extension, URL scheme, watch target, entitlement, or background mode is
implied by this README.
