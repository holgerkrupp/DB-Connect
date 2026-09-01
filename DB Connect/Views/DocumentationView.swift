import SwiftUI

enum DBConnectDocumentationWindow {
    static let sceneID = "documentation"
    static let onboardingSceneID = "onboarding"
}

private enum DBConnectLinks {
    static let privacyPolicy = URL(string: "https://holgerkrupp.de/privacy.txt")!
}

struct DBConnectDocumentationView: View {
    @State private var selection: DBConnectDocumentationTopic? = .quickStart

    var body: some View {
        NavigationSplitView {
            List(DBConnectDocumentationTopic.allCases, selection: $selection) { topic in
                Label(topic.title, systemImage: topic.systemImage)
                    .tag(topic)
            }
            .navigationTitle("Documentation")
            .navigationSplitViewColumnWidth(min: 190, ideal: 220)
        } detail: {
            DBConnectDocumentationArticle(topic: selection ?? .quickStart)
        }
    }
}

private enum DBConnectDocumentationTopic: String, CaseIterable, Identifiable {
    case quickStart
    case connections
    case tables
    case sqlConsole
    case transfer
    case administration
    case monitors
    case syncAndAutomation
    case troubleshooting

    var id: Self { self }

    var title: String {
        switch self {
        case .quickStart: "Quick Start"
        case .connections: "Connections & Security"
        case .tables: "Tables & Row Editing"
        case .sqlConsole: "SQL Console"
        case .transfer: "Import & Export"
        case .administration: "Schema & Users"
        case .monitors: "Monitors"
        case .syncAndAutomation: "Sync, Widgets & Shortcuts"
        case .troubleshooting: "Troubleshooting"
        }
    }

    var systemImage: String {
        switch self {
        case .quickStart: "sparkles"
        case .connections: "network.badge.shield.half.filled"
        case .tables: "tablecells"
        case .sqlConsole: "curlybraces"
        case .transfer: "arrow.left.arrow.right"
        case .administration: "person.2.badge.gearshape"
        case .monitors: "bell.badge"
        case .syncAndAutomation: "icloud.and.arrow.up"
        case .troubleshooting: "wrench.and.screwdriver"
        }
    }

    var summary: String {
        switch self {
        case .quickStart: "The shortest path from a new connection to browsing data and running a query."
        case .connections: "Choose a driver, protect credentials, and set the right write and transport policy."
        case .tables: "Page, search, filter, sort, and safely stage changes to database rows."
        case .sqlConsole: "Write schema-aware SQL, inspect bounded results, and reuse useful statements."
        case .transfer: "Move CSV data or SQL dumps with explicit format and destination controls."
        case .administration: "Create database objects and manage accounts where the server permits it."
        case .monitors: "Schedule a query, compare its value, and control per-device notifications."
        case .syncAndAutomation: "Understand what syncs and reach saved work from widgets, Shortcuts, and Siri."
        case .troubleshooting: "Recover from common connection, permission, query, sync, and monitor problems."
        }
    }
}

private struct DBConnectDocumentationArticle: View {
    let topic: DBConnectDocumentationTopic

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                DBConnectDocumentationHeader(topic: topic)

