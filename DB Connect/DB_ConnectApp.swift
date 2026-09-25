//
//  DB_ConnectApp.swift
//  DB Connect
//
//  Created by Holger Krupp on 20.07.26.
//

import SwiftUI
import SwiftData
import Observation

@main
struct DB_ConnectApp: App {
    @Environment(\.scenePhase) private var scenePhase

    static let mainWindowID = "main"
    @MainActor static let runtime = AppRuntime()

    @State private var runtime: AppRuntime
    @State private var purchaseManager: PurchaseManager

    init() {
        AppTips.configure()

        _runtime = State(initialValue: Self.runtime)
        _purchaseManager = State(initialValue: PurchaseManager())
    }

    nonisolated static func makeContainer() async throws -> ModelContainer {
        let schema = Schema([
            Connection.self,
            ConnectionFavoriteGroup.self,
            SavedQuery.self,
            QueryFavorite.self,
            QueryHistoryEntry.self,
            Monitor.self,
            MonitorActivation.self,
            MonitorSample.self,
            MonitorField.self
        ])

        // The app's normal store is always local. CloudKit is an optional future sync
        // integration and must never be part of the launch-critical path.
        let local = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        return try ModelContainer(for: schema, configurations: [local])
    }

    var body: some Scene {
        WindowGroup(id: Self.mainWindowID) {
            AppBootstrapView(purchaseManager: purchaseManager, runtime: runtime)
                .onOpenURL { AppNavigation.shared.handle($0) }
        }
        .commands {
            // AppMenuCommands reads a large set of dynamic focused values. Keeping that
            // graph out of the launch scene avoids SwiftUI repeatedly rebuilding the main
            // menu while the first window is still being prepared.
            #if os(macOS)
            DBConnectHelpCommands()
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            runtime.handle(phase)
        }

        // The Sequel Ace–style account manager, opened in its own window on Mac and iPad. It is
        // keyed by the connection's UUID; the window reconnects its own session from that id.
        WindowGroup("Users", id: UserAdminWindow.sceneID, for: UUID.self) { $connectionID in
            UserAdminWindowBootstrap(connectionID: $connectionID, runtime: runtime)
        }

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

/// Owns the one shared SwiftData container and creates it without blocking the main actor.
///
/// SwiftData may open or migrate a large local store during `ModelContainer`'s initializer.
/// Constructing it from `App.init` makes macOS show the spinning wait cursor before the first
/// window exists. The container is `@unchecked Sendable` by design, so it can safely be handed
/// back to the main actor once initialization has completed.
@MainActor
@Observable
final class AppRuntime {
    private(set) var container: ModelContainer?
    private(set) var scheduler: MonitorScheduler?
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    func loadIfNeeded() async -> ModelContainer? {
        guard container == nil, !isLoading else { return container }
        isLoading = true
        errorMessage = nil

        do {
            let container = try await Task.detached(priority: .userInitiated) {
                try await DB_ConnectApp.makeContainer()
            }.value
            self.container = container
            let scheduler = MonitorScheduler(container: container)
            #if os(iOS)
            // Registration must happen before the app finishes launching, but it does not need
            // the main window or a loaded query. Do it as soon as the shared runtime is ready.
            scheduler.registerBackgroundTask()
            #endif
            self.scheduler = scheduler
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
        return container
    }

    func handle(_ phase: ScenePhase) {
        guard let scheduler else { return }

        switch phase {
        case .active:
            Task { await scheduler.runDue() }
        case .background:
            #if os(iOS)
            scheduler.scheduleBackgroundRefresh()
            #endif
        default:
            break
        }
    }
}

private struct AppBootstrapView: View {
    let purchaseManager: PurchaseManager
    let runtime: AppRuntime

    var body: some View {
        Group {
            if let container = runtime.container, let scheduler = runtime.scheduler {
                ContentView(purchaseManager: purchaseManager)
                    .environment(\.monitorScheduler, scheduler)
                    .environment(\.appNavigation, AppNavigation.shared)
                    .modelContainer(container)
                    .task { scheduler.start() }
            } else {
                AppLaunchLoadingView(errorMessage: runtime.errorMessage) {
                    Task { _ = await runtime.loadIfNeeded() }
                }
            }
        }
        .task { _ = await runtime.loadIfNeeded() }
    }
}

private struct UserAdminWindowBootstrap: View {
    @Binding var connectionID: UUID?
    let runtime: AppRuntime

    var body: some View {
        Group {
            if let container = runtime.container, let scheduler = runtime.scheduler {
                UserAdminWindow(connectionID: connectionID)
                    .environment(\.monitorScheduler, scheduler)
                    .environment(\.appNavigation, AppNavigation.shared)
                    .modelContainer(container)
            } else {
                AppLaunchLoadingView(errorMessage: runtime.errorMessage) {
                    Task { _ = await runtime.loadIfNeeded() }
                }
            }
        }
        .task { _ = await runtime.loadIfNeeded() }
    }
}

#if os(macOS)
private struct MonitorMenuBarBootstrap: View {
    let runtime: AppRuntime

    var body: some View {
        Group {
            if let container = runtime.container, let scheduler = runtime.scheduler {
                MonitorMenuBarView()
                    .environment(\.monitorScheduler, scheduler)
                    .environment(\.appNavigation, AppNavigation.shared)
                    .modelContainer(container)
            } else {
                AppLaunchLoadingView(errorMessage: runtime.errorMessage) {
                    Task { _ = await runtime.loadIfNeeded() }
                }
            }
        }
        .task { _ = await runtime.loadIfNeeded() }
    }
}
#endif

private struct AppLaunchLoadingView: View {
    let errorMessage: String?
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            if let errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .font(.title)
                    .foregroundStyle(.orange)
                Text("DB Connect could not finish starting.")
                    .font(.headline)
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Try Again", action: retry)
                    .keyboardShortcut(.defaultAction)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing DB Connect…")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(minWidth: 360, minHeight: 220)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(errorMessage == nil ? "Preparing DB Connect" : "DB Connect could not finish starting")
    }
}

extension EnvironmentValues {
    @Entry var monitorScheduler: MonitorScheduler?
}
