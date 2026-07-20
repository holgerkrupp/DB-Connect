import SwiftUI
import SwiftData

/// Composes the notification body: a preset or free-form template, the extra queries that fill
/// its tokens, and a live preview built from sample values.
struct NotificationTemplateEditor: View {
    @Binding var template: String
    @Binding var fields: [FieldDraft]
    let savedQueries: [SavedQuery]

    /// Editing happens on drafts, not on `MonitorField` models, so cancelling a sheet leaves
    /// nothing behind in the store.
    struct FieldDraft: Identifiable, Hashable {
        var id = UUID()
        var token: String = ""
        var query: SavedQuery?
        var column: String = ""
        var format: FieldFormat = .automatic
    }

    var body: some View {
        Section {
            Picker("Preset", selection: presetBinding) {
                Text("Custom").tag(Optional<String>.none)
                ForEach(NotificationTemplate.presets) { preset in
                    Text(preset.title).tag(Optional(preset.template))
                }
            }

            TextField("Message", text: $template, axis: .vertical)
                .lineLimit(2...4)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            LabeledContent("Preview") {
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        } header: {
            Text("Notification")
        } footer: {
            Text("Leave the message empty to use the automatic description. Insert values with {{token}} — built in: \(NotificationTemplate.builtInTokens.map { "{{\($0)}}" }.joined(separator: ", ")).")
        }

        Section {
            ForEach($fields) { $field in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("token", text: $field.token)
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .frame(maxWidth: 120)
                        Text("→").foregroundStyle(.secondary)
                        Picker("", selection: $field.query) {
                            Text("Choose query…").tag(Optional<SavedQuery>.none)
                            ForEach(savedQueries) { query in
                                Text(query.title).tag(Optional(query))
                            }
                        }
                        .labelsHidden()
                    }
                    HStack {
                        TextField("column (optional)", text: $field.column)
                            .autocorrectionDisabled()
                            .font(.caption)
                        Picker("", selection: $field.format) {
                            ForEach(FieldFormat.allCases) { format in
                                Text(format.title).tag(format)
                            }
                        }
                        .labelsHidden()
                        .font(.caption)
                    }
                }
                .padding(.vertical, 2)
            }
            .onDelete { fields.remove(atOffsets: $0) }

            Button("Add Value", systemImage: "plus") {
                fields.append(FieldDraft(token: suggestedToken))
            }
        } header: {
            Text("Values")
        } footer: {
            Text(fieldsFooter)
        }
    }

    /// Selecting a preset also creates drafts for the tokens it expects, so the user is not
    /// left with a template referencing values that resolve to nothing.
    private var presetBinding: Binding<String?> {
        Binding(
            get: { NotificationTemplate.presets.first { $0.template == template }?.template },
            set: { newValue in
                guard let newValue,
                      let preset = NotificationTemplate.presets.first(where: { $0.template == newValue })
                else { return }
                template = preset.template
                for token in preset.suggestedFields where !fields.contains(where: { $0.token == token }) {
                    fields.append(FieldDraft(token: token))
                }
            }
        )
    }

    private var suggestedToken: String {
        let used = Set(fields.map(\.token))
        return NotificationTemplate.tokens(in: template)
            .first { !NotificationTemplate.builtInTokens.contains($0) && !used.contains($0) }
            ?? ""
    }

    /// Tokens the message uses that nothing will fill.
    private var unresolvedTokens: [String] {
        let provided = Set(fields.map(\.token)).union(NotificationTemplate.builtInTokens)
        return NotificationTemplate.tokens(in: template).filter { !provided.contains($0) }
    }

    private var fieldsFooter: String {
        if !unresolvedTokens.isEmpty {
            return "Nothing fills \(unresolvedTokens.map { "{{\($0)}}" }.joined(separator: ", ")) yet — add a value with that name."
        }
        return "Each value runs its own saved query when the notification fires. If one fails, it shows as “—” and the rest still arrive."
    }

    /// Preview with plausible stand-in values, so the shape of the message is visible before it fires.
    private var preview: String {
        guard !template.trimmingCharacters(in: .whitespaces).isEmpty else {
            return "Automatic description"
        }
        var sampleFields: [String: String] = [:]
        for field in fields where !field.token.isEmpty {
            sampleFields[field.token] = switch field.format {
            case .date: Date.now.formatted(date: .numeric, time: .omitted)
            case .dateTime: Date.now.formatted(date: .numeric, time: .shortened)
            case .number: "17"
            default: "sample"
            }
        }
        return NotificationTemplate.render(
            template,
            context: NotificationTemplate.Context(
                value: 142,
                previous: 135,
                rowCount: 142,
                fields: sampleFields
            )
        )
    }
}