                switch topic {
                case .quickStart: quickStart
                case .connections: connections
                case .tables: tables
                case .sqlConsole: sqlConsole
                case .transfer: transfer
                case .administration: administration
                case .monitors: monitors
                case .syncAndAutomation: syncAndAutomation
                case .troubleshooting: troubleshooting
                }
            }
            .frame(maxWidth: 720, alignment: .leading)
            .padding(32)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(topic.title)
    }

    private var quickStart: some View {
        Group {
            DBConnectDocumentationSection("Add a connection") {
                DBConnectDocumentationSteps([
                    "Choose File → New Connection (Command-N) or use the plus button beside the connection list.",
                    "Select SQLite, MySQL, PostgreSQL, or Supabase and enter the fields for that connection type.",
                    "Save, then select the connection. DB Connect opens a session and loads the databases, schemas, and tables the account may see."
                ])
            }
            DBConnectDocumentationSection("Browse or query") {
                DBConnectDocumentationSteps([
                    "Stay in Tables to select a table, search and filter it, and move through results in bounded pages.",
                    "Switch to SQL to write an arbitrary statement on drivers that support a console.",
                    "Save a useful query for later, or create a monitor when its result should be checked on a schedule."
                ])
            }
            DBConnectDocumentationNote(
                systemImage: "lock.shield.fill",
                text: "Start with Read-only when exploring an unfamiliar or production database. It blocks writes in DB Connect even if the database account itself can write."
            )
        }
    }

    private var connections: some View {
        Group {
            DBConnectDocumentationSection("Connection types") {
                DBConnectDocumentationBullets([
                    "SQLite opens a database file chosen from the device.",
                    "MySQL and PostgreSQL use a host, port, optional initial database, username, password, and TLS policy.",
                    "MySQL can also connect over a local Unix socket for servers running on the same Mac.",
                    "MySQL and PostgreSQL can be reached through an SSH tunnel on macOS when direct network access is unavailable or intentionally blocked.",
                    "MySQL can authenticate with AWS IAM by generating a fresh RDS or Aurora auth token each time the app connects.",
                    "Supabase uses the project URL and an anon or service-role API key. DB Connect adds the REST endpoint path automatically."
                ])
            }
            DBConnectDocumentationSection("Credentials and sync") {
                Text("Passwords, API keys, SSH secrets, and AWS access keys are stored separately in Keychain and are never written into the SwiftData connection record. Connection definitions sync through the user’s private iCloud database when available; secrets follow only when iCloud Keychain is enabled. SQLite files and their access remain device-specific.")
            }
            DBConnectDocumentationSection("Advanced transport and auth") {
                DBConnectDocumentationBullets([
                    "Use Local Socket for a MySQL or MariaDB server running on the same Mac. The socket path comes from the server, for example `/tmp/mysql.sock`.",
                    "SSH tunnels use the system OpenSSH client on macOS and require a trusted host key in your normal known-hosts configuration. DB Connect refuses unknown or changed host keys instead of accepting them silently.",
                    "AWS IAM needs the real RDS or Aurora endpoint hostname and an AWS region. The generated token is used only for login; an established database session does not need mid-session password rotation."
                ])
            }
            DBConnectDocumentationSection("TLS choices") {
                DBConnectDocumentationBullets([
                    "Required requests TLS and uses the system trust store. MySQL may fall back to plaintext if its server refuses TLS; use Pinned when that must never happen.",
                    "Pinned certificate trusts only the imported X.509 certificate and displays its SHA-256 fingerprint for an out-of-band comparison.",
                    "Preferred permits an unencrypted fallback. Disabled is appropriate only when another trusted layer, such as a VPN or SSH tunnel, provides protection."
                ])
            }
            DBConnectDocumentationSection("What is intentionally deferred") {
                Text("Vault- or OIDC-issued ephemeral database credentials are not shipped yet. They need a broader account-provider model, interactive browser or device-code flows, token and role selection UX, and clear trust boundaries around refresh in foreground windows, monitors, and widgets. The connection model now has typed authentication extension points so those providers can be added without redesigning every driver or form.")
            }
            DBConnectDocumentationSection("Manage connection entries") {
                Text("Edit changes the selected definition. Duplicate copies configuration but deliberately does not copy the password or API key. Delete removes the definition and its Keychain secret; it never deletes the remote database or SQLite file.")
            }
            DBConnectDocumentationNote(
                systemImage: "exclamationmark.shield.fill",
                text: "Compare a pinned certificate fingerprint with a value obtained from the server administrator over a separate trusted channel."
            )
        }
    }

    private var tables: some View {
        Group {
            DBConnectDocumentationSection("Shape a result page") {
                DBConnectDocumentationBullets([
                    "Choose a table or view, then use Search to match across columns.",
                    "Add typed per-column filters and select column headers to sort.",
                    "Use the pager to move through the data or change how many rows are loaded at once. Only the current page is held in memory."
                ])
            }
            DBConnectDocumentationSection("Stage row changes") {
                DBConnectDocumentationSteps([
                    "Add a row or select an existing row to edit or delete it. Editing requires a writable connection, driver support, and a table with a usable key.",
                    "Continue browsing or stage more work. DB Connect has not written these mutations yet.",
                    "Choose Review Changes, inspect the generated statements, then apply or discard individual changes. Supported drivers apply the batch in a transaction."
                ])
            }
            DBConnectDocumentationNote(
                systemImage: "eye.fill",
                text: "A view or a table without a primary key can still be browsed, searched, filtered, and sorted, but row editing is disabled because a change could not be targeted safely."
            )
        }
    }

    private var sqlConsole: some View {
        Group {
            DBConnectDocumentationSection("Write and run") {
                DBConnectDocumentationBullets([
                    "The editor highlights SQL and suggests table and column names from the open schema.",
                    "Command-Return runs the editor contents. Query results are capped; add LIMIT and an ordering when you need a specific slice.",
                    "Click a result column to sort the loaded result locally. Execution summaries report non-row statements."
                ])
            }
            DBConnectDocumentationSection("Identifier assistance") {
                Text("DB Connect can underline names that do not match the schema, silently correct capitalization, and offer spelling fixes. Settings controls how much it may change automatically. Quoted identifiers and aliases defined by the query are left alone.")
            }
            DBConnectDocumentationSection("Saved queries and history") {
                DBConnectDocumentationBullets([
                    "Save Query stores the SQL, title, connection, and selected database for reuse and monitor setup.",
                    "Favorites are separate from saved queries: they can be global or connection-scoped, insert into the editor without replacing it, and expand placeholders like `$DATABASE`, `$TABLE`, `${1:columns}`, and `$0`.",
                    "Assign a tab trigger to a favorite, type it in the SQL editor, then press Tab to expand the snippet in place. Query → Favorites opens the library with the keyboard shortcut Command-Option-F.",
                    "History keeps the latest statements and their duration and outcome for each connection when enabled.",
                    "Result rows and live console results are never stored or synced."
                ])
            }
            DBConnectDocumentationSection("What is intentionally deferred") {
                Text("Shell-command favorites are intentionally not included in this release. DB Connect’s favorites sync through app data and are designed to be safe to expand as plain text; executing local shell commands from those snippets would introduce a separate trust, permission, and audit model that the app does not yet explain well enough.")
            }
            DBConnectDocumentationNote(
                systemImage: "exclamationmark.triangle.fill",
                text: "Autocomplete and corrections are conveniences, not a SQL safety system. Review destructive statements and use database permissions plus Read-only for real enforcement."
            )
        }
    }

    private var transfer: some View {
        Group {
            DBConnectDocumentationSection("Export") {
                DBConnectDocumentationBullets([
                    "SQL dump export can include structure, content, and DROP statements independently for each supported table or view.",
                    "Large object lists can be filtered by schema or object name before selecting what to include.",
                    "CSV export writes one table or multiple table files with configurable delimiter, quote, header, line ending, NULL representation, and text encoding.",
                    "Export reads through the current connection and writes only to the destination you choose."
                ])
            }
            DBConnectDocumentationSection("Import") {
                DBConnectDocumentationSteps([
                    "Choose SQL or CSV and select a readable source file.",
                    "For CSV, confirm the header option, target table or new table name, and source-to-destination column mapping.",
                    "Review the parsed preview and options, then start the import. SQL previews show executable statements and their source line ranges; failed statements are reported with line numbers, error text, and the relevant SQL excerpt."
                ])
            }
            DBConnectDocumentationSection("CSV workflow details") {
                Text("When importing into a new table, DB Connect infers a starter column list from the first 200 data rows so the destination is visible before you commit. Existing-table imports keep explicit column mapping so defaults, generated columns, and conflict handling stay under your control.")
            }
            DBConnectDocumentationNote(
                systemImage: "externaldrive.badge.exclamationmark",
                text: "A SQL dump may contain destructive statements. Inspect untrusted files before importing, use a least-privileged account, and keep a tested backup."
            )
        }
    }

    private var administration: some View {
        Group {
            DBConnectDocumentationSection("Tables and databases") {
                DBConnectDocumentationBullets([
                    "New Table builds a column definition and previews the statement before creation.",
                    "New Database is available only when the active driver and account report that capability.",
                    "Reload Schema refreshes database metadata after changes made in DB Connect or another tool."
                ])
            }
            DBConnectDocumentationSection("Users and privileges") {
                Text("Manage Users is available for supported MySQL and PostgreSQL sessions. MySQL and MariaDB accounts can be edited at global, database, and single-table scope, including the server privileges that DB Connect exposes only when the current connection actually supports them. PostgreSQL keeps the simpler cross-database grant flow. The signed-in account still needs permission to perform each operation.")
            }
            DBConnectDocumentationSection("MySQL and MariaDB administration") {
                DBConnectDocumentationBullets([
                    "Table Details opens a MySQL- or MariaDB-only inspector for the selected table’s metadata, foreign-key relations, and triggers.",
                    "MySQL Administration shows server variables and the visible process list. Without the PROCESS privilege, the process viewer may show only sessions visible to the connected account.",
                    "Flush Privileges is shown only when the connected account has the server right to reload grant tables."
                ])
            }
            DBConnectDocumentationSection("What is intentionally deferred") {
                Text("MySQL contextual help for SQL terms is not shipped yet. Server-side HELP support and access to the mysql help tables vary across MySQL, MariaDB, and hosted services, and DB Connect does not want to fall back to shell execution or bundled stale help text without a clearer trust and update model. The current Phase 2 release focuses on server metadata and privilege administration instead.")
            }
            DBConnectDocumentationSection("Capability-based interface") {
                Text("DB Connect hides or disables an administrative action when the driver, server, selected object, read-only setting, or current account cannot safely perform it. An unavailable command is therefore often contextual rather than an app failure.")
            }
        }
    }

    private var monitors: some View {
        Group {
            DBConnectDocumentationSection("Create a monitor") {
                DBConnectDocumentationSteps([
                    "Open Monitors, add a monitor, and choose an existing saved query or define a new query with its connection and database.",
                    "Choose the condition. Leave Column blank to compare the first value of the first row, which works well with SELECT COUNT(*).",
                    "Set its interval, optional repeat cooldown, quiet hours, notification template, and whether it runs on this device."
                ])
            }
            DBConnectDocumentationSection("Scheduling and history") {
                DBConnectDocumentationBullets([
                    "Enabled monitors run when the app is active and use platform background opportunities when available; the operating system does not guarantee exact wake times.",
                    "Quiet hours suppress notifications but do not stop sampling, so later comparisons remain meaningful.",
                    "Each device has its own activation and sample history. Enabling the same monitor on several devices can produce several notifications."
                ])
            }
            DBConnectDocumentationSection("Notification fields") {
                Text("A message can include the monitor’s current value and fields supplied by other saved queries. Use a cooldown to avoid repeated alerts while a condition remains true.")
            }
            DBConnectDocumentationNote(
                systemImage: "bell.slash.fill",
                text: "A monitor needs working credentials on the device that runs it, permission to execute its query, notification permission, and occasional background execution time."
            )
        }
    }

    private var syncAndAutomation: some View {
        Group {
            DBConnectDocumentationSection("What syncs") {
                DBConnectDocumentationBullets([
                    "Connection definitions, saved queries, query favorites, and monitor definitions use the private iCloud database when it is available.",
                    "Passwords and API keys use iCloud Keychain separately. They may arrive later than a connection definition or remain local when Keychain sync is disabled.",
                    "Query result rows never sync. Monitor activations and sample histories remain specific to each device."
                ])
            }
            DBConnectDocumentationSection("Widgets") {
                Text("Add DB Connect widgets from the system widget gallery to show monitor status or saved-query shortcuts. Widgets use a privacy-conscious snapshot of titles and status; they do not contain database result sets or credentials. Tapping an item opens the corresponding place in DB Connect.")
            }
            DBConnectDocumentationSection("Shortcuts and Siri") {
                DBConnectDocumentationBullets([
                    "Open Saved Query brings the chosen query into the SQL console.",
                    "Open Monitor opens the monitor and its current status.",
                    "Run Monitors Now checks every monitor enabled on this device immediately."
                ])
            }
            DBConnectDocumentationNote(
                systemImage: "icloud.slash",
                text: "When iCloud is unavailable, DB Connect falls back to a local app database so you can keep working. Those local records do not retroactively become the CloudKit store during that launch."
            )
        }
    }

    private var troubleshooting: some View {
        Group {
            DBConnectDocumentationSection("A connection fails") {
                DBConnectDocumentationBullets([
                    "Recheck host, port, database, username, secret, VPN or tunnel, and whether the server accepts remote clients.",
                    "For SSH, confirm the host key is already trusted by OpenSSH on this Mac and that the selected SSH authentication mode matches the available secret or agent state.",
                    "For AWS IAM, confirm the region, AWS keys, database username, IAM policy, and that you used the database endpoint hostname rather than a custom DNS alias.",
                    "For system-trusted TLS, confirm the certificate is valid for the server and not expired. For pinned TLS, re-import the certificate after a legitimate rotation and verify its new fingerprint.",
                    "Use Reconnect after correcting network or server state. Edit Connection when the saved definition itself must change."
                ])
            }
            DBConnectDocumentationSection("An action is unavailable") {
                DBConnectDocumentationBullets([
                    "Turn off Read-only only when writes are intended.",
                    "Confirm the account has the database privilege required for the action.",
                    "Row editing also needs driver support and a table key; SQL console and administrative features vary by driver.",
                    "MySQL process visibility and Flush Privileges also depend on server-wide PROCESS or RELOAD rights."
                ])
            }
            DBConnectDocumentationSection("Sync or automation looks incomplete") {
                DBConnectDocumentationBullets([
                    "Confirm the device is signed into iCloud and that iCloud Drive and Keychain are enabled for the account.",
                    "Open DB Connect once after adding or changing saved queries and monitors so widgets and App Intents can refresh their snapshot.",
                    "For monitors, confirm the device activation is On, credentials exist locally, notifications are permitted, and quiet hours or cooldown are not suppressing an alert."
                ])
            }
            DBConnectDocumentationSection("A query or import fails") {
                Text("Copy the server error, verify the selected database and schema, then test the smallest relevant statement. For imports, inspect the failed-statement list, delimiter and encoding, column mapping, constraints, and transaction or account permissions.")
            }
        }
    }
}

