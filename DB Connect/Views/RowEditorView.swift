import SwiftUI

/// Edits one row as a form.
///
/// A form rather than an inline grid cell: it works identically on iPhone, and it gives room to
/// show each column's type and NULL state, which a spreadsheet cell cannot.
struct RowEditorView: View {
    let table: TableDescriptor
    /// Existing values keyed by column; empty when inserting.
    let original: [String: SQLValue]
    let isInsert: Bool
    let onCommit: (RowMutation) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: [String: SQLValue] = [:]
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                ForEach(table.columns) { column in
                    columnEditor(for: column)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isInsert ? "New Row" : "Edit Row")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commit() }
                        .disabled(changedValues.isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 380)
        #endif
        .onAppear { draft = original }
    }

    @ViewBuilder
    private func columnEditor(for column: ColumnDescriptor) -> some View {
        // Primary keys are the row's identity: changing one turns an update into "delete the
        // old row and insert a different one", which is not what a cell edit implies.
        let isLocked = column.isPrimaryKey && !isInsert
        let value = draft[column.name] ?? .null

        Section {
            if isLocked {
                LabeledContent(column.name) {
                    Text(value.displayText).foregroundStyle(.secondary)
                }
            } else {
                TextField(
                    column.name,
                    text: Binding(
                        get: { value.isNull ? "" : value.displayText },
                        set: { draft[column.name] = parse($0, for: column) }
                    )
                )
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

                if column.isNullable {
                    Toggle("NULL", isOn: Binding(
                        get: { (draft[column.name] ?? .null).isNull },
                        set: { draft[column.name] = $0 ? .null : .text("") }
                    ))
                    .font(.caption)
                }
            }
        } header: {
            HStack(spacing: 4) {
                if column.isPrimaryKey {
                    Image(systemName: "key.fill").foregroundStyle(.orange).font(.caption2)
                }
                Text(column.name)
                Text(column.declaredType.lowercased())
                    .foregroundStyle(.secondary)
                if isLocked {
                    Spacer()
                    Text("key — not editable").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .textCase(nil)
        }
    }

    /// Convert typed text back into a value the column can hold.
    ///
    /// Declared types are only a hint — SQLite in particular allows anything anywhere — so a
    /// value that will not parse as a number is kept as text rather than silently zeroed.
    private func parse(_ text: String, for column: ColumnDescriptor) -> SQLValue {
        let type = column.declaredType.lowercased()

        if type.contains("int") {
            return Int64(text).map { .integer($0) } ?? .text(text)
        }
        if type.contains("real") || type.contains("double") || type.contains("float") {
            return Double(text).map { .double($0) } ?? .text(text)
        }
        if type.contains("bool") {
            switch text.lowercased() {
            case "true", "t", "1", "yes": return .bool(true)
            case "false", "f", "0", "no": return .bool(false)
            default: return .text(text)
            }
        }
        return .text(text)
    }

    private var changedValues: [String: SQLValue] {
        if isInsert {
            return draft.filter { !$0.value.isNull }
        }
        return draft.filter { column, value in original[column] != value }
    }

    private var primaryKeyValues: [String: SQLValue] {
        // Always taken from the original row, never the draft, so a stray edit cannot
        // repoint the statement at a different row.
        Dictionary(uniqueKeysWithValues: table.primaryKey.compactMap { column in
            original[column].map { (column, $0) }
        })
    }

    private func commit() {
        let changes = changedValues
        guard !changes.isEmpty else { return dismiss() }

        if isInsert {
            onCommit(.insert(values: changes))
        } else {
            guard !primaryKeyValues.isEmpty else {
                errorMessage = "This row cannot be identified, so it cannot be edited."
                return
            }
            onCommit(.update(primaryKey: primaryKeyValues, values: changes))
        }
        dismiss()
    }
}
