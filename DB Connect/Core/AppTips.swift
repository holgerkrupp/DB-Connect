import SwiftUI
import TipKit

/// In-context tips for features that are useful but easy to miss. Onboarding covers the
/// essentials; a tip appears only once someone is in a position to use its feature, and goes away
/// for good after they have — help for something a person already does is just noise.
enum AppTips {
    static func configure() {
        #if DEBUG
        // Launch with -DBConnectResetTips to see every tip again while developing.
        if CommandLine.arguments.contains("-DBConnectResetTips") {
            try? Tips.resetDatastore()
        }
        #endif
        do {
            try Tips.configure([
                // At most one new tip a day, so tips never pile up on a single screen.
                .displayFrequency(.daily),
                // Tip state follows the user the way connections do, so a tip dismissed on the
                // Mac is not shown again on the iPad.
                .cloudKitContainer(.named("iCloud.de.holgerkrupp.DB-Connect"))
            ])
        } catch {
            print("TipKit configuration failed: \(error)")
        }
    }
}

/// Points at the Queries button once someone has run a few statements by hand, which is when
/// keeping one as a favorite starts to pay off.
struct FavoriteTabTriggerTip: Tip {
    static let queryRun = Tips.Event(id: "sqlConsole.queryRun")

    var title: Text {
        Text("Save Queries You Run Often")
    }

    var message: Text? {
        Text("Save a statement as a favorite and give it a tab trigger. Type the trigger in the editor and press Tab to insert the whole query.")
    }

    var image: Image? {
        Image(systemName: "text.badge.star")
    }

    var rules: [Rule] {
        #Rule(Self.queryRun) { $0.donations.count >= 3 }
    }
}

/// Replaces the permanent caption that used to explain inline editing: it disappears once the
/// person has staged their first change.
struct InlineCellEditingTip: Tip {
    var title: Text {
        Text("Edit Right in the Grid")
    }

    var message: Text? {
        #if os(macOS)
        Text("Click a cell to change its value, or double-click a row to open the full editor. Nothing is written until you review and apply your changes.")
        #else
        Text("Tap a cell to change its value, or double-tap a row to open the full editor. Nothing is written until you review and apply your changes.")
        #endif
    }

    var image: Image? {
        Image(systemName: "pencil.line")
    }
}

/// Monitors are only useful if their results are seen. The menu bar extra (Mac) and widgets
/// (iPhone and iPad) do that without opening the app, but both are otherwise found only in
/// Settings or the system's widget gallery.
struct MonitorGlanceTip: Tip {
    @Parameter static var hasEnabledMonitor: Bool = false

    #if os(macOS)
    static let showInMenuBarActionID = "show-in-menu-bar"

    var title: Text {
        Text("Watch Monitors from the Menu Bar")
    }

    var message: Text? {
        Text("See the latest monitor results without switching to DB Connect.")
    }

    var actions: [Action] {
        [Action(id: Self.showInMenuBarActionID, title: "Show in Menu Bar")]
    }
    #else
    var title: Text {
        Text("Add a Monitor Widget")
    }

    var message: Text? {
        Text("See monitor results at a glance on your Home Screen or Lock Screen.")
    }
    #endif

    var image: Image? {
        Image(systemName: "bell.badge")
    }

    var rules: [Rule] {
        #Rule(Self.$hasEnabledMonitor) { $0 == true }
    }
}
