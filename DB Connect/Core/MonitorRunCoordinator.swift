import Foundation
import SwiftData

/// Serializes monitor execution across timers, foreground refreshes, shortcuts, and UI buttons.
/// Without one process-wide gate, two entry points can read the same baseline and send the same
/// notification twice.
actor MonitorRunCoordinator {
    static let shared = MonitorRunCoordinator()

    private struct ActiveRun {
        let id: UUID
        let task: Task<MonitorRunSummary, Never>
    }

    private var activeRun: ActiveRun?

    func run(
        container: ModelContainer,
        force: Bool = false,
        monitorID: UUID? = nil,
        shouldStop: @escaping @Sendable () -> Bool = { false },
        onProgress: (@Sendable (_ completed: Int, _ total: Int) async -> Void)? = nil
    ) async -> MonitorRunSummary {
        if let activeRun {
            return await activeRun.task.value
        }

        let id = UUID()
        let task = Task {
            let runner = MonitorRunner(modelContainer: container)
            if let monitorID {
                return await runner.run(monitorID: monitorID)
            }
            return await runner.runDue(
                force: force,
                shouldStop: shouldStop,
                onProgress: onProgress
            )
        }
        activeRun = ActiveRun(id: id, task: task)

        let result = await task.value
        if activeRun?.id == id {
            activeRun = nil
        }
        return result
    }
}
