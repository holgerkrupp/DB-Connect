import Foundation
import Observation
import SwiftUI

/// A single hand-off point for App Intents and widget deep links.
///
/// The request stays pending until the destination view consumes it. This matters at launch:
/// `ContentView` can select a connection before its detail view exists, then the detail loads the
/// saved query once SwiftUI has created it.
@MainActor
@Observable
final class AppNavigation {
    static let shared = AppNavigation()

    struct Request: Identifiable, Equatable {
        let id = UUID()
        let destination: Destination
    }

    enum Destination: Equatable {
        case savedQuery(UUID)
        case monitor(UUID)
        case monitors
        case runMonitors
    }

    private(set) var request: Request?

    private init() {}

    func open(_ destination: Destination) {
        request = Request(destination: destination)
    }

    func handle(_ url: URL) {
        guard url.scheme == "db-connect" else { return }

        switch url.host {
        case "query":
            if let id = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:)) {
                open(.savedQuery(id))
            }
        case "monitor":
            if let id = url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:)) {
                open(.monitor(id))
            } else {
                open(.monitors)
            }
        case "run-monitors":
            open(.runMonitors)
        default:
            break
        }
    }

    func consume(_ requestID: UUID) {
        guard request?.id == requestID else { return }
        request = nil
    }
}

extension EnvironmentValues {
    @Entry var appNavigation = AppNavigation.shared
}
