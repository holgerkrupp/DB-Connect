import SwiftUI

/// Edit one column filter: which column, which comparison, and the value.
struct FilterEditorView: View {
    @State var filter: ColumnFilter
    let columns: [ColumnDescriptor]
    let onSave: (ColumnFilter) -> Void

    @Environment(\.dismiss) private var dismiss

    private var column: ColumnDescriptor? {
        columns.first { $0.name == filter.column }
    }

    private var availableOperators: [FilterOperator] {
        column.map { FilterOperator.options(for: $0) } ?? FilterOperator.allCases
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Column", selection: $filter.column) {
                        ForEach(columns) { column in
                            Text(column.name).tag(column.name)
                        }
                    }
                    Picker("Condition", selection: $filter.op) {
                        ForEach(availableOperators) { op in
                            Text(op.title).tag(op)
                        }
                    }
                    if filter.op.needsValue {
                        TextField("Value", text: $filter.value)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                    }
                } footer: {
                    if let column {
                        Text(footerText(for: column))
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Filter")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onSave(filter)
                        dismiss()
                    }
                    .disabled(!filter.isReady)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 260)
        #endif
        .onChange(of: filter.column) { _, _ in
            // A different column may not support the current comparison.
            if !availableOperators.contains(filter.op) {
                filter.op = availableOperators.first ?? .equals
            }
        }
    }

    private func footerText(for column: ColumnDescriptor) -> String {
        if column.isOrderable {
            return "\(column.name) is \(column.declaredType.lowercased()) — comparisons are numeric, not alphabetical."
        }
        if filter.op.isComparison {
            return "Comparisons on text columns sort alphabetically."
        }
        return "Matching ignores case. % and _ are treated as ordinary characters."
    }
}
