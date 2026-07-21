import SwiftUI

/// Column designer for `CREATE TABLE`.
///
/// The generated SQL is shown live rather than hidden behind the form. Creating a table is not
/// undoable, and the statement is the thing that actually runs — a user who knows SQL can check
/// it before committing, and one who doesn't learns what the form means.
struct NewTableView: View {
    let session: any DatabaseSession
    /// Used only to spell the preview correctly; the session does the real generation.
    let dialect: SQLDialect
    let schema: String?
    /// Called after a successful create so the caller can refresh its table list.
    let onCreate: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var columns: [NewColumn] = [
        NewColumn(name: "id", type: .integer, isNullable: false, isPrimaryKey: true, isAutoIncrement: true),
        NewColumn(name: "", type: .text)
    ]
    @State private var isCreating = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Table") {
                    TextField("Name", text: $name)
                        .autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                }

                Section {
                    ForEach($columns) { $column in
                        ColumnDesignerRow(column: $column) {
                            columns.removeAll { $0.id == column.id }
                        }
                    }
                    .onDelete { columns.remove(atOffsets: $0) }

                    Button("Add Column", systemImage: "plus") {
                        columns.append(NewColumn())
                    }
                } header: {
                    Text("Columns")
                } footer: {
                    Text("A primary key lets rows be edited later. Tables without one open read-only.")
                }

                Section("SQL") {
                    Text(preview)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(previewIsError ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("New Table")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(!isValid || isCreating)
                }
            }
            .overlay {
                if isCreating {
                    DatabaseLoadingView("Creating table…", size: 34)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 680, idealWidth: 760, minHeight: 560, idealHeight: 640)
        #endif
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespaces)
    }

    private var namedColumns: [NewColumn] {
        columns.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private var isValid: Bool {
        !trimmedName.isEmpty && !namedColumns.isEmpty
    }

    private var spec: NewTableSpec {
        NewTableSpec(name: trimmedName, schema: schema, columns: namedColumns)
    }

    private var previewIsError: Bool {
        !isValid || (try? SQLDDLBuilder.createTable(spec, dialect: dialect)) == nil
    }

    private var preview: String {
        guard isValid else { return "Name the table and at least one column." }
        do {
            return try SQLDDLBuilder.createTable(spec, dialect: dialect).sql
        } catch {
            return error.localizedDescription
        }
    }

    private func create() async {
        isCreating = true
        errorMessage = nil
        do {
            try await session.createTable(spec)
            onCreate(trimmedName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
        isCreating = false
    }
}

/// One column's settings. Laid out as a two-line row rather than a table so it stays usable on
/// iOS, where a spreadsheet-style grid of controls is unworkable.
private struct ColumnDesignerRow: View {
    @Binding var column: NewColumn
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Column name", text: $column.name)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif

                Picker("Type", selection: $column.type) {
                    ForEach(ColumnType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 160)

                if column.type.usesLength {
                    TextField("255", value: $column.length, format: .number)
                        .frame(width: 60)
                        #if os(iOS)
                        .keyboardType(.numberPad)
                        #endif
                }

                Button("Remove", systemImage: "minus.circle.fill", action: onDelete)
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Toggle("Primary key", isOn: $column.isPrimaryKey)
                    .onChange(of: column.isPrimaryKey) { _, isKey in
                        // A key column is NOT NULL by definition; every engine enforces it, so
                        // reflect it rather than letting the form claim otherwise.
                        if isKey { column.isNullable = false } else { column.isAutoIncrement = false }
                    }

                if column.isPrimaryKey && column.type.supportsAutoIncrement {
                    Toggle("Auto-increment", isOn: $column.isAutoIncrement)
                }

                Toggle("Required", isOn: Binding(
                    get: { !column.isNullable },
                    set: { column.isNullable = !$0 }
                ))
                .disabled(column.isPrimaryKey)

                if !column.isPrimaryKey {
                    Toggle("Unique", isOn: $column.isUnique)
                }

                Spacer(minLength: 8)

                TextField("Default", text: $column.defaultValue)
                    .frame(width: 120)
                    .disabled(column.isAutoIncrement)
            }
            .toggleStyle(.checkbox)
            .font(.callout)
        }
        .padding(.vertical, 4)
    }
}

#if !os(macOS)
/// `.checkbox` is macOS-only; on iOS the switch style is the native equivalent.
private extension ToggleStyle where Self == SwitchToggleStyle {
    static var checkbox: SwitchToggleStyle { .switch }
}
#endif
