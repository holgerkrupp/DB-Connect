import SwiftUI

/// Bump this value when a release adds onboarding pages that existing users
/// should see. Returning users receive only pages introduced since the release
/// they last saw; first-time users receive the complete walkthrough.
enum DBConnectOnboarding {
    static let currentRelease = 1
    static let releaseDefaultsKey = "DBConnectLastSeenOnboardingRelease"
}

@MainActor
final class DBConnectOnboardingPresentation {
    static let shared = DBConnectOnboardingPresentation()

    private var claimedThisLaunch = false

    private init() {}

    func claimAutomaticPresentation(lastSeenRelease: Int) -> Bool {
        guard !claimedThisLaunch,
              lastSeenRelease < DBConnectOnboarding.currentRelease else { return false }
        claimedThisLaunch = true
        return true
    }
}

struct DBConnectOnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @AppStorage(DBConnectOnboarding.releaseDefaultsKey)
    private var lastSeenRelease = 0
    @State private var selectedPage = 0
    @State private var showsDocumentation = false

    private static let allPages: [DBConnectOnboardingPage] = [
        DBConnectOnboardingPage(
            id: "connect",
            introducedIn: 1,
            title: "Connect to Your Database",
            summary: "Keep SQLite, MySQL, PostgreSQL, and Supabase connections together without putting credentials in the synced database.",
            systemImage: "cylinder.split.1x2",
            tint: .blue,
            bullets: [
                "Choose Add Connection, select a database type, and enter its file, server, or project details.",
                "Passwords and API keys live in Keychain; connection definitions can follow you through iCloud.",
                "Use read-only mode for an extra write barrier, and choose the TLS policy that matches your server."
            ]
        ),
        DBConnectOnboardingPage(
            id: "browse",
            introducedIn: 1,
            title: "Browse and Edit Safely",
            summary: "Explore large tables a page at a time, then review every pending mutation before it reaches the database.",
            systemImage: "tablecells",
            tint: .teal,
            bullets: [
                "Search all columns, add per-column filters, sort results, and choose a page size.",
                "Insert, edit, or delete rows when the connection and table support it.",
                "Changes stay staged until you review the generated statements and apply them."
            ]
        ),
        DBConnectOnboardingPage(
            id: "query",
            introducedIn: 1,
            title: "Write and Reuse SQL",
            summary: "The SQL console pairs a focused editor with schema-aware help, capped results, saved queries, and history.",
            systemImage: "curlybraces",
            tint: .indigo,
            bullets: [
                "Switch to SQL, write a statement, and press Command-Return to run it.",
                "Autocomplete and identifier checks use the open schema; you control automatic corrections in Settings.",
                "Save useful statements by name or restore recent SQL from History. Result rows are never stored."
            ]
        ),
        DBConnectOnboardingPage(
            id: "manage",
            introducedIn: 1,
            title: "Move Data and Manage Schema",
            summary: "Use guided tools for everyday administration without losing sight of the SQL being applied.",
            systemImage: "arrow.left.arrow.right",
            tint: .orange,
            bullets: [
                "Import or export CSV data, or create a configurable SQL dump for supported database engines.",
                "Create tables and databases where the connected account permits it.",
                "Manage users and granular privileges on supported MySQL and PostgreSQL servers."
            ]
        ),
        DBConnectOnboardingPage(
            id: "monitor",
            introducedIn: 1,
            title: "Monitor What Matters",
            summary: "Turn a saved query into a scheduled, per-device check and receive a notification when its value meets your rule.",
            systemImage: "bell.badge",
            tint: .purple,
            bullets: [
                "Choose a value or row-count condition, schedule, cooldown, quiet hours, and notification message.",
                "Each device decides which monitors it runs and keeps its own sample history.",
                "Use widgets for quick status and saved-query access, or run and open items with Shortcuts and Siri."
            ]
        )
    ]

    private var pages: [DBConnectOnboardingPage] {
        let unseen = Self.allPages.filter { $0.introducedIn > lastSeenRelease }
        return unseen.isEmpty ? Self.allPages : unseen
    }

    private var isUpdate: Bool {
        lastSeenRelease > 0 && lastSeenRelease < DBConnectOnboarding.currentRelease
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(isUpdate ? "What’s New" : "Getting Started")
                        .font(.title2.bold())
                    Text("DB Connect")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Documentation") { showDocumentation() }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)

            Divider()

            DBConnectOnboardingPageView(page: pages[selectedPage])

            Divider()

            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { index in
                    Circle()
                        .fill(index == selectedPage ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                }

                Spacer()

                if selectedPage > 0 {
                    Button("Back") {
                        withAnimation { selectedPage -= 1 }
                    }
                }

                Button(selectedPage == pages.count - 1 ? "Done" : "Continue") {
                    if selectedPage < pages.count - 1 {
                        withAnimation { selectedPage += 1 }
                    } else {
                        completeAndClose()
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        #if os(macOS)
        .frame(width: 660, height: 580)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #endif
        .sheet(isPresented: $showsDocumentation) {
            NavigationStack {
                DBConnectDocumentationView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsDocumentation = false }
                        }
                    }
            }
        }
        .onDisappear(perform: markCurrentReleaseSeen)
    }

    private func showDocumentation() {
        #if os(macOS)
        openWindow(id: DBConnectDocumentationWindow.sceneID)
        #else
        showsDocumentation = true
        #endif
    }

    private func completeAndClose() {
        markCurrentReleaseSeen()
        dismiss()
    }

    private func markCurrentReleaseSeen() {
        lastSeenRelease = max(lastSeenRelease, DBConnectOnboarding.currentRelease)
    }
}

private struct DBConnectOnboardingPage: Identifiable {
    let id: String
    let introducedIn: Int
    let title: String
    let summary: String
    let systemImage: String
    let tint: Color
    let bullets: [String]
}

private struct DBConnectOnboardingPageView: View {
    let page: DBConnectOnboardingPage

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: page.systemImage)
                    .font(.system(size: 54, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(page.tint)
                    .frame(width: 92, height: 92)
                    .background(page.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))
                    .accessibilityHidden(true)

                VStack(spacing: 7) {
                    Text(page.title)
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                    Text(page.summary)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 520)
                }

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(page.bullets, id: \.self) { bullet in
                        Label {
                            Text(bullet)
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(page.tint)
                        }
                    }
                }
                .frame(maxWidth: 540, alignment: .leading)
                .padding(16)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
    }
}

#Preview {
    DBConnectOnboardingView()
}
