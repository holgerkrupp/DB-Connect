import SwiftUI

/// The bridge between the menu bar and the view tree.
///
/// Menu commands are declared once at the `App` scene, but everything they act on — the open
/// session, the pending edits, the query in the editor — lives deep inside views that come and
/// go. So each area publishes what it can currently do as a *focused scene value*, and the menu
/// reads it back. A nil value means "no such context on screen right now", which is exactly the
/// condition that should grey the item out, so disabling falls out of the same mechanism.
///
/// Scene-scoped rather than focus-scoped on purpose: ⌘R should refresh the browser whether or
/// not the grid happens to hold keyboard focus at that moment.

/// Actions belonging to the connection list in the sidebar.
struct ConnectionListActions {
    var newConnection: () -> Void
    /// Nil when nothing is selected — there is no connection to act on.
    var editSelected: (() -> Void)?
    var duplicateSelected: (() -> Void)?
    var deleteSelected: (() -> Void)?
    /// Hangs up the session and returns to the empty state. Lives here rather than on
    /// `ConnectionActions` because it must also work on a connection that failed to open —
    /// which is exactly when there is no session to hang it off.
    var closeSelected: (() -> Void)?
}

/// Actions belonging to one open connection.
struct ConnectionActions {
    var mode: ConnectionDetailView.Mode
    var setMode: (ConnectionDetailView.Mode) -> Void
    /// False for drivers with no SQL console, where the mode switch is meaningless.
    var canRunSQL: Bool

    var databases: [String]
    var activeDatabase: String?
    var switchDatabase: (String) -> Void

    var newTable: (() -> Void)?
    var newDatabase: (() -> Void)?
    var manageUsers: (() -> Void)?
    var importData: (() -> Void)?
    var exportData: (() -> Void)?

    var reloadSchema: () -> Void
    var reconnect: () -> Void

    /// Declared on every platform even though only macOS shows a table list column, because
    /// `#if` is not allowed inside an argument list and splitting the initializer in two to
    /// avoid it costs more than the two unused fields.
    var isTableListShown: Bool = false
    var toggleTableList: () -> Void = {}
}

/// Actions belonging to the SQL console, published only while it is on screen.
struct ConsoleActions {
    var run: () -> Void
    var canRun: Bool
    var saveQuery: () -> Void
    var canSave: Bool
    var clearEditor: () -> Void
}

/// Actions belonging to the table browser, published only while it is on screen.
struct BrowserActions {
    var refresh: () -> Void
    var addRow: (() -> Void)?
    var reviewChanges: (() -> Void)?
    var pendingCount: Int
}

extension FocusedValues {
    @Entry var connectionListActions: ConnectionListActions?
    @Entry var connectionActions: ConnectionActions?
    @Entry var consoleActions: ConsoleActions?
    @Entry var browserActions: BrowserActions?
}

/// The app's menu bar.
///
/// Shortcut choices follow the platform conventions users already have in their fingers — ⌘N for
/// the primary new thing, ⌘I for "get info", ⌘S for save, ⌘R for refresh — and everything else
/// is left unbound rather than inventing a chord nobody will remember.
struct AppMenuCommands: Commands {
    @FocusedValue(\.connectionListActions) private var list
    @FocusedValue(\.connectionActions) private var connection
    @FocusedValue(\.consoleActions) private var console
    @FocusedValue(\.browserActions) private var browser

    var body: some Commands {
        // MARK: File

        CommandGroup(replacing: .newItem) {
            Button("New Connection…") { list?.newConnection() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(list == nil)

            Button("New Table…") { connection?.newTable?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(connection?.newTable == nil)

            Button("New Database…") { connection?.newDatabase?() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(connection?.newDatabase == nil)
        }

        CommandGroup(after: .newItem) {
            Divider()

            Button("Edit Connection…") { list?.editSelected?() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(list?.editSelected == nil)

            Button("Duplicate Connection") { list?.duplicateSelected?() }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(list?.duplicateSelected == nil)

            Button("Delete Connection…") { list?.deleteSelected?() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(list?.deleteSelected == nil)

            Divider()

            // Kept in this group rather than `replacing: .saveItem`, which would open a second
            // system group and leave two separators stacked against each other.
            Button("Save Query…") { console?.saveQuery() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(console?.canSave != true)

            Divider()

            Button("Import Data…") { connection?.importData?() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(connection?.importData == nil)

            Button("Export Data…") { connection?.exportData?() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(connection?.exportData == nil)
        }

        // MARK: View

        CommandGroup(after: .toolbar) {
            Button("Tables") { connection?.setMode(.tables) }
                .keyboardShortcut("1", modifiers: [.command, .control])
                .disabled(connection == nil)

            Button("SQL Console") { connection?.setMode(.sql) }
                .keyboardShortcut("2", modifiers: [.command, .control])
                .disabled(connection?.canRunSQL != true)

            #if os(macOS)
            Divider()

            Button(connection?.isTableListShown == true ? "Hide Table List" : "Show Table List") {
                connection?.toggleTableList()
            }
            .keyboardShortcut("t", modifiers: [.command, .option])
            .disabled(connection == nil)
            #endif

            Divider()

            Button("Refresh") { refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(connection == nil)
        }

        // MARK: Query

        CommandMenu("Query") {
            Button("Run") { console?.run() }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(console?.canRun != true)

            Button("Clear Editor") { console?.clearEditor() }
                .disabled(console == nil)

            Divider()

            Button("Add Row…") { browser?.addRow?() }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(browser?.addRow == nil)

            // The count is in the title because a menu item renders its label text only —
            // a badge or a second view is dropped on macOS.
            Button(reviewTitle) { browser?.reviewChanges?() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(browser?.reviewChanges == nil)
        }

        // MARK: Database

        CommandMenu("Database") {
            Button("Reload Schema") { connection?.reloadSchema() }
                .disabled(connection == nil)

            Button("Reconnect") { connection?.reconnect() }
                .disabled(connection == nil)

            // Gated on a selection rather than a live session, so a connection stuck on a
            // failed connect can still be dismissed.
            Button("Close Connection") { list?.closeSelected?() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(list?.closeSelected == nil)

            // An inline picker brackets itself with separators, so it supplies the division on
            // both sides here. Adding explicit dividers around it stacks them two deep.
            if let connection, !connection.databases.isEmpty {
                // Switching database is otherwise a trip to the sidebar picker; on a server with
                // a handful of databases this is the faster route.
                Picker("Open Database", selection: Binding(
                    get: { connection.activeDatabase },
                    set: { if let name = $0 { connection.switchDatabase(name) } }
                )) {
                    ForEach(connection.databases, id: \.self) { name in
                        Text(name).tag(Optional(name))
                    }
                }
                .pickerStyle(.inline)
            } else {
                Divider()
            }

            Button("Manage Users…") { connection?.manageUsers?() }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(connection?.manageUsers == nil)
        }
    }

    /// ⌘R means "refresh what I am looking at": the row page in the browser, the schema
    /// otherwise. One shortcut, rather than two the user has to choose between.
    private func refresh() {
        if let browser {
            browser.refresh()
        } else {
            connection?.reloadSchema()
        }
    }

    private var reviewTitle: String {
        let count = browser?.pendingCount ?? 0
        return count > 0 ? "Review \(count) Change\(count == 1 ? "" : "s")…" : "Review Changes…"
    }
}
