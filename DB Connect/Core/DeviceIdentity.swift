import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A stable identifier for *this* device.
///
/// Deliberately stored in local `UserDefaults` and never synced: it is what lets a device
/// recognise its own `MonitorActivation` rows among everyone else's. `identifierForVendor`
/// is not used because it changes when the app is reinstalled, which would silently orphan
/// every activation this device owns.
nonisolated enum DeviceIdentity {
    struct Snapshot: Sendable, Hashable {
        let id: String
        let name: String
        let kind: String
    }

    private static let storageKey = "de.holgerkrupp.DB-Connect.deviceID"

    static var current: Snapshot {
        Snapshot(id: identifier, name: name, kind: kind)
    }

    static var identifier: String {
        if let existing = UserDefaults.standard.string(forKey: storageKey) {
            return existing
        }
        let fresh = UUID().uuidString
        UserDefaults.standard.set(fresh, forKey: storageKey)
        return fresh
    }

    static var name: String {
        #if os(macOS)
        Host.current().localizedName ?? "Mac"
        #else
        MainActor.assumeIsolated { UIDevice.current.name }
        #endif
    }

    static var kind: String {
        #if os(macOS)
        "mac"
        #else
        MainActor.assumeIsolated {
            UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        }
        #endif
    }
}
