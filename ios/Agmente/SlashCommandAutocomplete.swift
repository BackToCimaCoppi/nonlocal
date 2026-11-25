import SwiftUI
import ACPClient

/// Active slash command fragment around the current insertion caret.
struct SlashCommandToken: Equatable, Sendable {
    let range: Range<String.Index>
    let slashUTF16Offset: Int
    let query: String
}

/// Result of inserting or replacing a slash command inside the prompt text.
struct SlashCommandInsertionResult: Equatable, Sendable {
    let text: String
    let cursorUTF16Offset: Int
}

/// Pure parsing, filtering, safe UTF-16 selection mapping, and text-insertion helpers for inline slash commands.
enum SlashCommandAutocomplete {
    private static func alignedUTF16Offset(of index: String.Index, in text: String) -> Int? {
        guard index >= text.startIndex,
              index <= text.endIndex,
              let aligned = index.samePosition(in: text) else {
            return nil
        }
        return aligned.utf16Offset(in: text)
    }

    private static func selectionUpperBoundUTF16Offset(
        in text: String,
        from selection: TextSelection?,
        requireEmptyRange: Bool
    ) -> Int? {
        guard let selection else { return nil }
        switch selection.indices {
        case .selection(let range):
            if requireEmptyRange && !range.isEmpty {
                return nil
            }
            return alignedUTF16Offset(of: range.upperBound, in: text)
        case .multiSelection:
            return nil
        @unknown default:
            return nil
        }
    }

    /// Returns the aligned UTF-16 offset only for a single empty insertion caret.
    /// Returns `nil` when `selection` is `nil`, non-empty (text highlight), multi-selection, or unaligned.
    static func insertionUTF16Offset(in text: String, from selection: TextSelection?) -> Int? {
        selectionUpperBoundUTF16Offset(in: text, from: selection, requireEmptyRange: true)
    }

    /// Returns the aligned UTF-16 offset for the upper bound of a single selection (caret or highlight).
    /// Returns `nil` when `selection` is `nil` so callers can preserve a pre-blur cursor cache.
    static func selectionEndUTF16Offset(in text: String, from selection: TextSelection?) -> Int? {
        selectionUpperBoundUTF16Offset(in: text, from: selection, requireEmptyRange: false)
    }

    private static func safeStringIndex(atUTF16Offset offset: Int, in text: String) -> String.Index {
        let utf16Count = text.utf16.count
        var pos = min(max(0, offset), utf16Count)
        while pos > 0 {
            let candidate = String.Index(utf16Offset: pos, in: text)
            if let aligned = candidate.samePosition(in: text) {
                return aligned < text.endIndex
                    ? text.rangeOfComposedCharacterSequence(at: aligned).lowerBound
                    : text.endIndex
            }
            pos -= 1
        }
        return text.startIndex
    }

    /// Converts an arbitrary UTF-16 offset into a safe grapheme-aligned `TextSelection(insertionPoint:)`.
    static func selection(atUTF16Offset offset: Int, in text: String) -> TextSelection {
        TextSelection(insertionPoint: safeStringIndex(atUTF16Offset: offset, in: text))
    }

    private static func isCommandCharacter(_ ch: Character) -> Bool {
        guard let ascii = ch.asciiValue else { return false }
        return (ascii >= 0x41 && ascii <= 0x5A) // A-Z
            || (ascii >= 0x61 && ascii <= 0x7A) // a-z
            || (ascii >= 0x30 && ascii <= 0x39) // 0-9
            || ascii == 0x2D                    // -
            || ascii == 0x5F                    // _
    }

    private static func isBoundaryCharacter(_ ch: Character) -> Bool {
        ch == " " || ch == "\n"
    }

    private static func hasValidLeftBoundary(beforeSlash slashIndex: String.Index, in text: String) -> Bool {
        guard slashIndex > text.startIndex else { return true }
        return isBoundaryCharacter(text[text.index(before: slashIndex)])
    }

    /// Detects a valid `/command` token at `utf16CursorOffset`, scanning both left and right across ASCII `[A-Za-z0-9_-]`
    /// to support whole-token replacement while rejecting paths/filenames containing `/`, `.`, or punctuation.
    static func activeToken(in text: String, utf16CursorOffset: Int?) -> SlashCommandToken? {
        guard let utf16CursorOffset else { return nil }
        let cursorIndex = safeStringIndex(atUTF16Offset: utf16CursorOffset, in: text)

        var tokenStart = cursorIndex
        while tokenStart > text.startIndex {
            let prev = text.index(before: tokenStart)
            if isCommandCharacter(text[prev]) {
                tokenStart = prev
            } else {
                break
            }
        }

        guard tokenStart > text.startIndex else { return nil }
        let slashIndex = text.index(before: tokenStart)
        guard text[slashIndex] == "/" else { return nil }
        guard hasValidLeftBoundary(beforeSlash: slashIndex, in: text) else { return nil }

        let slashAfter = text.index(after: slashIndex)
        guard cursorIndex > slashAfter else { return nil }

        var tokenEnd = cursorIndex
        while tokenEnd < text.endIndex && isCommandCharacter(text[tokenEnd]) {
            tokenEnd = text.index(after: tokenEnd)
        }
        guard tokenEnd == text.endIndex || isBoundaryCharacter(text[tokenEnd]) else {
            return nil
        }

        return SlashCommandToken(
            range: slashIndex..<tokenEnd,
            slashUTF16Offset: slashIndex.utf16Offset(in: text),
            query: String(text[slashAfter..<cursorIndex])
        )
    }

