import SwiftUI
import WidgetKit

@main
struct DBConnectWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MonitorWidget()
        SavedQueriesWidget()
    }
}
