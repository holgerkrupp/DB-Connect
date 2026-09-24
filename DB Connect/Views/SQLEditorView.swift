import SwiftUI
import TipKit

/// SQL text editor with keyword colouring and schema-aware completion.
///
/// Built on the `AttributedString` `TextEditor` (macOS 26 / iOS 26) so highlighting is applied
/// as attributes on the user's own text rather than by drawing a second, overlaid copy — the
/// overlay approach drifts out of alignment as soon as wrapping or fonts disagree.
struct SQLEditorView: View {
    @Bindable var draft: ConsoleDraft
    /// Schema for completion. Empty is fine — the editor then suggests keywords only.
    var tables: [TableDescriptor]
    var favorites: [QueryFavorite]
    var favoriteContext: QueryFavoriteContext

    @State private var attributed = AttributedString()
    @State private var selection = AttributedTextSelection()
    @State private var completion: SQLAutocomplete.Context?
    @State private var highlightedIndex = 0
    /// Set while we are rewriting `attributed` ourselves, so the resulting change notification
    /// isn't mistaken for the user typing (which would re-open the popover we just closed).
    @State private var isApplyingEdit = false

    @AppStorage(AppSettings.Key.syntaxHighlighting) private var syntaxHighlighting = true
    @AppStorage(AppSettings.Key.autocompleteEnabled) private var autocompleteEnabled = true
    @AppStorage(AppSettings.Key.highlightIdentifierIssues) private var highlightIssues = true

    /// Names that don't match the schema, underlined in the editor and offered as fixes.
    private var issues: [SQLIdentifierCorrection.Issue] {
        guard highlightIssues else { return [] }
        return SQLIdentifierCorrection.issues(in: String(attributed.characters), tables: tables)
    }

    var body: some View {
        TextEditor(text: $attributed, selection: $selection)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
            .scrollContentBackground(.hidden)
            .padding(4)
            .background(.quaternary.opacity(0.25))
            .overlay(alignment: .topLeading) { placeholder }
            .overlay(alignment: .bottomLeading) { completionList }
            .onKeyPress(keys: [.upArrow, .downArrow, .return, .tab, .escape], action: handleKey)
            .task(id: draft.sql) {
                // Adopt external changes (a saved query being loaded) without clobbering the
                // text the user is actively editing.
                guard String(attributed.characters) != draft.sql else { return }
                isApplyingEdit = true
                attributed = SQLSyntax.highlighted(draft.sql, colored: syntaxHighlighting)
                isApplyingEdit = false
            }
            .onChange(of: draft.pendingFavoriteInsertion?.id) { _, _ in
                guard let request = draft.pendingFavoriteInsertion else { return }
                applyFavoriteInsertion(request)
            }
            .onChange(of: attributed) { _, _ in
                draft.sql = String(attributed.characters)
                rehighlight()
                if isApplyingEdit {
                    completion = nil
                } else {
                    updateCompletion()
                }
            }
    }

