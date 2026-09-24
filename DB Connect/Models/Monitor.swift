import Foundation
import SwiftData

/// The two scheduling behaviors a monitor can persist. Presets such as hourly and weekly are
/// interval schedules; a clock-time schedule runs once after that time on each calendar day.
nonisolated enum MonitorScheduleKind: String, Sendable, CaseIterable, Identifiable {
    case interval
    case dailyTime

    var id: String { rawValue }
}

/// A saved query that runs on a schedule and notifies when a condition fires.
///
/// The *definition* syncs via CloudKit and is device-agnostic. Whether it actually runs is a
/// per-device decision recorded in `MonitorActivation` — a monitor created on the Mac shows up
/// on the iPhone but stays dormant until that device opts in.
@Model
final class Monitor {
    var id: UUID = UUID()
    var title: String = ""
    var intervalMinutes: Int = 60
    var scheduleKindRaw: String = MonitorScheduleKind.interval.rawValue
    /// Minutes after midnight for a daily clock-time schedule.
    var scheduledMinuteOfDay: Int = 9 * 60
    var ruleType: String = MonitorRule.Kind.changedByAtLeast.rawValue
    var threshold: Double = 1
    /// Which result column to reduce to a number. Nil means the first column of the first row,
    /// which is what `SELECT COUNT(*)` produces.
    var comparisonColumn: String?
    /// Minutes to wait before notifying again for the same monitor.
    var cooldownMinutes: Int = 0
    /// Hour-of-day bounds during which notifications are suppressed. Equal values disable it.
    var quietHoursStart: Int = 0
    var quietHoursEnd: Int = 0
    var createdAt: Date = Date.now

    /// Notification body. Empty means "describe the rule", which is the phase-5 default.
    /// Tokens like `{{value}}` and `{{newest}}` are filled at delivery time — see
    /// `NotificationTemplate`.
    var messageTemplate: String = ""

    var query: SavedQuery?

    @Relationship(deleteRule: .cascade, inverse: \MonitorActivation.monitor)
    var activations: [MonitorActivation]? = []

    /// Extra queries whose results fill template tokens.
    @Relationship(deleteRule: .cascade, inverse: \MonitorField.monitor)
    var fields: [MonitorField]? = []

    init(title: String, query: SavedQuery?) {
        self.title = title
        self.query = query
    }

    var rule: MonitorRule {
        MonitorRule(kind: MonitorRule.Kind(rawValue: ruleType) ?? .changed, threshold: threshold)
    }

    var interval: TimeInterval {
        TimeInterval(max(1, intervalMinutes) * 60)
    }

    var scheduleKind: MonitorScheduleKind {
        get { MonitorScheduleKind(rawValue: scheduleKindRaw) ?? .interval }
        set { scheduleKindRaw = newValue.rawValue }
    }

    var scheduleDescription: String {
        switch scheduleKind {
        case .dailyTime:
            let minutes = min(max(scheduledMinuteOfDay, 0), 1439)
            var components = DateComponents()
            components.hour = minutes / 60
            components.minute = minutes % 60
            let time = Calendar.current.date(from: components)?.formatted(date: .omitted, time: .shortened)
                ?? String(format: "%02d:%02d", minutes / 60, minutes % 60)
            return "daily at \(time)"
        case .interval:
            switch intervalMinutes {
            case 60: return "every hour"
            case 360: return "every 6 hours"
            case 720: return "every 12 hours"
            case 1_440: return "every day"
            case 10_080: return "every week"
            default:
                if intervalMinutes.isMultiple(of: 1_440) {
                    let days = intervalMinutes / 1_440
                    return "every \(days) days"
                }
                if intervalMinutes.isMultiple(of: 60) {
                    let hours = intervalMinutes / 60
                    return "every \(hours) hours"
                }
                return "every \(intervalMinutes) minutes"
            }
        }
    }

    /// The activation belonging to this device, if the user ever touched it here.
    func activation(for deviceID: String) -> MonitorActivation? {
        activations?.first { $0.deviceID == deviceID }
    }

    /// Opts a device in or out. The activation row is created lazily, so a device that never
    /// opts in does not clutter every monitor with an empty record.
    func setEnabled(_ isEnabled: Bool, on device: DeviceIdentity.Snapshot, in context: ModelContext) {
        if let existing = activation(for: device.id) {
            existing.isEnabled = isEnabled
            // Re-enabling starts a fresh baseline; a stale one would produce a bogus first delta.
            if !isEnabled {
                existing.lastValue = nil
                existing.consecutiveFailureCount = 0
                existing.lastErrorMessage = nil
            }
        } else if isEnabled {
            let activation = MonitorActivation(device: device, isEnabled: true)
            activation.monitor = self
            context.insert(activation)
        }
    }

    var enabledDeviceNames: [String] {
        (activations ?? []).filter(\.isEnabled).map(\.deviceName).sorted()
    }
}

