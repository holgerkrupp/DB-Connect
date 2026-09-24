import Foundation
import SwiftData

nonisolated struct MonitorRunSummary: Sendable, Equatable {
    var total = 0
    var attempted = 0
    var succeeded = 0
    var fired = 0
    var failureMessages: [String] = []
    var wasCancelled = false

    var failed: Int { failureMessages.count }

    var message: String {
        if wasCancelled {
            return "Stopped after checking \(attempted) of \(total) monitors."
        }
        if failed > 0 {
            if attempted == 0, let failure = failureMessages.first { return failure }
            return "Checked \(attempted) monitor\(attempted == 1 ? "" : "s"); \(failed) failed."
        }
        if total == 0 { return "No enabled monitors to check on this device." }
        if fired > 0 {
            return "Checked \(succeeded) monitor\(succeeded == 1 ? "" : "s") and sent \(fired) alert\(fired == 1 ? "" : "s")."
        }
        return "Checked \(succeeded) monitor\(succeeded == 1 ? "" : "s"). Everything is up to date."
    }
}

private nonisolated enum MonitorRunOutcome: Sendable {
    case completed
    case fired
    case failed(String)
}

/// Executes due monitors for this device.
///
/// A `ModelActor` so it can own its own `ModelContext` off the main actor — background runs must
/// not touch the UI's context. Only activations belonging to `DeviceIdentity.identifier` are
/// considered, which is what keeps two devices from consuming each other's baselines.
@ModelActor
actor MonitorRunner {

    /// Check one enabled monitor on this device, regardless of when it is next due.
    func run(monitorID: UUID) async -> MonitorRunSummary {
        let deviceID = DeviceIdentity.identifier
        let descriptor = FetchDescriptor<MonitorActivation>(
            predicate: #Predicate { $0.deviceID == deviceID && $0.isEnabled }
        )

        do {
            let activations = try modelContext.fetch(descriptor)
            guard let activation = activations.first(where: { $0.monitor?.id == monitorID }) else {
                return MonitorRunSummary(failureMessages: ["This monitor is not enabled on this device."])
            }

            var summary = MonitorRunSummary(total: 1, attempted: 1)
            switch await run(activation) {
            case .completed:
                summary.succeeded = 1
            case .fired:
                summary.succeeded = 1
                summary.fired = 1
            case .failed(let message):
                summary.failureMessages = [message]
            }
            try? modelContext.save()
            return summary
        } catch {
            return MonitorRunSummary(failureMessages: [error.localizedDescription])
        }
    }

    /// Run every activation that is due on this device and report what actually happened.
    ///
    /// `shouldStop` and `onProgress` exist for the Run Monitors intent: the system only keeps
    /// extending a long-running intent while its progress moves, and a cancelled run should keep
    /// the results it already has rather than discard them.
    @discardableResult
    func runDue(
        force: Bool = false,
        shouldStop: @Sendable () -> Bool = { false },
        onProgress: (@Sendable (_ completed: Int, _ total: Int) async -> Void)? = nil
    ) async -> MonitorRunSummary {
        let deviceID = DeviceIdentity.identifier

        let descriptor = FetchDescriptor<MonitorActivation>(
            predicate: #Predicate { $0.deviceID == deviceID && $0.isEnabled }
        )
        let activations: [MonitorActivation]
        do {
            activations = try modelContext.fetch(descriptor)
        } catch {
            return MonitorRunSummary(failureMessages: [error.localizedDescription])
        }

        let due = activations.filter { force || $0.isDue }
        await onProgress?(0, due.count)

        var summary = MonitorRunSummary(total: due.count)
        for (index, activation) in due.enumerated() {
            if Task.isCancelled || shouldStop() {
                summary.wasCancelled = true
                break
            }
            summary.attempted += 1
            switch await run(activation) {
            case .completed:
                summary.succeeded += 1
            case .fired:
                summary.succeeded += 1
                summary.fired += 1
            case .failed(let message):
                summary.failureMessages.append(message)
            }
            // Persist after each remote round trip. A cancelled multi-monitor run keeps every
            // result it already completed instead of relying on reaching the end of the loop.
            try? modelContext.save()
            await onProgress?(index + 1, due.count)
        }
        try? modelContext.save()
        return summary
    }

    /// Run one activation. Returns whether it completed, notified, or failed.
    @discardableResult
    private func run(_ activation: MonitorActivation) async -> MonitorRunOutcome {
        let attemptedAt = Date.now
        activation.recordAttempt(at: attemptedAt)

        guard let monitor = activation.monitor,
              let query = monitor.query,
              let connection = query.connection else {
            let message = "This monitor is missing its query or connection."
            activation.recordFailure(message, at: attemptedAt)
            return .failed(message)
        }

        do {
            let observation = try await observe(query: query, connection: connection, monitor: monitor)
            activation.recordSuccess(at: .now)

            let previous = activation.lastValue
            let didFire = monitor.rule.fires(previous: previous, observation: observation)

            let allowed = NotificationGate.allows(
                lastNotifiedAt: activation.lastNotifiedAt,
                cooldownMinutes: monitor.cooldownMinutes,
                quietHoursStart: monitor.quietHoursStart,
                quietHoursEnd: monitor.quietHoursEnd
            )

            let sample = MonitorSample(value: observation.value ?? 0, didFire: false)
            sample.activation = activation
            modelContext.insert(sample)
            pruneSamples(for: activation)

            if didFire && allowed {
                // Only resolve the extra template queries once we know we are going to notify —
                // no point running them on every quiet check.
                let body = await composeMessage(
                    monitor: monitor,
                    previous: previous,
                    observation: observation
                )
                do {
                    try await NotificationService.send(
                        title: monitor.title.isEmpty ? "Monitor" : monitor.title,
                        body: body,
                        monitorID: monitor.id
                    )
                    sample.didFire = true
                    activation.lastNotifiedAt = .now
                    activation.lastValue = observation.value
                    return .fired
                } catch {
                    // Keep the old comparison baseline so an edge-triggered condition can retry
                    // after notification permission or delivery is repaired.
                    let message = "The query succeeded, but the alert could not be delivered: \(error.localizedDescription)"
                    activation.recordFailure(message, at: attemptedAt)
                    return .failed(message)
                }
            }

            // A suppressed alert still advances the baseline; quiet hours and cooldowns should
            // not make the next comparison use stale data.
            activation.lastValue = observation.value
            return .completed

        } catch {
            // A credential that has not synced to this device yet is the common case, and it
            // deserves a clearer message than the driver's own.
            if case DatabaseError.missingCredentials = error {
                let message = "Waiting for this connection's credentials to sync to this device."
                activation.recordFailure(message, at: attemptedAt)
                return .failed(message)
            } else {
                let message = error.localizedDescription
                activation.recordFailure(message, at: attemptedAt)
                return .failed(message)
            }
        }
    }

    /// Build the notification body, filling any template tokens from their own queries.
    ///
    /// A field whose query fails degrades to "—" rather than losing the whole notification:
    /// knowing the count changed is still useful even if the "newest" lookup timed out.
    private func composeMessage(
        monitor: Monitor,
        previous: Double?,
        observation: MonitorRule.Observation
    ) async -> String {
        let template = monitor.messageTemplate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else {
            return monitor.rule.message(previous: previous, observation: observation)
        }

        var resolved: [String: String] = [:]
        let referenced = Set(NotificationTemplate.tokens(in: template))

        for field in (monitor.fields ?? []).sorted(by: { $0.sortOrder < $1.sortOrder }) {
            guard referenced.contains(field.token) else { continue }
            resolved[field.token] = await resolve(field) ?? "—"
        }

        return NotificationTemplate.render(
            template,
            context: NotificationTemplate.Context(
                value: observation.value,
                previous: previous,
                rowCount: observation.rowCount,
                fields: resolved
            )
        )
    }

    private func resolve(_ field: MonitorField) async -> String? {
        guard let query = field.query,
              let connection = query.connection,
              let driver = DriverRegistry.driver(for: connection.driverID) else { return nil }

        do {
            let config = config(for: query, on: connection)
            let storedSecret = try KeychainSecretStore().secret(for: connection.id)
            let secret = try ConnectionRuntimeSecretResolver.resolve(config: config, secret: storedSecret)
            let session = try await driver.connect(config: config, secret: secret)
            let result: ResultSet
            do {
                result = try await session.query(Statement(query.sql))
            } catch {
                await session.close()
                return nil
            }
            await session.close()
            guard let row = result.rows.first else { return nil }

            let value: SQLValue
            if let column = field.column,
               let index = result.columns.firstIndex(where: { $0.name == column }),
               row.indices.contains(index) {
                value = row[index]
            } else {
                value = row.first ?? .null
            }
            return field.format.render(value)
        } catch {
            return nil
        }
    }

    private func observe(
        query: SavedQuery,
        connection: Connection,
        monitor: Monitor
    ) async throws -> MonitorRule.Observation {
        guard let driver = DriverRegistry.driver(for: connection.driverID) else {
            throw DatabaseError.unsupported("Unknown driver “\(connection.driverID)”.")
        }

        let config = config(for: query, on: connection)
        let storedSecret = try KeychainSecretStore().secret(for: connection.id)
        let secret = try ConnectionRuntimeSecretResolver.resolve(config: config, secret: storedSecret)
        if driver.capabilities.requiresCredentials && secret == nil {
            throw DatabaseError.missingCredentials
        }

        let session = try await driver.connect(config: config, secret: secret)
        let result: ResultSet
        do {
            result = try await session.query(Statement(query.sql))
        } catch {
            await session.close()
            throw error
        }
        await session.close()
        let value = result.scalar(column: monitor.comparisonColumn)
        if monitor.rule.kind.readsValue, value == nil {
            let message: String
            if let column = monitor.comparisonColumn, !column.isEmpty {
                message = "The result column “\(column)” is missing or is not numeric."
            } else {
                message = "The first value returned by the query is missing or is not numeric."
            }
            throw DatabaseError.queryFailed(sql: query.sql, message: message)
        }
        return MonitorRule.Observation(value: value, rowCount: result.rows.count)
    }

    /// The connection config to dial for a saved query, with its recorded database selected.
    ///
    /// A server-level connection (typically MySQL) has no database of its own, so it is chosen at
    /// connect time from what the query was saved against. This also covers PostgreSQL, which binds
    /// a connection to one database for its lifetime and so cannot `USE` another after connecting.
    /// An empty `query.database` leaves the connection's own value untouched — the right default for
    /// file-based drivers and connections already bound to a single database.
    private func config(for query: SavedQuery, on connection: Connection) -> ConnectionConfig {
        var config = connection.config
        if !query.database.isEmpty {
            config.database = query.database
        }
        return config
    }

    /// Keep history bounded — this syncs through CloudKit, and an hourly monitor would otherwise
    /// accumulate thousands of records a year.
    private func pruneSamples(for activation: MonitorActivation, keeping limit: Int = 200) {
        let samples = (activation.samples ?? []).sorted { $0.at > $1.at }
        guard samples.count > limit else { return }
        for stale in samples.dropFirst(limit) {
            modelContext.delete(stale)
        }
    }
}
