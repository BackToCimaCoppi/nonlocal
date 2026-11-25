import XCTest
import UIKit
import ListViewKit
import MarkdownView
import ACP
import ACPClient
@testable import Agmente

// SC-AC-052: ChatPathLink iOS preprocessing, routing & cache key isolation regression.
@MainActor
final class ChatPathLinkTests: XCTestCase {

    // MARK: - AC-501: Bare paths, backtick paths, Chinese trailing punctuation, `#` preservation

    func testAC501_PreprocessBareAndBacktickPathsPreservingPunctuationAndHash() {
        let bareInput = "见 /Users/a/foo.md、~/bar.txt：file:///tmp/c.md#L10。"
        let bareOut = ChatPathLinkPreprocessor.preprocess(bareInput)

        XCTAssertEqual(bareInput, "见 /Users/a/foo.md、~/bar.txt：file:///tmp/c.md#L10。", "Original input must not be mutated")
        XCTAssertTrue(bareOut.contains("[/Users/a/foo.md](/Users/a/foo.md)、"), "Chinese dunhao must remain outside link: \(bareOut)")
        XCTAssertTrue(bareOut.contains("[~/bar.txt](~/bar.txt)："), "Chinese colon must remain outside link: \(bareOut)")
        XCTAssertTrue(bareOut.contains("[file:///tmp/c.md#L10](file:///tmp/c.md#L10)。"), "Chinese period must remain outside link and #L10 preserved: \(bareOut)")

        let backtickInput = "查看 `docs/plan(1).md`、`App.swift:42` 与 `/Users/demo/dir#L5`。"
        let backtickOut = ChatPathLinkPreprocessor.preprocess(backtickInput)

        XCTAssertTrue(backtickOut.contains("[`docs/plan(1).md`](docs/plan%281%29.md)"), "Parentheses must be percent-encoded in target: \(backtickOut)")
        XCTAssertTrue(backtickOut.contains("[`App.swift:42`](App.swift:42)"), "file:line in backticks must become link: \(backtickOut)")
        XCTAssertTrue(backtickOut.contains("[`/Users/demo/dir#L5`](/Users/demo/dir#L5)"), "Hash # must NOT be percent-encoded: \(backtickOut)")
    }

    // MARK: - AC-502: Negative cases (fences, existing links, URLs, non-paths) & cache key isolation

    func testAC502_NegativeAntiFalsePositivesAndCacheKeyIsolation() {
        let closedFence = """
        ```bash
        /usr/local/bin/node
        ```
        """
        XCTAssertEqual(ChatPathLinkPreprocessor.preprocess(closedFence), closedFence, "Closed code fence must not be rewritten")

        let unclosedFence = """
        ```bash
        /usr/local/bin/node
        ~/secret.txt
        """
        XCTAssertEqual(ChatPathLinkPreprocessor.preprocess(unclosedFence), unclosedFence, "Unclosed streaming code fence must not be rewritten")

        let existingLinks = "已有 [文档](docs/a.md) 与 <https://a.com/b.md> 以及 https://github.com/org/repo/blob/main/a.md"
        XCTAssertEqual(ChatPathLinkPreprocessor.preprocess(existingLinks), existingLinks, "Existing links and URLs must not be rewritten")

        let nonPathBackticks = "命令 `git status`、分数 `1/2`、日期 `2026/11/19`、词 `foo`"
        XCTAssertEqual(ChatPathLinkPreprocessor.preprocess(nonPathBackticks), nonPathBackticks, "Non-path backticks must not be rewritten")

        // Verify ChatMarkdownPackageCache separates preprocessPathLinks: false vs true
        let cache = ChatMarkdownPackageCache.shared
        let theme = MarkdownTheme.default
        let themeId = ChatMarkdownPackageCache.themeIdentity(for: theme)
        let sample = "检查 `/Users/demo/README.md`"

        let pkgFalse = cache.package(for: "ac502-iso", content: sample, theme: theme, themeIdentity: themeId, preprocessPathLinks: false)
        let pkgTrue = cache.package(for: "ac502-iso", content: sample, theme: theme, themeIdentity: themeId, preprocessPathLinks: true)
        let pkgFalseRepeat = cache.package(for: "ac502-iso", content: sample, theme: theme, themeIdentity: themeId, preprocessPathLinks: false)
        let pkgTrueRepeat = cache.package(for: "ac502-iso", content: sample, theme: theme, themeIdentity: themeId, preprocessPathLinks: true)

        XCTAssertTrue(pkgFalse !== pkgTrue, "preprocessPathLinks: false vs true must use isolated cache keys and never share a package")
        XCTAssertTrue(pkgFalse === pkgFalseRepeat, "preprocessPathLinks: false must hit its own cache slot")
        XCTAssertTrue(pkgTrue === pkgTrueRepeat, "preprocessPathLinks: true must hit its own cache slot")
        XCTAssertEqual(ChatPathLinkPreprocessor.preprocess(sample), "检查 [`/Users/demo/README.md`](/Users/demo/README.md)")
    }

