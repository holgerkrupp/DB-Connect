import AppIntents
import Foundation
import UserNotifications

/// Local notification delivery for fired monitors.
nonisolated struct NotificationService: Sendable {

    enum DeliveryError: LocalizedError {
        case notAuthorized

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                "Notifications are disabled in System Settings."
            }
        }
    }

    /// Ask once. Returns false if the user has declined — callers should surface that rather
    /// than letting monitors appear to work while staying silent.
    @discardableResult
    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    static func isAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }

    static func send(title: String, body: String, monitorID: UUID) async throws {
        guard await isAuthorized() else { throw DeliveryError.notAuthorized }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        // One thread per monitor, so repeated alerts group instead of stacking up.
        content.threadIdentifier = monitorID.uuidString
        if #available(iOS 27.0, macOS 27.0, *) {
            // Lets Siri resolve "open it" or "turn that off" against the monitor that alerted.
            content.appEntityIdentifiers = [EntityIdentifier(for: MonitorEntity.self, identifier: monitorID)]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil    // deliver immediately
        )
        try await UNUserNotificationCenter.current().add(request)
    }
}