private struct DBConnectDocumentationHeader: View {
    let topic: DBConnectDocumentationTopic

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: topic.systemImage)
                .font(.system(size: 30, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
                .background(.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(topic.title)
                    .font(.largeTitle.bold())
                Text(topic.summary)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct DBConnectDocumentationSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2.bold())
            content
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DBConnectDocumentationBullets: View {
    let items: [String]

    init(_ items: [String]) { self.items = items }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 5))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct DBConnectDocumentationSteps: View {
    let items: [String]

    init(_ items: [String]) { self.items = items }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(index + 1)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(.tint, in: Circle())
                        .accessibilityHidden(true)
                    Text(item)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Step \(index + 1): \(item)")
            }
        }
    }
}

private struct DBConnectDocumentationNote: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label {
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .textSelection(.enabled)
    }
}

#if os(macOS)
struct DBConnectHelpCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("DB Connect Documentation") {
                openWindow(id: DBConnectDocumentationWindow.sceneID)
            }
            .keyboardShortcut("?", modifiers: .command)

            Button("Getting Started") {
                openWindow(id: DBConnectDocumentationWindow.onboardingSceneID)
            }

            Divider()

            Link("Privacy Policy", destination: DBConnectLinks.privacyPolicy)
        }
    }
}
#endif

#Preview {
    DBConnectDocumentationView()
        .frame(width: 900, height: 650)
}