    // MARK: - AC-503: 6-step router precedence (`:42` before scheme check)

    func testAC503_RouterOrderAndSchemePrecedence() {
        XCTAssertEqual(ChatLinkRouter.resolve(rawLink: "", sessionCwd: "/proj", serverDefaultCwd: "~"), .ignored)
        XCTAssertEqual(ChatLinkRouter.resolve(rawLink: "#heading", sessionCwd: "/proj", serverDefaultCwd: "~"), .ignored)

        if case .externalURL(let url) = ChatLinkRouter.resolve(rawLink: "https://a.com/x#sec", sessionCwd: "/proj", serverDefaultCwd: "~") {
            XCTAssertEqual(url.absoluteString, "https://a.com/x#sec")
        } else {
            XCTFail("Expected externalURL for https with fragment")
        }

        if case .externalURL(let url) = ChatLinkRouter.resolve(rawLink: "mailto:a@b.com", sessionCwd: "/proj", serverDefaultCwd: "~") {
            XCTAssertEqual(url.absoluteString, "mailto:a@b.com")
        } else {
            XCTFail("Expected externalURL for mailto")
        }

        XCTAssertEqual(
            ChatLinkRouter.resolve(rawLink: "App.swift:42", sessionCwd: "/proj", serverDefaultCwd: "~"),
            .remotePath(resolvedPath: "/proj/App.swift", prefersDirectory: false, startLine: 42, endLine: nil)
        )

        XCTAssertEqual(
            ChatLinkRouter.resolve(rawLink: "docs/a.md#L10-L20", sessionCwd: "/proj", serverDefaultCwd: "~"),
            .remotePath(resolvedPath: "/proj/docs/a.md", prefersDirectory: false, startLine: 10, endLine: 20)
        )

        XCTAssertEqual(ChatLinkRouter.resolve(rawLink: "javascript:alert(1)", sessionCwd: "/proj", serverDefaultCwd: "~"), .ignored)
        XCTAssertEqual(ChatLinkRouter.resolve(rawLink: "file://remote-host/a.md", sessionCwd: "/proj", serverDefaultCwd: "~"), .ignored)
    }

    // MARK: - AC-504: Percent decoding, 3-level CWD fallback, `file://localhost`, lexical `~/..`

    func testAC504_PercentDecodingFallbacksAndLexicalNormalization() {
        XCTAssertEqual(
            ChatLinkRouter.resolve(rawLink: "docs/plan%281%29.md", sessionCwd: "/proj", serverDefaultCwd: "~"),
            .remotePath(resolvedPath: "/proj/docs/plan(1).md", prefersDirectory: false, startLine: nil, endLine: nil)
        )

        XCTAssertEqual(
            ChatLinkRouter.resolve(rawLink: "docs/%E6%96%B9%E6%A1%88.md#概述", sessionCwd: "/proj", serverDefaultCwd: "~"),
            .remotePath(resolvedPath: "/proj/docs/方案.md", prefersDirectory: false, startLine: nil, endLine: nil)
        )

        XCTAssertEqual(
            ChatLinkRouter.resolve(rawLink: "file://localhost/Users/demo/%E6%96%87%E6%A1%A3.md#L12", sessionCwd: "/proj", serverDefaultCwd: "~"),
            .remotePath(resolvedPath: "/Users/demo/文档.md", prefersDirectory: false, startLine: 12, endLine: nil)
        )

        // 3-level fallback: sessionCwd -> serverDefaultCwd -> "~"
        XCTAssertEqual(
            ChatLinkRouter.resolve(rawLink: "README.md", sessionCwd: "", serverDefaultCwd: "/srv"),
            .remotePath(resolvedPath: "/srv/README.md", prefersDirectory: false, startLine: nil, endLine: nil)
        )
        XCTAssertEqual(
            ChatLinkRouter.resolve(rawLink: "README.md", sessionCwd: "", serverDefaultCwd: ""),
            .remotePath(resolvedPath: "~/README.md", prefersDirectory: false, startLine: nil, endLine: nil)
        )

        // Never pop leading `~` or `/`
        XCTAssertEqual(
            ChatLinkRouter.resolve(rawLink: "../note.md", sessionCwd: "~", serverDefaultCwd: "~"),
            .remotePath(resolvedPath: "~/../note.md", prefersDirectory: false, startLine: nil, endLine: nil)
        )
        XCTAssertEqual(
            ChatLinkRouter.resolve(rawLink: "/", sessionCwd: "/proj", serverDefaultCwd: "~"),
            .remotePath(resolvedPath: "/", prefersDirectory: true, startLine: nil, endLine: nil)
        )
        XCTAssertEqual(
            ChatLinkRouter.resolve(rawLink: "~", sessionCwd: "/proj", serverDefaultCwd: "~"),
            .remotePath(resolvedPath: "~", prefersDirectory: true, startLine: nil, endLine: nil)
        )
        XCTAssertEqual(
            ChatLinkRouter.resolve(rawLink: "docs/", sessionCwd: "/proj", serverDefaultCwd: "~"),
            .remotePath(resolvedPath: "/proj/docs", prefersDirectory: true, startLine: nil, endLine: nil)
        )
    }