    /// Filters commands case-insensitively with deduplication (preserving first occurrence),
    /// grouping prefix matches ahead of substring matches and sorting each tier A–Z ascending.
    static func filter(_ commands: [SessionCommand], query: String) -> [SessionCommand] {
        guard !query.isEmpty else { return [] }
        let loweredQuery = query.lowercased()
        var seenLowercasedNames: Set<String> = []
        var prefixMatches: [SessionCommand] = []
        var containsMatches: [SessionCommand] = []

        for command in commands {
            let loweredName = command.name.lowercased()
            guard seenLowercasedNames.insert(loweredName).inserted else { continue }
            if loweredName.hasPrefix(loweredQuery) {
                prefixMatches.append(command)
            } else if loweredName.contains(loweredQuery) {
                containsMatches.append(command)
            }
        }

        let ascendingByName: (SessionCommand, SessionCommand) -> Bool = { lhs, rhs in
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if order != .orderedSame {
                return order == .orderedAscending
            }
            return lhs.name < rhs.name
        }
        prefixMatches.sort(by: ascendingByName)
        containsMatches.sort(by: ascendingByName)

        return prefixMatches + containsMatches
    }

    /// Inserts or replaces a slash command at the current/cached cursor offset using one unified path
    /// that prevents duplicate trailing spaces, avoids unnecessary leading spaces after whitespace/start,
    /// and cleanly replaces a boundary-valid isolated `"/"` when triggered outside an active token.
    static func insertCommand(
        _ commandName: String,
        into text: String,
        utf16CursorOffset: Int?,
        replacing activeToken: SlashCommandToken?
    ) -> SlashCommandInsertionResult {
        let targetRange: Range<String.Index>
        let needsLeadingSpace: Bool

        if let activeToken,
           let lower = activeToken.range.lowerBound.samePosition(in: text),
           let upper = activeToken.range.upperBound.samePosition(in: text),
           lower <= upper {
            targetRange = lower..<upper
            needsLeadingSpace = false
        } else {
            let cursorIndex = safeStringIndex(
                atUTF16Offset: utf16CursorOffset ?? text.utf16.count,
                in: text
            )
            if let isolatedSlash = isolatedSlashRangeBeforeCursor(in: text, cursorIndex: cursorIndex) {
                targetRange = isolatedSlash
                needsLeadingSpace = false
            } else {
                targetRange = cursorIndex..<cursorIndex
                if cursorIndex > text.startIndex {
                    needsLeadingSpace = !text[text.index(before: cursorIndex)].isWhitespace
                } else {
                    needsLeadingSpace = false
                }
            }
        }

        return applyReplacement(
            commandName,
            into: text,
            replacing: targetRange,
            needsLeadingSpace: needsLeadingSpace
        )
    }

    private static func isolatedSlashRangeBeforeCursor(
        in text: String,
        cursorIndex: String.Index
    ) -> Range<String.Index>? {
        guard cursorIndex > text.startIndex else { return nil }
        let slashIndex = text.index(before: cursorIndex)
        guard text[slashIndex] == "/" else { return nil }
        guard hasValidLeftBoundary(beforeSlash: slashIndex, in: text) else { return nil }
        guard cursorIndex == text.endIndex || isBoundaryCharacter(text[cursorIndex]) else {
            return nil
        }
        return slashIndex..<cursorIndex
    }

    private static func applyReplacement(
        _ commandName: String,
        into text: String,
        replacing targetRange: Range<String.Index>,
        needsLeadingSpace: Bool
    ) -> SlashCommandInsertionResult {
        let hasTrailingSpace = targetRange.upperBound < text.endIndex
            && text[targetRange.upperBound] == " "
        let leading = needsLeadingSpace ? " " : ""
        let trailing = hasTrailingSpace ? "" : " "
        let inserted = "\(leading)/\(commandName)\(trailing)"

        var updated = text
        updated.replaceSubrange(targetRange, with: inserted)

        let prefixUTF16Count = text[..<targetRange.lowerBound].utf16.count
        let cursorOffset = prefixUTF16Count
            + inserted.utf16.count
            + (hasTrailingSpace ? 1 : 0)

        return SlashCommandInsertionResult(text: updated, cursorUTF16Offset: cursorOffset)
    }
}

/// Floating suggestion card rendered above the composer without shifting layout or stealing focus.
struct SlashCommandSuggestionsView: View {
    let commands: [SessionCommand]
    let dismissTokenOffset: Int
    let onSelect: (SessionCommand) -> Void
    let onDismiss: (Int) -> Void

    @State private var rowsHeight: CGFloat = 0

    private var needsScrolling: Bool {
        rowsHeight > 176
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Choose Skill / Command")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    onDismiss(dismissTokenOffset)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss slash command suggestions")
                .accessibilityIdentifier("acp-slash-dismiss-button")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()

            if needsScrolling {
                ScrollView(.vertical) {
                    measuredSuggestionRows
                }
                .frame(height: 176)
            } else {
                measuredSuggestionRows
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(.systemBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.black.opacity(0.12), radius: 10, x: 0, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("acp-slash-suggestions")
    }

    private var measuredSuggestionRows: some View {
        suggestionRows
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { rowsHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, newValue in
                            rowsHeight = newValue
                        }
                }
            )
    }

    private var suggestionRows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(commands.enumerated()), id: \.element.id) { index, command in
                if index > 0 {
                    Divider()
                        .padding(.leading, 12)
                }
                Button {
                    onSelect(command)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("/\(command.name)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if !command.description.isEmpty {
                            Text(command.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("acp-slash-suggestion-\(command.name)")
            }
        }
    }
}