    @ViewBuilder
    private var placeholder: some View {
        if attributed.characters.isEmpty {
            Text("SELECT * FROM …")
                .font(.body.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.top, 12)
                .padding(.leading, 9)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var completionList: some View {
        if let completion {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(completion.items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        accept(item)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: icon(for: item.kind))
                                .foregroundStyle(color(for: item.kind))
                                .frame(width: 14)
                            Text(item.text).font(.body.monospaced())
                            Spacer(minLength: 12)
                            if let detail = item.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .contentShape(.rect)
                        .background(index == highlightedIndex ? Color.accentColor.opacity(0.2) : .clear)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: 320, alignment: .leading)
            .background(.regularMaterial, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            .shadow(radius: 8, y: 2)
            .padding(8)
        }
    }

    private func icon(for kind: SQLSuggestion.Kind) -> String {
        switch kind {
        case .keyword: "curlybraces"
        case .table: "tablecells"
        case .column: "rectangle.split.3x1"
        }
    }

    private func color(for kind: SQLSuggestion.Kind) -> Color {
        switch kind {
        case .keyword: .blue
        case .table: .orange
        case .column: .teal
        }
    }

    /// Re-colour in place. Only attributes change, so the caret does not move.
    private func rehighlight() {
        var copy = attributed
        SQLSyntax.applyHighlighting(to: &copy, colored: syntaxHighlighting, issues: issues)
        if copy != attributed {
            isApplyingEdit = true
            attributed = copy
            isApplyingEdit = false
        }
    }

    /// A collapsed caret is reported as `.insertionPoint` in some states and as a single empty
    /// range in others, so both are treated as a caret. A real (non-empty) selection returns nil:
    /// completing over selected text would silently replace it.
    private var cursorOffset: Int? {
        func offset(of index: AttributedString.Index) -> Int {
            attributed.characters.distance(from: attributed.startIndex, to: index)
        }
        switch selection.indices(in: attributed) {
        case .insertionPoint(let index):
            return offset(of: index)
        case .ranges(let ranges):
            let all = ranges.ranges
            guard let last = all.last, all.count == 1, last.isEmpty else { return nil }
            return offset(of: last.upperBound)
        @unknown default:
            return nil
        }
    }

    private func updateCompletion() {
        guard autocompleteEnabled else {
            completion = nil
            return
        }
        guard let offset = cursorOffset else {
            completion = nil
            return
        }
        let sql = String(attributed.characters)
        guard let cursor = sql.index(sql.startIndex, offsetBy: offset, limitedBy: sql.endIndex) else {
            completion = nil
            return
        }
        completion = SQLAutocomplete.suggest(in: sql, at: cursor, tables: tables)
        highlightedIndex = 0
    }

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if let completion {
            switch press.key {
            case .escape:
                self.completion = nil
                return .handled
            case .upArrow:
                highlightedIndex = max(0, highlightedIndex - 1)
                return .handled
            case .downArrow:
                highlightedIndex = min(completion.items.count - 1, highlightedIndex + 1)
                return .handled
            case .return, .tab:
                // ⌘↩ runs the query; a bare Return with the list open accepts the selection.
                if press.key == .return, press.modifiers.contains(.command) { return .ignored }
                accept(completion.items[highlightedIndex])
                return .handled
            default:
                return .ignored
            }
        }

        switch press.key {
        case .tab:
            return expandTabTrigger() ? .handled : .ignored
        default:
            return .ignored
        }
    }

    private func accept(_ item: SQLSuggestion) {
        guard let completion else { return }
        var sql = String(attributed.characters)
        guard let lower = sql.index(sql.startIndex, offsetBy: completion.replacementOffsets.lowerBound, limitedBy: sql.endIndex),
              let upper = sql.index(sql.startIndex, offsetBy: completion.replacementOffsets.upperBound, limitedBy: sql.endIndex)
        else { return }

        sql.replaceSubrange(lower..<upper, with: item.text)
        let caret = completion.replacementOffsets.lowerBound + item.text.count

        isApplyingEdit = true
        attributed = SQLSyntax.highlighted(sql, colored: syntaxHighlighting)
        draft.sql = sql
        if let index = attributed.characters.index(attributed.startIndex, offsetBy: caret, limitedBy: attributed.endIndex) {
            selection = AttributedTextSelection(range: index..<index)
        }
        isApplyingEdit = false
        self.completion = nil
    }

    private var selectedOffsets: Range<Int>? {
        func offset(of index: AttributedString.Index) -> Int {
            attributed.characters.distance(from: attributed.startIndex, to: index)
        }
        switch selection.indices(in: attributed) {
        case .insertionPoint(let index):
            let point = offset(of: index)
            return point..<point
        case .ranges(let ranges):
            guard let last = ranges.ranges.last, ranges.ranges.count == 1 else { return nil }
            return offset(of: last.lowerBound)..<offset(of: last.upperBound)
        @unknown default:
            return nil
        }
    }

    private func applyFavoriteInsertion(_ request: QueryFavoriteInsertionRequest) {
        defer { draft.pendingFavoriteInsertion = nil }

        let expansion = QueryFavoriteExpander.expand(request.sql, context: favoriteContext)
        let sql = String(attributed.characters)
        let replacementRange: Range<Int>

        switch request.mode {
        case .replaceEditor:
            replacementRange = 0..<sql.count
        case .insertAtCursor:
            replacementRange = selectedOffsets ?? (sql.count..<sql.count)
        }

        guard let lower = sql.index(sql.startIndex, offsetBy: replacementRange.lowerBound, limitedBy: sql.endIndex),
              let upper = sql.index(sql.startIndex, offsetBy: replacementRange.upperBound, limitedBy: sql.endIndex)
        else { return }

        var updated = sql
        updated.replaceSubrange(lower..<upper, with: expansion.text)

        let baseOffset = replacementRange.lowerBound
        let selectedRange = expansion.selectedRange ?? (expansion.cursorOffset.map { $0..<$0 })
        let finalSelection = selectedRange.map { (baseOffset + $0.lowerBound)..<(baseOffset + $0.upperBound) }
            ?? (baseOffset + expansion.text.count)..<(baseOffset + expansion.text.count)

        isApplyingEdit = true
        attributed = SQLSyntax.highlighted(updated, colored: syntaxHighlighting)
        draft.sql = updated
        applySelection(finalSelection)
        isApplyingEdit = false
        completion = nil
        draft.favoriteNotice = request.mode == .insertAtCursor
            ? "Inserted favorite \(request.title)"
            : "Loaded favorite \(request.title)"
    }

    private func expandTabTrigger() -> Bool {
        guard let cursor = cursorOffset else { return false }
        let sql = String(attributed.characters)
        guard let triggerRange = tabTriggerRange(in: sql, cursorOffset: cursor) else { return false }
        let trigger = String(sql[triggerRange])
        guard let favorite = QueryFavoriteExpander.favorite(matching: trigger, in: favorites) else { return false }

        let expansion = QueryFavoriteExpander.expand(favorite.sql, context: favoriteContext)
        let lowerOffset = sql.distance(from: sql.startIndex, to: triggerRange.lowerBound)
        let upperOffset = sql.distance(from: sql.startIndex, to: triggerRange.upperBound)
        guard let lower = sql.index(sql.startIndex, offsetBy: lowerOffset, limitedBy: sql.endIndex),
              let upper = sql.index(sql.startIndex, offsetBy: upperOffset, limitedBy: sql.endIndex)
        else { return false }

        var updated = sql
        updated.replaceSubrange(lower..<upper, with: expansion.text)
        let baseOffset = lowerOffset
        let selectedRange = expansion.selectedRange ?? (expansion.cursorOffset.map { $0..<$0 })
        let finalSelection = selectedRange.map { (baseOffset + $0.lowerBound)..<(baseOffset + $0.upperBound) }
            ?? (baseOffset + expansion.text.count)..<(baseOffset + expansion.text.count)

        isApplyingEdit = true
        attributed = SQLSyntax.highlighted(updated, colored: syntaxHighlighting)
        draft.sql = updated
        applySelection(finalSelection)
        isApplyingEdit = false
        completion = nil
        draft.favoriteNotice = "Expanded favorite \(favorite.title)"
        FavoriteTabTriggerTip().invalidate(reason: .actionPerformed)
        return true
    }

    private func tabTriggerRange(in sql: String, cursorOffset: Int) -> Range<String.Index>? {
        guard cursorOffset > 0,
              let cursor = sql.index(sql.startIndex, offsetBy: cursorOffset, limitedBy: sql.endIndex)
        else {
            return nil
        }

        var start = cursor
        while start > sql.startIndex {
            let previous = sql.index(before: start)
            let character = sql[previous]
            guard character.isLetter || character.isNumber || character == "_" else { break }
            start = previous
        }

        guard start < cursor else { return nil }
        let token = sql[start..<cursor]
        guard token.count >= 2 else { return nil }
        return start..<cursor
    }

    private func applySelection(_ offsets: Range<Int>) {
        guard let lower = attributed.characters.index(attributed.startIndex, offsetBy: offsets.lowerBound, limitedBy: attributed.endIndex),
              let upper = attributed.characters.index(attributed.startIndex, offsetBy: offsets.upperBound, limitedBy: attributed.endIndex)
        else {
            return
        }
        selection = AttributedTextSelection(range: lower..<upper)
    }
}
