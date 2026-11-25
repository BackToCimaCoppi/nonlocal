import XCTest
import UIKit
import WebKit
import ListViewKit
@testable import Agmente

@MainActor
final class MermaidRenderingTests: XCTestCase {

    // MARK: - AC-601: `.message`, `.plan`, `.thought` Mermaid splitting + in-process list rendering

    func testAC601_SplitMermaidBlocksAcrossMessagePlanAndThought() {
        let mapper = ChatEntryMapper()
        let messageSeg = AssistantSegment(
            kind: .message,
            text: """
            请查看 `README.md`：

            ```mermaid
            graph TD
              A --> B
            ```

            中间文字

            ~~~Mermaid
            sequenceDiagram
              Alice->>Bob: Hi
            ~~~
            """
        )
        let planSeg = AssistantSegment(
            kind: .plan,
            text: """
            计划：
            ```mermaid
            flowchart LR
              P1 --> P2
            ```
            """
        )
        let thoughtSeg = AssistantSegment(
            kind: .thought,
            text: """
            思考：
            ```mermaid
            graph LR
              T1 --> T2
            ```
            """
        )
        let chatMsg = ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: false,
            segments: [messageSeg, planSeg, thoughtSeg]
        )

        let entries = mapper.entries(from: [chatMsg], liveStatusText: nil)
        let mermaidEntries = entries.filter { $0.kind == .assistantMermaid }
        XCTAssertEqual(mermaidEntries.count, 4, "Expected 2 message + 1 plan + 1 thought mermaid entries, got \(entries.map { ($0.kind, $0.id) })")

        // All IDs must be unique and stable
        let ids = mermaidEntries.map(\.id)
        XCTAssertEqual(Set(ids).count, 4)
        XCTAssertTrue(ids.contains(where: { $0.contains(".assistantMermaid.message.") }))
        XCTAssertTrue(ids.contains(where: { $0.contains(".assistantMermaid.plan.") }))
        XCTAssertTrue(ids.contains(where: { $0.contains(".assistantMermaid.thought.") }))

        // Text segments preserved alongside Mermaid
        XCTAssertTrue(entries.contains(where: { $0.kind == .assistantMarkdown && $0.text.contains("README.md") }))
        XCTAssertTrue(entries.contains(where: { $0.kind == .assistantMarkdown && $0.text.contains("中间文字") }))

