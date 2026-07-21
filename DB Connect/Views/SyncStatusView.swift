import SwiftUI
import CloudKitSyncMonitor

/// Compact iCloud sync indicator for the sidebar footer, with a popover of per-phase detail.
/// Backed by CloudKitSyncMonitor's `SyncMonitor.shared`.
struct SyncStatusView: View {
    @ObservedObject private var syncMonitor = SyncMonitor.shared
    @State private var showsDetail = false

    var body: some View {
        Button {
            showsDetail = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: syncMonitor.syncStateSummary.symbolName)
                    .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
                Text(summaryText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isSyncing {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        }
        .buttonStyle(.glass)
        .popover(isPresented: $showsDetail) {
            detail
                .padding()
                .frame(minWidth: 280)
        }
    }

    private var isSyncing: Bool {
        if case .inProgress = syncMonitor.importState { return true }
        if case .inProgress = syncMonitor.exportState { return true }
        return false
    }

    private var summaryText: String {
        isSyncing ? "Syncing…" : "iCloud"
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(syncMonitor.syncStateSummary.description)
            } icon: {
                Image(systemName: syncMonitor.syncStateSummary.symbolName)
                    .foregroundColor(syncMonitor.syncStateSummary.symbolColor)
            }
            .font(.headline)

            Divider()

            phaseRow("Setup", systemImage: "gearshape", state: syncMonitor.setupState)
            phaseRow("Upload", systemImage: "icloud.and.arrow.up", state: syncMonitor.exportState)
            phaseRow("Download", systemImage: "icloud.and.arrow.down", state: syncMonitor.importState)

            if isSyncing {
                // CloudKit reports no percentages, so this is honest indeterminate progress.
                ProgressView()
                    .progressViewStyle(.linear)
            }

            if let error = syncMonitor.lastError {
                Divider()
                Label {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
    }

    private func phaseRow(_ title: String, systemImage: String, state: SyncMonitor.SyncState) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(text(for: state))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func text(for state: SyncMonitor.SyncState) -> String {
        switch state {
        case .notStarted:
            "Not started"
        case .inProgress(let started):
            "Since \(started.formatted(date: .omitted, time: .shortened))"
        case .succeeded(_, let ended):
            "Done \(ended.formatted(date: .omitted, time: .shortened))"
        case .failed(_, let ended, _):
            "Failed \(ended.formatted(date: .omitted, time: .shortened))"
        }
    }
}
