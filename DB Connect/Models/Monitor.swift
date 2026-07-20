import Foundation
import SwiftData

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

    /// The activation belonging to this device, if the user ever touched it here.
    func activation(for deviceID: String) -> MonitorActivation? {
        activations?.first { $0.deviceID == deviceID }
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
    var lastRunAt: Date?
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
        guard isEnabled else { return false }
        guard let lastRunAt, let monitor else { return true }
        return Date.now.timeIntervalSince(lastRunAt) >= monitor.interval
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
