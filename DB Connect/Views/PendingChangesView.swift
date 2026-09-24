import SwiftUI

/// The confirmation step between editing and writing.
///
/// Nothing reaches the database until the user has seen exactly what will run — the generated
/// statements, with their bound values, in order.
struct PendingChangesView: View {
    let mutations: [RowMutation]
    let statements: [String]
    let isAtomic: Bool
    let onCommit: () -> Void
    let onDiscard: (RowMutation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isCommitting = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(mutations.enumerated()), id: \.element.id) { index, mutation in
                        VStack(alignment: .leading, spacing: 4) {
                            Label(mutation.summary, systemImage: icon(for: mutation.kind))
                                .font(.callout.weight(.medium))
                            if index < statements.count {
                                Text(statements[index])
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 2)
                        .swipeActions {
                            Button("Discard", role: .destructive) { onDiscard(mutation) }
                        }
                    }
                } header: {
                    Text("\(mutations.count) pending change\(mutations.count == 1 ? "" : "s")")
                } footer: {
                    Text(isAtomic
                         ? "These run in a single transaction — if any statement fails, none of them are applied."
                         : "This connection has no transactions. Changes are sent one at a time, so a failure part-way through leaves earlier changes applied.")
                }
            }
            .navigationTitle("Review Changes")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isCommitting ? "Applying…" : "Apply") {
                        isCommitting = true
                        onCommit()
                    }
                    .disabled(mutations.isEmpty || isCommitting)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 380)
        #endif
    }

    private func icon(for kind: RowMutation.Kind) -> String {
        switch kind {
        case .insert: "plus.circle"
        case .update: "pencil.circle"
        case .delete: "minus.circle"
        }
    }
}
