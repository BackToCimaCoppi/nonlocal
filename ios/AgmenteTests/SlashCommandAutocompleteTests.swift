import XCTest
import SwiftUI
import ACPClient
@testable import Agmente

final class SlashCommandAutocompleteTests: XCTestCase {
    private func makeCommand(_ name: String, description: String = "") -> SessionCommand {
        SessionCommand(id: name, name: name, description: description, inputHint: nil)
    }

    // MARK: - AC-1: Boundary Validation, Selection Suppression, and Nil/Invalid Safety

    func testActiveTokenSupportsValidLeftBoundaries() {
        let startToken = SlashCommandAutocomplete.activeToken(in: "/g", utf16CursorOffset: 2)
        XCTAssertEqual(startToken?.query, "g")
        XCTAssertEqual(startToken?.slashUTF16Offset, 0)

        let newlineToken = SlashCommandAutocomplete.activeToken(in: "hello\n/go", utf16CursorOffset: 9)
        XCTAssertEqual(newlineToken?.query, "go")
        XCTAssertEqual(newlineToken?.slashUTF16Offset, 6)

        let spaceToken = SlashCommandAutocomplete.activeToken(in: "hello /plan", utf16CursorOffset: 11)
        XCTAssertEqual(spaceToken?.query, "plan")
        XCTAssertEqual(spaceToken?.slashUTF16Offset, 6)
    }