/// One device's participation in a monitor — and its own state.
///
/// `lastValue` and `samples` live here rather than on `Monitor` on purpose. If two devices shared
/// one baseline, whichever ran first would consume the change and the other would see "no
/// difference", silently breaking every delta-based rule.
@Model
final class MonitorActivation {
    var id: UUID = UUID()
    var deviceID: String = ""
    var deviceName: String = ""
    /// "iphone" | "ipad" | "mac" — drives the SF Symbol in the device list.
    var deviceKind: String = ""
    var isEnabled: Bool = false
    var lastValue: Double?
    /// The last successful database check. Failed attempts do not move this date forward.
    var lastRunAt: Date?
    /// Used for short failure backoff without making a failed hourly monitor wait another hour.
    var lastAttemptAt: Date?
    var consecutiveFailureCount: Int = 0
    var lastNotifiedAt: Date?
    /// Set when a run could not happen — most often the credentials have not synced here yet.
    var lastErrorMessage: String?

    var monitor: Monitor?

    @Relationship(deleteRule: .cascade, inverse: \MonitorSample.activation)
    var samples: [MonitorSample]? = []

    init(device: DeviceIdentity.Snapshot, isEnabled: Bool = true) {
        self.deviceID = device.id
        self.deviceName = device.name
        self.deviceKind = device.kind
        self.isEnabled = isEnabled
    }

    var isDue: Bool {
        isDue(at: .now)
    }

    /// Kept as a function with injectable time/calendar so calendar-day behavior remains easy to
    /// verify. If the app was closed at the chosen time, the first later scheduler tick catches up.
    func isDue(at now: Date, calendar: Calendar = .current) -> Bool {
        guard isEnabled else { return false }
        guard let monitor else { return false }

        switch monitor.scheduleKind {
        case .interval:
            if consecutiveFailureCount > 0, let lastAttemptAt {
                return now.timeIntervalSince(lastAttemptAt) >= retryInterval
            }
            guard let lastRunAt else { return true }
            return now.timeIntervalSince(lastRunAt) >= monitor.interval

        case .dailyTime:
            let minuteOfDay = min(max(monitor.scheduledMinuteOfDay, 0), 1439)
            guard let scheduledToday = calendar.date(
                bySettingHour: minuteOfDay / 60,
                minute: minuteOfDay % 60,
                second: 0,
                of: now
            ), now >= scheduledToday else { return false }
            if let lastRunAt, lastRunAt >= scheduledToday { return false }
            if consecutiveFailureCount > 0,
               let lastAttemptAt,
               lastAttemptAt >= scheduledToday {
                return now.timeIntervalSince(lastAttemptAt) >= retryInterval
            }
            return true
        }
    }

    /// Failures retry quickly, but repeated scheduler ticks cannot hammer an unavailable server.
    /// Exponential backoff tops out at 15 minutes and never exceeds the configured interval.
    var retryInterval: TimeInterval {
        let exponent = min(max(consecutiveFailureCount - 1, 0), 4)
        let retry = TimeInterval(60 * (1 << exponent))
        return min(retry, monitor?.interval ?? retry)
    }

    func recordAttempt(at date: Date = .now) {
        lastAttemptAt = date
    }

    func recordSuccess(at date: Date = .now) {
        lastRunAt = date
        lastAttemptAt = date
        consecutiveFailureCount = 0
        lastErrorMessage = nil
    }

    func recordFailure(_ message: String, at date: Date = .now) {
        lastAttemptAt = date
        consecutiveFailureCount += 1
        lastErrorMessage = message
    }

    var symbolName: String {
        switch deviceKind {
        case "mac": "laptopcomputer"
        case "ipad": "ipad"
        default: "iphone"
        }
    }

    /// Recent samples, oldest first, for the history chart.
    func recentSamples(limit: Int = 40) -> [MonitorSample] {
        (samples ?? []).sorted { $0.at < $1.at }.suffix(limit)
    }
}

/// Binds a named template token to a query result.
///
/// The token `newest` pointing at "SELECT MAX(created_at) FROM tickets" turns `{{newest}}` in
/// the message into that date — which is how one notification can summarise several queries.
@Model
final class MonitorField {
    var id: UUID = UUID()
    /// Token name without braces, e.g. "newest".
    var token: String = ""
    /// Which column of the result to take. Nil means the first column of the first row.
    var column: String?
    var formatRaw: String = FieldFormat.automatic.rawValue
    var sortOrder: Int = 0

    var monitor: Monitor?
    var query: SavedQuery?

    init(token: String, query: SavedQuery?) {
        self.token = token
        self.query = query
    }

    var format: FieldFormat {
        FieldFormat(rawValue: formatRaw) ?? .automatic
    }
}

@Model
final class MonitorSample {
    var at: Date = Date.now
    var value: Double = 0
    /// True when this sample triggered a notification, so the chart can mark it.
    var didFire: Bool = false

    var activation: MonitorActivation?

    init(value: Double, didFire: Bool) {
        self.at = .now
        self.value = value
        self.didFire = didFire
    }
}
