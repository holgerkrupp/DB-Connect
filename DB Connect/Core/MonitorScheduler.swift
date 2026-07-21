import Foundation
import SwiftData
#if os(iOS)
import BackgroundTasks
#endif

/// Drives `MonitorRunner` on a schedule.
///
/// The two platforms are genuinely different and the app does not pretend otherwise:
///
/// - **macOS** keeps a repeating timer while the app runs, so a 15-minute interval means
///   15 minutes. Left running (or as a login item), monitoring is dependable.
/// - **iOS/iPadOS** can only ask. `BGAppRefreshTask` is opportunistic: the system decides when,
///   often less than hourly, and never at all if the app is rarely opened. There is no
///   entitlement that changes this, so the UI labels iOS activations accordingly rather than
///   promising an interval it cannot keep.
///
/// Both platforms also evaluate on foreground, which is the only execution path that is
/// reliable everywhere.
@MainActor
final class MonitorScheduler {
    static let backgroundTaskIdentifier = "de.holgerkrupp.DB-Connect.monitors.refresh"

    private let container: ModelContainer
    private var timer: Timer?

    init(container: ModelContainer) {
        self.container = container
    }

    /// Check every minute; each activation's own `isDue` decides whether it actually runs.
    private static let tickInterval: TimeInterval = 60

    func start() {
        #if os(macOS)
        timer?.invalidate()
        let timer = Timer(timeInterval: Self.tickInterval, repeats: true) { [weak self] _ in
            Task { await self?.runDue() }
        }
        // .common keeps it firing while menus or window resizing block the default run loop mode.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        #endif

        Task { await runDue() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func runDue(force: Bool = false) async {
        let runner = MonitorRunner(modelContainer: container)
        await runner.runDue(force: force)
        WidgetSnapshotPublisher.publish(container: container)
    }

    // MARK: - iOS background refresh

    #if os(iOS)
    /// Must be called before the app finishes launching, or BGTaskScheduler traps.
    func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.backgroundTaskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else { return }
            self?.handle(refreshTask)
        }
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        // A floor, not a promise — iOS will not run it sooner, and may run it much later.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handle(_ task: BGAppRefreshTask) {
        // Always chain the next request first: if this run is killed, monitoring still continues.
        scheduleBackgroundRefresh()

        let work = Task {
            await runDue()
            task.setTaskCompleted(success: true)
        }

        task.expirationHandler = {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }
    #endif
}