    func testActiveTokenRejectsInvalidBoundariesPathsAndProtectionStates() {
        // Invalid left boundaries
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "https://g", utf16CursorOffset: 9))
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "foo/g", utf16CursorOffset: 5))

        // Invalid right boundaries (paths & file extensions)
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "/Users/alice", utf16CursorOffset: 6))
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "/go.md", utf16CursorOffset: 3))

        // Empty query / isolated slash / after space / cursor right after slash before suffix
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "/", utf16CursorOffset: 1))
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "/g ", utf16CursorOffset: 3))
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "/plan", utf16CursorOffset: 1))

        // Nil cursor offset strictly suppresses autocomplete
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "/g", utf16CursorOffset: nil))

        // Nil selection preserves cache (must return nil, not text.utf16.count)
        let sample = "前文 /g"
        XCTAssertNil(SlashCommandAutocomplete.insertionUTF16Offset(in: sample, from: nil))
        XCTAssertNil(SlashCommandAutocomplete.selectionEndUTF16Offset(in: sample, from: nil))

        // Non-empty range selection suppresses insertion offset (but selectionEnd tracks upperBound)
        let highlight = TextSelection(range: sample.startIndex..<sample.endIndex)
        XCTAssertNil(SlashCommandAutocomplete.insertionUTF16Offset(in: sample, from: highlight))
        XCTAssertEqual(SlashCommandAutocomplete.selectionEndUTF16Offset(in: sample, from: highlight), sample.utf16.count)

        // Multi-selection suppresses both
        let rangeSet = RangeSet([sample.startIndex..<sample.index(after: sample.startIndex)])
        let multi = TextSelection(ranges: rangeSet)
        XCTAssertNil(SlashCommandAutocomplete.insertionUTF16Offset(in: sample, from: multi))
        XCTAssertNil(SlashCommandAutocomplete.selectionEndUTF16Offset(in: sample, from: multi))

        // Stale out-of-bounds or mid-emoji/mid-ZWJ String.Index returns nil cleanly without crashing
        let longText = "ab🚀cd"
        let shortText = "a"
        let staleSelection = TextSelection(insertionPoint: longText.endIndex)
        XCTAssertNil(SlashCommandAutocomplete.insertionUTF16Offset(in: shortText, from: staleSelection))
        XCTAssertNil(SlashCommandAutocomplete.selectionEndUTF16Offset(in: shortText, from: staleSelection))

        let emojiText = "🚀"
        let midEmojiIndex = String.Index(utf16Offset: 1, in: emojiText)
        let midEmojiSelection = TextSelection(insertionPoint: midEmojiIndex)
        XCTAssertNil(SlashCommandAutocomplete.insertionUTF16Offset(in: emojiText, from: midEmojiSelection))
        XCTAssertNil(SlashCommandAutocomplete.selectionEndUTF16Offset(in: emojiText, from: midEmojiSelection))

        let flagText = "🇨🇳"
        let midFlagSelection = TextSelection(insertionPoint: String.Index(utf16Offset: 2, in: flagText))
        XCTAssertNil(SlashCommandAutocomplete.insertionUTF16Offset(in: flagText, from: midFlagSelection))
        XCTAssertNil(SlashCommandAutocomplete.selectionEndUTF16Offset(in: flagText, from: midFlagSelection))

        // selection(atUTF16Offset:in:) clamps safely on extreme and mid-emoji offsets without crash
        XCTAssertEqual(
            SlashCommandAutocomplete.insertionUTF16Offset(
                in: "前文🚀 /pl",
                from: SlashCommandAutocomplete.selection(atUTF16Offset: -10, in: "前文🚀 /pl")
            ),
            0
        )
        XCTAssertEqual(
            SlashCommandAutocomplete.insertionUTF16Offset(
                in: "a🚀b",
                from: SlashCommandAutocomplete.selection(atUTF16Offset: 2, in: "a🚀b")
            ),
            1
        )
        XCTAssertEqual(
            SlashCommandAutocomplete.insertionUTF16Offset(
                in: "a🇨🇳b",
                from: SlashCommandAutocomplete.selection(atUTF16Offset: 3, in: "a🇨🇳b")
            ),
            1
        )
        XCTAssertEqual(
            SlashCommandAutocomplete.insertionUTF16Offset(
                in: "a🚀b",
                from: SlashCommandAutocomplete.selection(atUTF16Offset: 999, in: "a🚀b")
            ),
            4
        )
    }

    // MARK: - AC-2: ASCII Character Set, Punctuation Termination, and Backspace

    func testActiveTokenAllowsASCIICharactersAndDismissesOnNonASCIIOrDelimiters() {
        let hyphenDigits = SlashCommandAutocomplete.activeToken(in: "/code-to-7layer", utf16CursorOffset: 15)
        XCTAssertEqual(hyphenDigits?.query, "code-to-7layer")

        let underscore = SlashCommandAutocomplete.activeToken(in: "/one_1", utf16CursorOffset: 6)
        XCTAssertEqual(underscore?.query, "one_1")

        // Collapses on non-ASCII punctuation/letters/full-width chars, space, newline, or second slash
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "/g、后文", utf16CursorOffset: 2))
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "/g、", utf16CursorOffset: 3))
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "/g中", utf16CursorOffset: 3))
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "/ｇ", utf16CursorOffset: 2))
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "/g１", utf16CursorOffset: 3))
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "/g ", utf16CursorOffset: 3))
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "/g\n", utf16CursorOffset: 3))
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "/g/h", utf16CursorOffset: 4))

        // Backspace narrows query cleanly and widens matches
        let commands = [makeCommand("goal-charter"), makeCommand("plan-goal")]
        let narrowed = SlashCommandAutocomplete.activeToken(in: "/goal-", utf16CursorOffset: 6)
        XCTAssertEqual(
            SlashCommandAutocomplete.filter(commands, query: narrowed?.query ?? "").map(\.name),
            ["goal-charter"]
        )
        let widened = SlashCommandAutocomplete.activeToken(in: "/goal", utf16CursorOffset: 5)
        XCTAssertEqual(
            SlashCommandAutocomplete.filter(commands, query: widened?.query ?? "").map(\.name),
            ["goal-charter", "plan-goal"]
        )
    }

    // MARK: - AC-3: Deduplication, Tiered Grouping, and Intra-Tier A–Z Sorting (DEC-2, DEC-10)

    func testFilterDeduplicatesAndSortsPrefixThenContainsAlphabetically() {
        let commands = [
            makeCommand("compact", description: "first"),
            makeCommand("plan-goal"),
            makeCommand("Compact", description: "duplicate"),
            makeCommand("goal-charter"),
            makeCommand("alpha-build"),
        ]

        let goalResults = SlashCommandAutocomplete.filter(commands, query: "goal")
        XCTAssertEqual(goalResults.map(\.name), ["goal-charter", "plan-goal"])

        let upperResults = SlashCommandAutocomplete.filter(commands, query: "GOAL")
        XCTAssertEqual(upperResults.map(\.name), ["goal-charter", "plan-goal"])

        // Case-insensitive deduplication preserves first occurrence
        let compactResults = SlashCommandAutocomplete.filter(commands, query: "com")
        XCTAssertEqual(compactResults.map(\.name), ["compact"])
        XCTAssertEqual(compactResults.first?.description, "first")

        // Empty and non-matching queries return []
        XCTAssertTrue(SlashCommandAutocomplete.filter(commands, query: "").isEmpty)
        XCTAssertTrue(SlashCommandAutocomplete.filter(commands, query: "zzz").isEmpty)

        // Intra-tier A–Z ascending order inside both prefix and substring buckets
        let unordered = [
            makeCommand("z-plan-sub"),
            makeCommand("plan-zebra"),
            makeCommand("beta-plan"),
            makeCommand("plan-alpha"),
            makeCommand("alpha-plan"),
            makeCommand("plan-mid"),
        ]
        XCTAssertEqual(
            SlashCommandAutocomplete.filter(unordered, query: "plan").map(\.name),
            ["plan-alpha", "plan-mid", "plan-zebra", "alpha-plan", "beta-plan", "z-plan-sub"]
        )
    }

    // MARK: - AC-4: Emoji Replacement, Mid-Word Replacement, Isolated Slash, and Blur Fallback

    func testInsertCommandHandlesEmojiMidWordTrailingSpaceNewlineAndBlurFallback() throws {
        // Emoji-adjacent replacement preserving existing trailing space
        let emojiPrompt = "前文🚀 /pl 后文"
        let emojiCursor = ("前文🚀 /pl" as NSString).length
        let emojiToken = try XCTUnwrap(
            SlashCommandAutocomplete.activeToken(in: emojiPrompt, utf16CursorOffset: emojiCursor)
        )
        let emojiResult = SlashCommandAutocomplete.insertCommand(
            "plan-goal",
            into: emojiPrompt,
            utf16CursorOffset: emojiCursor,
            replacing: emojiToken
        )
        XCTAssertEqual(emojiResult.text, "前文🚀 /plan-goal 后文")
        XCTAssertEqual(emojiResult.cursorUTF16Offset, ("前文🚀 /plan-goal " as NSString).length)

        // Mid-word caret whole-token replacement (DEC-8)
        let midWordPrompt = "/plan-goal 后文"
        let midWordToken = try XCTUnwrap(
            SlashCommandAutocomplete.activeToken(in: midWordPrompt, utf16CursorOffset: 5)
        )
        XCTAssertEqual(midWordToken.query, "plan")
        let midWordResult = SlashCommandAutocomplete.insertCommand(
            "compact",
            into: midWordPrompt,
            utf16CursorOffset: 5,
            replacing: midWordToken
        )
        XCTAssertEqual(midWordResult.text, "/compact 后文")
        XCTAssertEqual(midWordResult.cursorUTF16Offset, "/compact ".utf16.count)

        // Empty text and newline boundary do NOT prepend spurious space
        XCTAssertEqual(
            SlashCommandAutocomplete.insertCommand("compact", into: "", utf16CursorOffset: 0, replacing: nil).text,
            "/compact "
        )
        XCTAssertEqual(
            SlashCommandAutocomplete.insertCommand("compact", into: "line1\n", utf16CursorOffset: 6, replacing: nil).text,
            "line1\n/compact "
        )

        // Boundary-valid isolated "/" replacement (DEC-9)
        XCTAssertEqual(
            SlashCommandAutocomplete.insertCommand("compact", into: "/", utf16CursorOffset: 1, replacing: nil).text,
            "/compact "
        )
        XCTAssertEqual(
            SlashCommandAutocomplete.insertCommand("compact", into: "请用 /", utf16CursorOffset: 4, replacing: nil).text,
            "请用 /compact "
        )
        let midIsolatedResult = SlashCommandAutocomplete.insertCommand(
            "compact",
            into: "请用 / 后文",
            utf16CursorOffset: 4,
            replacing: nil
        )
        XCTAssertEqual(midIsolatedResult.text, "请用 /compact 后文")
        XCTAssertEqual(midIsolatedResult.cursorUTF16Offset, ("请用 /compact " as NSString).length)

        // Blur fallback when selection == nil preserves mid-string offset instead of jumping to end (AR-1)
        let midText = "前文 后文"
        let cachedOffset = 2 // right between "前文" and " 后文"
        let fallbackOffset = SlashCommandAutocomplete.selectionEndUTF16Offset(in: midText, from: nil) ?? cachedOffset
        let blurResult = SlashCommandAutocomplete.insertCommand(
            "compact",
            into: midText,
            utf16CursorOffset: fallbackOffset,
            replacing: nil
        )
        XCTAssertEqual(blurResult.text, "前文 /compact 后文")
        XCTAssertEqual(blurResult.cursorUTF16Offset, ("前文 /compact " as NSString).length)
    }

    // MARK: - AC-5 & AC-10: Multiple Inline Commands and Dismiss Reset Conditions

    func testMultipleCommandInsertionsCoexistAndDismissTracksSlashOffset() throws {
        let first = SlashCommandAutocomplete.insertCommand(
            "plan-goal",
            into: "",
            utf16CursorOffset: 0,
            replacing: nil
        )
        XCTAssertEqual(first.text, "/plan-goal ")

        let second = SlashCommandAutocomplete.insertCommand(
            "compact",
            into: first.text,
            utf16CursorOffset: first.cursorUTF16Offset,
            replacing: nil
        )
        XCTAssertEqual(second.text, "/plan-goal /compact ")

        // Dismiss tracks slashUTF16Offset per active segment and resets when leaving or switching tokens
        let t1 = try XCTUnwrap(SlashCommandAutocomplete.activeToken(in: "Use /g", utf16CursorOffset: 6))
        let dismissedOffset: Int? = t1.slashUTF16Offset
        let t1Continued = try XCTUnwrap(SlashCommandAutocomplete.activeToken(in: "Use /go", utf16CursorOffset: 7))
        XCTAssertEqual(t1Continued.slashUTF16Offset, dismissedOffset)

        // Typing a space produces nil token -> resets dismissedOffset
        XCTAssertNil(SlashCommandAutocomplete.activeToken(in: "Use /go ", utf16CursorOffset: 8))

        // Starting another slash token has a different slashUTF16Offset
        let t2 = try XCTUnwrap(SlashCommandAutocomplete.activeToken(in: "Use /go /c", utf16CursorOffset: 10))
        XCTAssertNotEqual(t2.slashUTF16Offset, dismissedOffset)
    }
}