    // MARK: - AC-505: Height/render cache consistency & linkHandler reuse safety

    func testAC505_LinkHandlerReuseSafetyAndHeightRenderConsistency() {
        let theme = MarkdownTheme.default
        let themeId = ChatMarkdownPackageCache.themeIdentity(for: theme)
        let pkg = ChatMarkdownPackageCache.shared.package(
            for: "ac505-row",
            content: "打开 `/Users/demo/app.swift`",
            theme: theme,
            themeIdentity: themeId,
            preprocessPathLinks: true
        )

        // 1. MarkdownRowView (assistant & plan): same renderToken with cb1 -> cb2 must fire cb2, prepareForReuse clears handler
        for style in [MarkdownStyle.assistant, MarkdownStyle.plan] {
            let row = MarkdownRowView(style: style)
            var called: [String] = []
            row.setMarkdown(pkg, renderToken: "tok-1", onOpenLink: { _ in called.append("cb1") })
            row.setMarkdown(pkg, renderToken: "tok-1", onOpenLink: { _ in called.append("cb2") })

            XCTAssertNotNil(row.markdownViewForTesting.linkHandler)
            row.markdownViewForTesting.linkHandler?(.string("/Users/demo/app.swift"), NSRange(location: 0, length: 1), CGPoint.zero)
            XCTAssertEqual(called, ["cb2"], "Must invoke latest closure even when renderToken early-returns")

            row.prepareForReuse()
            XCTAssertNil(row.markdownViewForTesting.linkHandler, "prepareForReuse must clear linkHandler")
        }

        // 2. ThoughtRowView: same renderToken cb1 -> cb2 must fire cb2, prepareForReuse clears handler
        let thoughtRow = ThoughtRowView()
        var thoughtCalled: [String] = []
        thoughtRow.configure(
            markdown: pkg,
            theme: theme,
            renderToken: "thought-1",
            isExpanded: true,
            isStreaming: false,
            onToggle: {},
            onOpenLink: { _ in thoughtCalled.append("cb1") }
        )
        thoughtRow.configure(
            markdown: pkg,
            theme: theme,
            renderToken: "thought-1",
            isExpanded: true,
            isStreaming: false,
            onToggle: {},
            onOpenLink: { _ in thoughtCalled.append("cb2") }
        )
        thoughtRow.markdownViewForTesting.linkHandler?(.string("/Users/demo/app.swift"), NSRange(location: 0, length: 1), CGPoint.zero)
        XCTAssertEqual(thoughtCalled, ["cb2"], "ThoughtRowView must invoke latest closure on same renderToken")
        thoughtRow.prepareForReuse()
        XCTAssertNil(thoughtRow.markdownViewForTesting.linkHandler, "ThoughtRowView prepareForReuse must clear linkHandler")

        // 3. HighPerformanceChatListView: verify heightFor and configureRowView both honor actionHandlers.onOpenLink != nil
        let listViewWithLinks = HighPerformanceChatListView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        listViewWithLinks.actionHandlers = ChatEntryActionHandlers(
            onACPPermissionResponse: nil,
            onUndoFileChanges: nil,
            onReviewFileChanges: nil,
            onOpenLink: { _ in }
        )
        let listViewNoLinks = HighPerformanceChatListView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        listViewNoLinks.actionHandlers = .none

        let entry = ChatEntry.assistantMarkdown(messageId: UUID(), segmentId: UUID(), text: "查看 `/Users/demo/test.md`")
        let configuredWithLinks = MarkdownRowView(style: .assistant)
        listViewWithLinks.listView(ListViewKit.ListView(), configureRowView: configuredWithLinks, for: entry, at: 0)
        XCTAssertNotNil(configuredWithLinks.markdownViewForTesting.linkHandler)

        let configuredNoLinks = MarkdownRowView(style: .assistant)
        listViewNoLinks.listView(ListViewKit.ListView(), configureRowView: configuredNoLinks, for: entry, at: 0)
        XCTAssertNil(configuredNoLinks.markdownViewForTesting.linkHandler)
    }
}
