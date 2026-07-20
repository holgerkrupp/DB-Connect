import Foundation

/// When a monitor should notify.
///
/// Pure value logic with no I/O, so every branch is directly testable — this is the part that
/// decides whether the user's phone buzzes at 3am, and it should never depend on a live database.
nonisolated struct MonitorRule: Sendable, Hashable {
    enum Kind: String, Sendable, Hashable, CaseIterable, Identifiable {
        case changed
        case changedByAtLeast
        case changedByPercent
        case above
        case below
        case returnsRows
        case noData

        var id: String { rawValue }

        var title: String {
            switch self {
            case .changed: "Value changes at all"
            case .changedByAtLeast: "Value changes by at least"
            case .changedByPercent: "Value changes by percent"
            case .above: "Value rises above"
            case .below: "Value falls below"
            case .returnsRows: "Query returns any rows"
            case .noData: "Query returns nothing"
            }
        }

        var usesThreshold: Bool {
            switch self {
            case .changedByAtLeast, .changedByPercent, .above, .below: true
            case .changed, .returnsRows, .noData: false
            }
        }
    }

    let kind: Kind
    let threshold: Double

    /// What a run produced.
    struct Observation: Sendable, Hashable {
        let value: Double?
        let rowCount: Int
    }

    /// Decide whether this observation should notify, given the previous value on *this* device.
    func fires(previous: Double?, observation: Observation) -> Bool {
        switch kind {
        case .returnsRows:
            return observation.rowCount > 0

        case .noData:
            return observation.rowCount == 0

        case .changed:
            guard let current = observation.value else { return false }
            guard let previous else { return false }   // first run establishes a baseline only
            return current != previous

        case .changedByAtLeast:
            guard let current = observation.value, let previous else { return false }
            return abs(current - previous) >= threshold

        case .changedByPercent:
            guard let current = observation.value, let previous else { return false }
            // A move away from zero is an infinite percentage; treat any change as qualifying
            // rather than dividing by zero.
            guard previous != 0 else { return current != 0 }
            return abs((current - previous) / previous) * 100 >= threshold

        case .above:
            guard let current = observation.value else { return false }
            // Edge-triggered: notify on the crossing, not on every run while it stays high.
            guard let previous else { return current > threshold }
            return current > threshold && previous <= threshold

        case .below:
            guard let current = observation.value else { return false }
            guard let previous else { return current < threshold }
            return current < threshold && previous >= threshold
        }
    }

    /// The notification body.
    func message(previous: Double?, observation: Observation) -> String {
        switch kind {
        case .returnsRows:
            return "\(observation.rowCount) row\(observation.rowCount == 1 ? "" : "s") returned"
        case .noData:
            return "The query returned no rows"
        default:
            guard let current = observation.value else { return "No value" }
            let currentText = Self.format(current)
            guard let previous else { return currentText }
            let delta = current - previous
            let sign = delta >= 0 ? "+" : "−"
            return "\(currentText) (\(sign)\(Self.format(abs(delta))) from \(Self.format(previous)))"
        }
    }

    private static func format(_ value: Double) -> String {
        value == value.rounded()
            ? String(Int64(value))
            : String(format: "%.2f", value)
    }
}

/// Time-of-day and repeat-rate suppression, applied after a rule fires.
nonisolated enum NotificationGate {
    /// Whether a notification may be delivered now.
    static func allows(
        now: Date = .now,
        lastNotifiedAt: Date?,
        cooldownMinutes: Int,
        quietHoursStart: Int,
        quietHoursEnd: Int,
        calendar: Calendar = .current
    ) -> Bool {
        if cooldownMinutes > 0, let lastNotifiedAt {
            if now.timeIntervalSince(lastNotifiedAt) < TimeInterval(cooldownMinutes * 60) {
                return false
            }
        }
        return !isQuiet(now: now, start: quietHoursStart, end: quietHoursEnd, calendar: calendar)
    }

    /// Quiet hours may wrap past midnight (22 → 7), so the comparison flips in that case.
    static func isQuiet(now: Date, start: Int, end: Int, calendar: Calendar = .current) -> Bool {
        guard start != end else { return false }
        let hour = calendar.component(.hour, from: now)
        return start < end
            ? (hour >= start && hour < end)
            : (hour >= start || hour < end)
    }
}
