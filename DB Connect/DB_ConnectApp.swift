//
//  DB_ConnectApp.swift
//  DB Connect
//
//  Created by Holger Krupp on 20.07.26.
//

import SwiftUI
import SwiftData

@main
struct DB_ConnectApp: App {
    @Environment(\.scenePhase) private var scenePhase

    static let appModelContainer = makeContainer()

    let sharedModelContainer: ModelContainer
    @State private var scheduler: MonitorScheduler
    @State private var purchaseManager: PurchaseManager

    init() {
        let container = Self.appModelContainer
        self.sharedModelContainer = container
        let scheduler = MonitorScheduler(container: container)
        _scheduler = State(initialValue: scheduler)
        _purchaseManager = State(initialValue: PurchaseManager())

        #if os(iOS)
        // Registration must happen before launch finishes, so it belongs in init.
        scheduler.registerBackgroundTask()
        #endif
    }

    static func makeContainer() -> ModelContainer {
        let schema = Schema([
            Connection.self,
            SavedQuery.self,
            QueryHistoryEntry.self,
            Monitor.self,
            MonitorActivation.self,
            MonitorSample.self,
            MonitorField.self
        ])

        // Primary store: the private CloudKit database, so connections, saved queries and
        // monitor definitions follow the user across devices. Result data and credentials never
        // go through here — secrets sync separately via iCloud Keychain.
        let cloud = ModelConfiguration(
            schema: schema,
            cloudKitDatabase: .private("iCloud.de.holgerkrupp.DB-Connect")
        )

        do {
            return try ModelContainer(for: schema, configurations: [cloud])
        } catch {
            // No iCloud account, sync disabled, or missing entitlement at dev time.
            // A database client that refuses to launch without iCloud would be absurd,
            // so fall back to the same schema in a purely local store.
            print("CloudKit store unavailable (\(error)); falling back to local store.")
        }

        let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        do {
            return try ModelContainer(for: schema, configurations: [local])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView(purchaseManager: purchaseManager)
                .environment(\.monitorScheduler, scheduler)
                .environment(\.appNavigation, AppNavigation.shared)
                .task { scheduler.start() }
                .onOpenURL { AppNavigation.shared.handle($0) }
        }
        .modelContainer(sharedModelContainer)
        .commands {
            AppMenuCommands()
            #if os(macOS)
            DBConnectHelpCommands()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // The only execution path that is reliable on every platform.
                Task { await scheduler.runDue() }
            case .background:
                #if os(iOS)
                scheduler.scheduleBackgroundRefresh()
                #endif
            default:
                break
            }
        }

        // The Sequel Ace–style account manager, opened in its own window on Mac and iPad. It is
        // keyed by the connection's UUID; the window reconnects its own session from that id.
        WindowGroup("Users", id: UserAdminWindow.sceneID, for: UUID.self) { $connectionID in
            UserAdminWindow(connectionID: connectionID)
                .environment(\.monitorScheduler, scheduler)
                .environment(\.appNavigation, AppNavigation.shared)
        }
        .modelContainer(sharedModelContainer)

        #if os(macOS)
        Window("Getting Started", id: DBConnectDocumentationWindow.onboardingSceneID) {
            DBConnectOnboardingView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("DB Connect Documentation", id: DBConnectDocumentationWindow.sceneID) {
            DBConnectDocumentationView()
        }
        .defaultSize(width: 900, height: 650)

        // iOS reaches the same form through a toolbar button in ContentView.
        Settings {
            SettingsView()
        }
        #endif
    }
}

extension EnvironmentValues {
    @Entry var monitorScheduler: MonitorScheduler?
}
