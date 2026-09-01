import Foundation
import SwiftData

/// Executes due monitors for this device.
///
/// A `ModelActor` so it can own its own `ModelContext` off the main actor — background runs must
/// not touch the UI's context. Only activations belonging to `DeviceIdentity.identifier` are
/// considered, which is what keeps two devices from consuming each other's baselines.
@ModelActor
actor MonitorRunner {

    /// Run every activation that is due on this device. Returns how many fired a notification.
    @discardableResult
    func runDue(force: Bool = false) async -> Int {
        let deviceID = DeviceIdentity.identifier

        let descriptor = FetchDescriptor<MonitorActivation>(
            predicate: #Predicate { $0.deviceID == deviceID && $0.isEnabled }
        )
        guard let activations = try? modelContext.fetch(descriptor) else { return 0 }

        var fired = 0
        for activation in activations where force || activation.isDue {
            if await run(activation) { fired += 1 }
        }
        try? modelContext.save()
        return fired
    }

    /// Run one activation. Returns true if it notified.
    @discardableResult
    func run(_ activation: MonitorActivation) async -> Bool {
        guard let monitor = activation.monitor,
              let query = monitor.query,
              let connection = query.connection else {
            activation.lastErrorMessage = "This monitor is missing its query or connection."
            return false
        }

        activation.lastRunAt = .now

        do {
            let observation = try await observe(query: query, connection: connection, monitor: monitor)
            activation.lastErrorMessage = nil

            let previous = activation.lastValue
            let didFire = monitor.rule.fires(previous: previous, observation: observation)

            let allowed = NotificationGate.allows(
                lastNotifiedAt: activation.lastNotifiedAt,
                cooldownMinutes: monitor.cooldownMinutes,
                quietHoursStart: monitor.quietHoursStart,
                quietHoursEnd: monitor.quietHoursEnd
            )

            let sample = MonitorSample(value: observation.value ?? 0, didFire: didFire && allowed)
            sample.activation = activation
            modelContext.insert(sample)
            pruneSamples(for: activation)

            // The baseline advances whether or not the notification was suppressed — otherwise a
            // quiet-hours window would make the next delta measure against a stale value.
            activation.lastValue = observation.value

            if didFire && allowed {
                activation.lastNotifiedAt = .now
                // Only resolve the extra template queries once we know we are going to notify —
                // no point running them on every quiet check.
                let body = await composeMessage(
                    monitor: monitor,
                    previous: previous,
                    observation: observation
                )
                await NotificationService.send(
                    title: monitor.title.isEmpty ? "Monitor" : monitor.title,
                    body: body,
                    monitorID: monitor.id
                )
                return true
            }
            return false

        } catch {
            // A credential that has not synced to this device yet is the common case, and it
            // deserves a clearer message than the driver's own.
            if case DatabaseError.missingCredentials = error {
                activation.lastErrorMessage = "Waiting for this connection's credentials to sync to this device."
            } else {
                activation.lastErrorMessage = error.localizedDescription
            }
            return false
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
        return MonitorRule.Observation(
            value: result.scalar(column: monitor.comparisonColumn),
            rowCount: result.rows.count
        )
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