        // Plan/Thought split mermaid entries configure cleanly on HighPerformanceChatListView -> MermaidRowView
        let listView = HighPerformanceChatListView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        for mEntry in mermaidEntries {
            let kind = listView.listView(ListViewKit.ListView(), rowKindFor: mEntry, at: 0)
            let row = listView.listViewMakeRow(for: kind)
            XCTAssertTrue(row is MermaidRowView, "Mermaid entry must produce MermaidRowView")
        }
    }

    // MARK: - AC-602: Nested 4-backtick fence, empty mermaid block, unclosed streaming fence

    func testAC602_BoundaryNestedEmptyAndUnclosedMermaidFences() {
        let mapper = ChatEntryMapper()

        let nested = """
        ````markdown
        ```mermaid
        graph TD
          A --> B
        ```
        ````
        """
        let empty = "```mermaid\n   \n```"
        let unclosed = """
        ```mermaid
        graph TD
          A --> B
        """

        for (label, text) in [("nested", nested), ("empty", empty), ("unclosed", unclosed)] {
            let msg = ChatMessage(
                role: .assistant,
                content: text,
                isStreaming: label == "unclosed",
                segments: [AssistantSegment(kind: .message, text: text)]
            )
            let entries = mapper.entries(from: [msg], liveStatusText: nil)
            let mermaidCount = entries.filter { $0.kind == .assistantMermaid }.count
            XCTAssertEqual(mermaidCount, 0, "\(label) must produce 0 .assistantMermaid entries")
            XCTAssertTrue(entries.contains(where: { $0.kind == .assistantMarkdown && $0.text.contains("mermaid") }), "\(label) must stay in markdown")
        }
    }

    // MARK: - AC-603: Zero WKWebView in MermaidRowView, placeholder never cached, height measurement, reuse

    func testAC603_MermaidRowViewZeroWebViewHeightAndReuse() {
        func containsWebView(_ view: UIView) -> Bool {
            if view is WKWebView { return true }
            return view.subviews.contains(where: containsWebView)
        }

        let row = MermaidRowView(frame: CGRect(x: 0, y: 0, width: 340, height: 160))
        XCTAssertFalse(containsWebView(row), "MermaidRowView must embed ZERO WKWebView instances")

        // When onOpenFullscreen == nil, zoom hint is hidden
        row.configure(source: "graph TD\nA-->B", renderToken: "t1", onOpenFullscreen: nil)
        XCTAssertFalse(row.isZoomHintVisible, "Zoom hint must be hidden when onOpenFullscreen == nil")

        // Placeholder height must NOT be stored in ChatHeightCache.shared
        let uniqueSource = "graph TD\n  UNRENDERED_\(UUID().uuidString) --> B"
        let entry = ChatEntry.assistantMermaid(messageId: UUID(), segmentId: UUID(), sourceKind: "msg", index: 0, source: uniqueSource)
        let listView = HighPerformanceChatListView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        let lv = ListViewKit.ListView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        let placeholderHeight = listView.listView(lv, heightFor: entry, at: 0)
        XCTAssertEqual(placeholderHeight, MermaidRowView.placeholderHeight + HighPerformanceChatListView.rowInsets.bottom)

        let contentWidth = max(0, lv.bounds.width - HighPerformanceChatListView.rowInsets.left - HighPerformanceChatListView.rowInsets.right)
        XCTAssertNil(ChatHeightCache.shared.height(for: entry, width: contentWidth), "Placeholder 160pt must NEVER be cached in ChatHeightCache.shared")

        // Ready height within 120...320 pt
        let readyDiagram = MermaidRenderedDiagram(svg: "<svg></svg>", aspectRatio: 1.5, domId: "m1", image: nil)
        let readyHeight = MermaidRowView.measureHeight(source: uniqueSource, outcome: .ready(readyDiagram), contentWidth: 332)
        XCTAssertGreaterThanOrEqual(readyHeight, MermaidRowView.minDiagramHeight)
        XCTAssertLessThanOrEqual(readyHeight, MermaidRowView.maxDiagramHeight)

        // Failure height for 20-line source > 160 pt
        let twentyLines = (1...20).map { "  Node\($0) --> Node\($0 + 1)" }.joined(separator: "\n")
        let failHeight = MermaidRowView.measureHeight(source: twentyLines, outcome: .failure(.syntaxError("bad syntax")), contentWidth: 332)
        XCTAssertGreaterThan(failHeight, MermaidRowView.placeholderHeight, "20-line failure source height must exceed 160pt placeholder")

        // withContentHashSalt triggers ChatRenderDiff change
        let salted = entry.withContentHashSalt(1)
        let diff = ChatRenderDiff.make(old: [entry], new: [salted])
        XCTAssertFalse(diff.isEmpty, "withContentHashSalt must trigger ChatRenderDiff")

        // prepareForReuse clears handler and active render task
        row.configure(source: uniqueSource, renderToken: "t2", onOpenFullscreen: { _ in })
        row.prepareForReuse()
        XCTAssertNil(row.currentFullscreenHandlerForTesting)
        XCTAssertFalse(row.hasActiveRenderTaskForTesting)
    }

    // MARK: - AC-604: Duplicate Mermaid SVG ID dedup & `.markdown-prose` CSS scoping

    func testAC604_MarkdownMermaidSVGDedupAndProseCSSScoping() {
        let md = """
        正文段落

        ```mermaid
        graph TD
          A --> B
        ```

        ```mermaid
        graph TD
          A --> B
        ```
        """
        let mockSVG = """
        <svg id="mermaid-1" xmlns="http://www.w3.org/2000/svg"><defs><marker id="arrow"></marker></defs><path marker-end="url(#arrow)"/><foreignObject><div>Line 1<br>Line 2</div></foreignObject></svg>
        """

        let html = MarkdownToHTMLConverter.convertToHTMLDocument(
            markdown: md,
            isDark: false,
            mermaidRenderer: { _, idx in
                let deduped = MarkdownToHTMLConverter.deduplicateSVGIds(mockSVG, prefix: "mdm\(idx)")
                return "<div class=\"mermaid-diagram\">\(deduped)</div>"
            }
        )

        // Extract all id="..." values and verify zero duplicates
        let regex = try! NSRegularExpression(pattern: #"\bid="([^"]+)""#)
        let ns = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: ns.length))
        let ids = matches.map { ns.substring(with: $0.range(at: 1)) }
        XCTAssertGreaterThanOrEqual(ids.count, 4, "Expected deduped IDs from both SVGs")
        XCTAssertEqual(ids.count, Set(ids).count, "All SVG DOM IDs must be unique: \(ids)")
        XCTAssertTrue(html.contains("url(#mdm0_arrow)"))
        XCTAssertTrue(html.contains("url(#mdm1_arrow)"))

        // Prose CSS must be scoped under .markdown-prose
        XCTAssertTrue(html.contains(".markdown-prose"))
        XCTAssertFalse(html.contains("\np {"))
    }

    // MARK: - AC-605: Fullscreen inline `<svg>` HTML5 shell (no `<img src="data:image/svg+xml">`) & macOS isolation

    func testAC605_FullscreenInlineSVGShellAndMacOSIsolation() throws {
        let sampleSVG = "<svg id=\"m9\"><foreignObject><div>第一行<br>第二行</div></foreignObject></svg>"
        let html = MermaidFullscreenHTMLBuilder.buildInlineSVGHTML(svg: sampleSVG, isDark: true)

        XCTAssertTrue(html.lowercased().contains("<!doctype html>"))
        XCTAssertTrue(html.contains("<svg id=\"m9\""))
        XCTAssertFalse(html.contains("data:image/svg+xml"), "Fullscreen Mermaid MUST NOT use <img src=\"data:image/svg+xml\">")

        // Verify SessionDetailView macOS #else path does NOT use MermaidRowView or .assistantMermaid
        let testFileURL = URL(fileURLWithPath: #filePath)
        let iosRoot = testFileURL.deletingLastPathComponent().deletingLastPathComponent()
        let sessionDetailURL = iosRoot.appendingPathComponent("Agmente/SessionDetailView.swift")
        let source = try String(contentsOf: sessionDetailURL, encoding: .utf8)
        XCTAssertFalse(source.contains("MermaidRowView"), "SessionDetailView macOS path must not reference MermaidRowView")
        XCTAssertFalse(source.contains(".assistantMermaid"), "SessionDetailView macOS path must not split .assistantMermaid")
    }
}
