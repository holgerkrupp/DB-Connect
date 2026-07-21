import SwiftUI
import SwiftData

/// Composes the notification body: a preset or free-form template, the extra queries that fill
/// its tokens, and a live preview built from sample values.
struct NotificationTemplateEditor: View {
    @Binding var template: String
    @Binding var fields: [FieldDraft]
    let savedQueries: [SavedQuery]

    @State private var messageStyle: MessageStyle = .automatic
    @State private var showsAdditionalData = false

    /// Editing happens on drafts, not on `MonitorField` models, so cancelling a sheet leaves
    /// nothing behind in the store.
    struct FieldDraft: Identifiable, Hashable {
        var id = UUID()
        var token: String = ""
        var query: SavedQuery?
        var column: String = ""
        var format: FieldFormat = .automatic
    }

    private enum MessageStyle: Hashable {
        case automatic
        case preset(String)
        case custom
    }

    var body: some View {
        Section {
            Picker("Message", selection: $messageStyle) {
                Text("Automatic description").tag(MessageStyle.automatic)
                ForEach(NotificationTemplate.presets) { preset in
                    Text(preset.title).tag(MessageStyle.preset(preset.template))
                }
                Text("Write my own…").tag(MessageStyle.custom)
            }

            if messageStyle == .custom {
                TextField("Notification text", text: $template, axis: .vertical)
                    .lineLimit(2...4)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
            }

            LabeledContent("Preview") {
                Text(preview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }

            additionalDataEditor
        } header: {
            Text("Notification")
        } footer: {
            Text(notificationFooter)
        }
        .onAppear(perform: syncFromTemplate)
        .onChange(of: messageStyle) { _, style in apply(style) }
        .onChange(of: template) { _, newValue in
            // Once the user chose a custom message, its text should never silently switch the
            // picker back to a preset just because it happens to match one.
            guard messageStyle != .custom, !newValue.isEmpty else { return }
            if let preset = NotificationTemplate.presets.first(where: { $0.template == newValue }) {
                messageStyle = .preset(preset.template)
            } else {
                messageStyle = .custom
            }
        }
        .onChange(of: fields) { _, newValue in
            if !newValue.isEmpty { showsAdditionalData = true }
        }
    }

    private var additionalDataEditor: some View {
        DisclosureGroup(isExpanded: $showsAdditionalData) {
            ForEach($fields) { $field in
                NotificationFieldEditor(field: $field, savedQueries: savedQueries) {
                    fields.removeAll { $0.id == field.id }
                }
            }

            Button("Add Query Result", systemImage: "plus") {
                fields.append(FieldDraft(token: suggestedToken))
            }

            Text(fieldsFooter)
                .font(.footnote)
                .foregroundStyle(unresolvedTokens.isEmpty ? Color.secondary : Color.orange)
        } label: {
            Text(additionalDataLabel)
        }
    }

    private var additionalDataLabel: String {
        fields.isEmpty
            ? "Include data from another query (optional)"
            : "Additional query data (\(fields.count))"
    }

    private var notificationFooter: String {
        switch messageStyle {
        case .automatic:
            "DB Connect will describe what changed. You do not need to write a message."
        case .preset:
            "The preview uses sample data. The real values are inserted when the notification is sent."
        case .custom:
            "Use placeholders such as {{value}}, {{previous}}, {{delta}}, {{rows}}, {{time}}, or {{date}}."
        }
    }

    /// Selecting a preset also creates drafts for the extra tokens it expects, so the user is not
    /// left with a template referencing data that resolves to nothing.
    private func apply(_ style: MessageStyle) {
        switch style {
        case .automatic:
            template = ""
        case .custom:
            break
        case .preset(let value):
            guard let preset = NotificationTemplate.presets.first(where: { $0.template == value }) else {
                return
            }
            template = preset.template
            for token in preset.suggestedFields where !fields.contains(where: { $0.token == token }) {
                fields.append(FieldDraft(token: token))
            }
        }
    }

    private func syncFromTemplate() {
        if template.isEmpty {
            messageStyle = .automatic
        } else if let preset = NotificationTemplate.presets.first(where: { $0.template == template }) {
            messageStyle = .preset(preset.template)
        } else {
            messageStyle = .custom
        }
        showsAdditionalData = !fields.isEmpty
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
            return "Add a query result named \(unresolvedTokens.map { "{{\($0)}}" }.joined(separator: ", ")) to fill this placeholder."
        }
        return "Optional: each item runs a saved query only when a notification is sent, then inserts its result into a matching placeholder."
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

private struct NotificationFieldEditor: View {
    @Binding var field: NotificationTemplateEditor.FieldDraft
    let savedQueries: [SavedQuery]
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Additional query result")
                    .font(.callout.weight(.medium))
                Spacer()
                Button("Remove", systemImage: "trash", role: .destructive, action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }

            TextField("Name used in message", text: $field.token)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif

            Picker("Saved query", selection: $field.query) {
                Text("Choose query…").tag(Optional<SavedQuery>.none)
                ForEach(savedQueries) { query in
                    Text(query.title).tag(Optional(query))
                }
            }

            TextField("Result column (optional)", text: $field.column)
                .autocorrectionDisabled()

            Picker("Format", selection: $field.format) {
                ForEach(FieldFormat.allCases) { format in
                    Text(format.title).tag(format)
                }
            }
        }
        .padding(.vertical, 4)
    }
}
