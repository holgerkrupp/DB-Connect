import SwiftData
import SwiftUI

/// Keeps WidgetKit's privacy-safe snapshot in step with CloudKit and local edits.
struct WidgetSnapshotSyncView: View {
    @Query private var monitors: [Monitor]
    @Query private var queries: [SavedQuery]

    private var revision: Int {
        var hasher = Hasher()
        for query in queries {
            hasher.combine(query.id)
            hasher.combine(query.title)
            hasher.combine(query.database)
            hasher.combine(query.connection?.name)
        }
        for monitor in monitors {
            let activation = monitor.activation(for: DeviceIdentity.identifier)
            hasher.combine(monitor.id)
            hasher.combine(monitor.title)
            hasher.combine(monitor.query?.id)
            hasher.combine(activation?.isEnabled)
            hasher.combine(activation?.lastValue)
            hasher.combine(activation?.lastRunAt)
            hasher.combine(activation?.lastNotifiedAt)
            hasher.combine(activation?.lastErrorMessage)
        }
        return hasher.finalize()
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task(id: revision) {
                WidgetSnapshotPublisher.publish(monitors: monitors, queries: queries)
            }
    }
}
