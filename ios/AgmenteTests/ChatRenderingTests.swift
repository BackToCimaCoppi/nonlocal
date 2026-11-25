import Foundation
import SwiftUI
import MarkdownView
import Testing
import ACP
import ACPClient
#if canImport(UIKit)
import UIKit
#endif
@testable import Agmente

// SC-AC-052: ChatRendering SystemRowView multiline & ACP permissionOptions regression.
struct ChatRenderingTests {

    @Test func entryMapperGeneratesExpectedKinds() {
        let user = ChatMessage(role: .user, content: "hello", isStreaming: false)

        let assistant = ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: true,
            segments: [
                AssistantSegment(kind: .message, text: "answer"),
                AssistantSegment(kind: .thought, text: "thinking"),
            ]
        )

        let mapper = ChatEntryMapper()
        let entries = mapper.entries(from: [user, assistant])

        #expect(entries.contains(where: { $0.kind == .userText }))
        #expect(entries.contains(where: { $0.kind == .assistantMarkdown }))
        #expect(entries.contains(where: { $0.kind == .assistantThought }))
        #expect(entries.contains(where: { $0.kind == .streamingIndicator }))
    }

    @Test func entryMapperExtractsFileChangeSummary() {
        let toolCall = ToolCallDisplay(
            toolCallId: "tc1",
            title: "Edit: Sources/File.swift",
            kind: "edit",
            status: "completed",
            output: "@@ -1 +1 @@\n-old\n+new"
        )
        let assistant = ChatMessage(
            role: .assistant,
            content: "",
            isStreaming: false,
            segments: [AssistantSegment(kind: .toolCall, text: toolCall.title, toolCall: toolCall)]
        )

        let mapper = ChatEntryMapper()
        let entries = mapper.entries(from: [assistant])

        #expect(entries.contains(where: { $0.kind == .fileChanges }))
    }

    @Test func renderDiffDetectsInsertUpdateRemove() {
        let oldEntries: [ChatEntry] = [
            .userText(messageId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, text: "a"),
            .system(messageId: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!, text: "b", isError: false),
        ]
        let newEntries: [ChatEntry] = [
            .userText(messageId: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!, text: "a updated"),
            .assistantMarkdown(
                messageId: UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!,
                segmentId: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
                text: "new"
            ),
        ]

        let diff = ChatRenderDiff.make(old: oldEntries, new: newEntries)

        #expect(diff.updated.count == 1)
        #expect(diff.inserted.count == 1)
        #expect(diff.removed.count == 1)
    }

    @Test func scrollAnimationPolicy_NoAnimationBeforeFirstRender() {
        let oldMessages: [ChatMessage] = []
        let newMessages = [makeMessage(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", content: "hello")]

        let result = ChatScrollAnimationPolicy.shouldAnimateScrollToBottom(
            from: oldMessages,
            to: newMessages,
            hasRendered: false
        )

        #expect(result == false)
    }

    @Test func scrollAnimationPolicy_NoAnimationForHistoryHydration() {
        let oldMessages: [ChatMessage] = []
        let newMessages = [
            makeMessage(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", content: "1"),
            makeMessage(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", content: "2"),
            makeMessage(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", content: "3"),
        ]

        let result = ChatScrollAnimationPolicy.shouldAnimateScrollToBottom(
            from: oldMessages,
            to: newMessages,
            hasRendered: true
        )

        #expect(result == false)
    }

    @Test func scrollAnimationPolicy_AnimatesForTailAppend() {
        let oldMessages = [
            makeMessage(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", content: "1"),
            makeMessage(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", content: "2"),
        ]
        let newMessages = oldMessages + [
            makeMessage(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", content: "3"),
        ]

        let result = ChatScrollAnimationPolicy.shouldAnimateScrollToBottom(
            from: oldMessages,
            to: newMessages,
            hasRendered: true
        )

        #expect(result == true)
    }

    @Test func scrollAnimationPolicy_NoAnimationWhenInsertedBeyondThreshold() {
        let oldMessages = [
            makeMessage(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", content: "1"),
        ]
        let newMessages = oldMessages + [
            makeMessage(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", content: "2"),
            makeMessage(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", content: "3"),
            makeMessage(id: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD", content: "4"),
            makeMessage(id: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE", content: "5"),
        ]

        let result = ChatScrollAnimationPolicy.shouldAnimateScrollToBottom(
            from: oldMessages,
            to: newMessages,
            hasRendered: true
        )

        #expect(result == false)
    }

    @Test func scrollAnimationPolicy_AnimatesForStreamingUpdate() {
        let oldLast = makeMessage(
            id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA",
            content: "partial",
            isStreaming: true
        )
        var newLast = oldLast
        newLast.content = "partial plus more"

        let result = ChatScrollAnimationPolicy.shouldAnimateScrollToBottom(
            from: [oldLast],
            to: [newLast],
            hasRendered: true
        )

        #expect(result == true)
    }

    @Test func scrollAnimationPolicy_NoAnimationForSessionSwitchWithReorder() {
        let oldMessages = [
            makeMessage(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", content: "1"),
            makeMessage(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", content: "2"),
            makeMessage(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", content: "3"),
        ]
        let newMessages = [
            makeMessage(id: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF", content: "new session"),
            makeMessage(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", content: "2"),
            makeMessage(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", content: "3"),
        ]

        let result = ChatScrollAnimationPolicy.shouldAnimateScrollToBottom(
            from: oldMessages,
            to: newMessages,
            hasRendered: true
        )

        #expect(result == false)
    }

    private func makeMessage(
        id: String,
        content: String,
        isStreaming: Bool = false
    ) -> ChatMessage {
        let stored = StoredMessageInfo(
            messageId: UUID(uuidString: id)!,
            role: ChatMessage.Role.assistant.rawValue,
            content: content,
            createdAt: Date(timeIntervalSince1970: 0),
            segmentsData: nil
        )
        var message = ChatMessage(from: stored)
        message.isStreaming = isStreaming
        return message
    }

#if canImport(UIKit)
    @MainActor
    @Test func highPerformanceChatListView_Renders700ToolCallsWithoutHanging() async throws {
        var messages: [ChatMessage] = []
        for turn in 0..<20 {
            messages.append(ChatMessage(role: .user, content: "User prompt \(turn)", isStreaming: false))
            var segments: [AssistantSegment] = [
                AssistantSegment(kind: .thought, text: "Internal reasoning paragraph **\(turn)** with markdown\n- step 1\n- step 2")
            ]
            for t in 0..<35 {
                let id = "tc-\(turn)-\(t)"
                segments.append(AssistantSegment(
                    kind: .toolCall,
                    text: "[read] File\(t).swift",
                    toolCall: ToolCallDisplay(
                        toolCallId: id,
                        title: "Read Sources/Module/File\(t).swift",
                        kind: "read",
                        status: "completed"
                    )
                ))
            }
            segments.append(AssistantSegment(
                kind: .message,
                text: "Summary for turn **\(turn)** with `code` and clean output."
            ))
            messages.append(ChatMessage(role: .assistant, content: "Summary \(turn)", isStreaming: false, segments: segments))
        }

        let start = CFAbsoluteTimeGetCurrent()
        let view = HighPerformanceChatListView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        view.render(messages: messages, animated: false, scrollToBottomAnimated: false)

        let deadline = Date().addingTimeInterval(5.0)
        while Date() < deadline {
            view.layoutIfNeeded()
            if view.subviews.compactMap({ $0 as? UIScrollView }).first?.contentSize.height ?? 0 > 1000 {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let scrollView = view.subviews.compactMap { $0 as? UIScrollView }.first
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        #expect((scrollView?.contentSize.height ?? 0) > 1000)
        #expect(elapsed < 5.0)
    }

    @MainActor
    @Test func chatTextMetrics_ShrinkWrapsShortTextAndMeasuresLargePromptQuickly() {
        let font = UIFont.preferredFont(forTextStyle: .callout)
        let shortSize = ChatTextMetrics.measureSize(for: "Hi", font: font, maxWidth: 300)
        #expect(shortSize.width > 0 && shortSize.width < 60)
        #expect(shortSize.height > 0 && shortSize.height < 40)

        let hugeText = String(repeating: "## 证据包审查段落\n检查 `SessionDetailView.swift:424-448` 与并发状态流。\n", count: 900)
        let start = CFAbsoluteTimeGetCurrent()
        let hugeSize = ChatTextMetrics.measureSize(for: hugeText, font: font, maxWidth: 295)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        #expect(hugeSize.height > 10_000)
        #expect(elapsedMs < 1_000, "CoreText measurement took \(elapsedMs)ms")
    }

    @MainActor
    @Test func highPerformanceChatListView_RendersHugeUserPromptAndReentryQuickly() async throws {
        let userBlock = String(repeating: "## 证据包审查段落\n检查 `SessionDetailView.swift:424-448` 与 `ACPSessionViewModel.swift:212-220` 的并发状态流与缓存边界。\n| 项 | 状态 | 说明 |\n|---|---|---|\n| AC-1 | OK | 正常 |\n", count: 380)
        let mdPara = "- 核验 `HighPerformanceChatListView`、`ChatMarkdownPackageCache`、`ListViewKit`、`MarkdownTextView` 在 `session/load` 回放与切入切出时的布局与重绘路径。\n"
        let hugeMarkdown = (0..<10).map { i in
            "## 第 \(i) 部分：总评与整改前置判断\n\n" + String(repeating: mdPara, count: 16) + "\n---\n\n### 评审条目明细\n\n"
        }.joined()

        var segments: [AssistantSegment] = []
        for i in 0..<24 {
            segments.append(AssistantSegment(kind: .thought, text: String(repeating: "思考片段 \(i) 验证状态机与主线程渲染耗时。\n", count: 25)))
            for j in 0..<9 {
                segments.append(AssistantSegment(
                    kind: .toolCall,
                    text: "Read File\(i)_\(j).swift",
                    toolCall: ToolCallDisplay(toolCallId: "tc-\(i)-\(j)", title: "Read ios/Agmente/File\(i)_\(j).swift", kind: "read", status: "completed", output: "1: import Foundation\n2: // ok\n")
                ))
            }
        }
        segments.append(AssistantSegment(kind: .message, text: hugeMarkdown))

        let messages = [
            ChatMessage(role: .user, content: userBlock, isStreaming: false),
            ChatMessage(role: .assistant, content: hugeMarkdown, isStreaming: false, segments: segments)
        ]

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.makeKeyAndVisible()

        func measureRender() async throws -> (Double, CGFloat) {
            let view = HighPerformanceChatListView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
            window.addSubview(view)
            view.layoutIfNeeded()
            let t0 = CFAbsoluteTimeGetCurrent()
            view.render(messages: messages, animated: false, scrollToBottomAnimated: false)
            let deadline = Date().addingTimeInterval(5.0)
            var contentHeight: CGFloat = 0
            while Date() < deadline {
                view.layoutIfNeeded()
                contentHeight = view.subviews.compactMap({ $0 as? UIScrollView }).first?.contentSize.height ?? 0
                if contentHeight > 1000 {
                    break
                }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            view.removeFromSuperview()
            return (elapsedMs, contentHeight)
        }

        let (firstMs, firstHeight) = try await measureRender()
        let (reenterMs, reenterHeight) = try await measureRender()

        // Also verify scrolling directly to y = 0 renders the 56K UserTextRowView cleanly without TextKit hang
        let scrollCheckView = HighPerformanceChatListView(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.addSubview(scrollCheckView)
        scrollCheckView.layoutIfNeeded()
        scrollCheckView.render(messages: messages, animated: false, scrollToBottomAnimated: false)
        let waitDeadline = Date().addingTimeInterval(5.0)
        while Date() < waitDeadline {
            scrollCheckView.layoutIfNeeded()
            if (scrollCheckView.subviews.compactMap({ $0 as? UIScrollView }).first?.contentSize.height ?? 0) > 1000 {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let scrollT0 = CFAbsoluteTimeGetCurrent()
        if let sv = scrollCheckView.subviews.compactMap({ $0 as? UIScrollView }).first {
            sv.setContentOffset(.zero, animated: false)
            scrollCheckView.layoutIfNeeded()
        }
        let scrollTopMs = (CFAbsoluteTimeGetCurrent() - scrollT0) * 1000
        scrollCheckView.removeFromSuperview()

        #expect(firstHeight > 50_000)
        #expect(reenterHeight == firstHeight)
        #expect(firstMs < 3_000, "First render took \(firstMs)ms")
        #expect(reenterMs < 2_000, "Re-entry render took \(reenterMs)ms")
        #expect(scrollTopMs < 1_000, "Scrolling to top UserTextRowView took \(scrollTopMs)ms")
    }

    @Test func caches_RespectMaxEntriesBound() {
        let pkgCache = ChatMarkdownPackageCache(maxEntries: 2)
        _ = pkgCache.package(for: "a", content: "one", theme: .default)
        _ = pkgCache.package(for: "b", content: "two", theme: .default)
        _ = pkgCache.package(for: "c", content: "three", theme: .default)
        // Re-fetching "c" works cleanly after eviction of "a"
        let pkgC = pkgCache.package(for: "c", content: "three", theme: .default)
        #expect(!pkgC.blocks.isEmpty)

        let heightCache = ChatHeightCache(maxEntries: 2)
        let msgId = UUID()
        let e1 = ChatEntry.userText(messageId: msgId, text: "1")
        let e2 = ChatEntry.system(messageId: msgId, text: "2", isError: false)
        let e3 = ChatEntry.system(messageId: msgId, text: "3", isError: true)
        heightCache.store(height: 10, for: e1, width: 300)
        heightCache.store(height: 20, for: e2, width: 300)
        heightCache.store(height: 30, for: e3, width: 300)
        #expect(heightCache.height(for: e1, width: 300) == nil)
        #expect(heightCache.height(for: e2, width: 300) == 20)
        #expect(heightCache.height(for: e3, width: 300) == 30)
    }
#endif

    @Test func ccAc7_FileEditPermissionIsNotSwallowedByFileChangesSummary() throws {
        let diff = ACPToolCallDiff(path: "Sources/App.swift", oldText: "old", newText: "new")
        let parsedPermission = try #require(
            ACPPermissionRequestParser.parse(params: .object([
                "sessionId": .string("s-edit"),
                "toolCall": .object([
                    "toolCallId": .string("edit-perm-1"),
                    "title": .string("Edit: Sources/App.swift"),
                    "kind": .string("edit"),
                    "status": .string("pending"),
                ]),
                "options": .array([
                    .object(["optionId": .string("allow_once"), "name": .string("Allow"), "kind": .string("allow_once")]),
                    .object(["optionId": .string("reject_once"), "name": .string("Reject"), "kind": .string("reject_once")]),
                ]),
            ]))
        )
        let pendingEdit = ToolCallDisplay(
            toolCallId: "edit-perm-1",
            title: "Edit: Sources/App.swift",
            kind: "edit",
            status: "awaiting_permission",
            diffs: [diff],
            permissionOptions: parsedPermission.options,
            acpPermissionRequestId: .string("req-edit-1")
        )
        let completedEdit = ToolCallDisplay(
            toolCallId: "edit-done-1",
            title: "Edit: Sources/Other.swift",
            kind: "edit",
            status: "completed",
            diffs: [diff]
        )

        let pendingSegment = AssistantSegment(kind: .toolCall, text: pendingEdit.title, toolCall: pendingEdit)
        let completedSegment = AssistantSegment(kind: .toolCall, text: completedEdit.title, toolCall: completedEdit)

        #expect(FileChangeSummary.isFileChangeSegment(pendingSegment) == false)
        #expect(FileChangeSummary.isFileChangeSegment(completedSegment) == true)

        let msg = ChatMessage(role: .assistant, content: "", isStreaming: true, segments: [pendingSegment])
        let entries = ChatEntryMapper().entries(from: [msg], liveStatusText: "等待确认：Edit: Sources/App.swift")
        #expect(!entries.contains(where: { $0.kind == .fileChanges }))
        let toolEntry = try #require(entries.first { $0.kind == .toolCall })
        #expect(toolEntry.segment?.toolCall?.permissionOptions?.map(\.optionId) == ["allow_once", "reject_once"])
    }

    @Test func ccAc7_StreamingIndicatorContentHashTracksLiveStatusAndMapsSoloRow() throws {
        let msgId = UUID()
        let first = ChatEntry.streamingIndicator(messageId: msgId, text: "正在思考…", suffix: "live")
        let second = ChatEntry.streamingIndicator(messageId: msgId, text: "正在执行：ls", suffix: "live")
        #expect(first.id == second.id)
        #expect(first.contentHash != second.contentHash)

        let soloEntries = ChatEntryMapper().entries(from: [], liveStatusText: "正在思考…")
        #expect(soloEntries.count == 1)
        let solo = try #require(soloEntries.first)
        #expect(solo.kind == .streamingIndicator)
        #expect(solo.text == "正在思考…")
    }

#if canImport(UIKit)
    @MainActor
    @Test func ccAc7_UIKitStreamingIndicatorRowViewAndContainerTriggerUpdateLiveStatus() async throws {
        func findLabels(in root: UIView) -> [UILabel] {
            var result: [UILabel] = []
            if let label = root as? UILabel {
                result.append(label)
            }
            for sub in root.subviews {
                result.append(contentsOf: findLabels(in: sub))
            }
            return result
        }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 393, height: 852))
        window.makeKeyAndVisible()

        let transcriptState = ChatTranscriptState()
        let initialContainer = ChatTranscriptContainerView(
            state: transcriptState,
            messages: [],
            liveStatusText: "正在思考…",
            contentInsets: .zero,
            actionHandlers: .none
        )
        let coordinator = initialContainer.makeCoordinator()
        let listView = HighPerformanceChatListView(frame: window.bounds)
        window.addSubview(listView)
        listView.layoutIfNeeded()

        #expect(initialContainer.applyRenderIfNeeded(to: listView, coordinator: coordinator) == true)
        #expect(initialContainer.applyRenderIfNeeded(to: listView, coordinator: coordinator) == false)

        let deadline1 = Date().addingTimeInterval(2.0)
        while Date() < deadline1 {
            listView.layoutIfNeeded()
            if findLabels(in: listView).contains(where: { $0.text == "正在思考…" }) {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let firstLabel = try #require(findLabels(in: listView).first { $0.text == "正在思考…" })
        #expect(firstLabel.numberOfLines == 1)
        #expect(firstLabel.lineBreakMode == .byTruncatingTail)

        // Updating only liveStatusText (with unchanged empty messages) must re-render StreamingIndicatorRowView
        let updatedStatus = "正在执行：git status --very-long-command-to-confirm-tail-truncation"
        let updatedContainer = ChatTranscriptContainerView(
            state: transcriptState,
            messages: [],
            liveStatusText: updatedStatus,
            contentInsets: .zero,
            actionHandlers: .none
        )
        #expect(updatedContainer.applyRenderIfNeeded(to: listView, coordinator: coordinator) == true)
        #expect(coordinator.lastLiveStatusText == updatedStatus)

        let deadline2 = Date().addingTimeInterval(2.0)
        var updatedLabel: UILabel?
        while Date() < deadline2 {
            listView.layoutIfNeeded()
            if let match = findLabels(in: listView).first(where: { $0.text == updatedStatus }) {
                updatedLabel = match
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let resolvedUpdatedLabel = try #require(updatedLabel)
        #expect(resolvedUpdatedLabel.numberOfLines == 1)
        #expect(resolvedUpdatedLabel.lineBreakMode == .byTruncatingTail)
        #expect(resolvedUpdatedLabel.superview?.bounds.height ?? 99 <= 40)
        listView.removeFromSuperview()
    }

    // MARK: - W2-AC-406: #4b UIKit failedDeliveryMessageIds single retry button placement & dirty check

    @MainActor
    @Test func testW2AC406_FailedDeliveryRetryButtonPlacementAndDirtyCheck() {
        UIGraphicsBeginImageContextWithOptions(CGSize(width: 4, height: 4), true, 1.0)
        UIColor.blue.setFill()
        UIRectFill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let solidImg = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
        UIGraphicsEndImageContext()
        let attachment = ImageAttachment(id: UUID(), image: solidImg, mimeType: "image/png", base64Data: "AAAA", originalSize: 16)
        let img = ChatImageData(from: attachment)

        let textOnlyMsg = ChatMessage(role: .user, content: "Text only", isStreaming: false)
        let imageOnlyMsg = ChatMessage(role: .user, content: "", isStreaming: false, images: [img])
        let mixedMsg = ChatMessage(role: .user, content: "With image", isStreaming: false, images: [img])
        let messages = [textOnlyMsg, imageOnlyMsg, mixedMsg]

        let failedSet: Set<UUID> = [textOnlyMsg.id, imageOnlyMsg.id, mixedMsg.id]
        let mapper = ChatEntryMapper()
        let entriesWithFailed = mapper.entries(from: messages, failedDeliveryMessageIds: failedSet)
        let entriesWithoutFailed = mapper.entries(from: messages, failedDeliveryMessageIds: [])

        // Mixed message: ONLY .userText has showsRetryButton == true; .userImages has showsRetryButton == false
        var mixedTextRetry = false
        var mixedImagesRetry = true
        var imageOnlyRetry = false
        var textOnlyRetry = false

        for entry in entriesWithFailed {
            switch entry.kind {
            case .userText:
                if entry.messageId == textOnlyMsg.id { textOnlyRetry = entry.showsRetryButton }
                if entry.messageId == mixedMsg.id { mixedTextRetry = entry.showsRetryButton }
            case .userImages:
                if entry.messageId == imageOnlyMsg.id { imageOnlyRetry = entry.showsRetryButton }
                if entry.messageId == mixedMsg.id { mixedImagesRetry = entry.showsRetryButton }
            default:
                break
            }
        }

        #expect(textOnlyRetry == true)
        #expect(imageOnlyRetry == true)
        #expect(mixedTextRetry == true)
        #expect(mixedImagesRetry == false)

        // contentHash changes when showsRetryButton toggles
        #expect(entriesWithFailed.map(\.contentHash) != entriesWithoutFailed.map(\.contentHash))

        // ChatTranscriptContainerView dirty check detects failedDeliveryMessageIds changes alone
        let state = ChatTranscriptState()
        let listView = HighPerformanceChatListView(frame: CGRect(x: 0, y: 0, width: 360, height: 600))
        let coordinator = ChatTranscriptContainerView.Coordinator()

        let c1 = ChatTranscriptContainerView(
            state: state, messages: messages, failedDeliveryMessageIds: [], contentInsets: .zero, actionHandlers: .none
        )
        #expect(c1.applyRenderIfNeeded(to: listView, coordinator: coordinator) == true)
        #expect(c1.applyRenderIfNeeded(to: listView, coordinator: coordinator) == false)

        let c2 = ChatTranscriptContainerView(
            state: state, messages: messages, failedDeliveryMessageIds: failedSet, contentInsets: .zero, actionHandlers: .none
        )
        #expect(c2.applyRenderIfNeeded(to: listView, coordinator: coordinator) == true)
    }

    // MARK: - W2-AC-505: UIKit ToolCallRowView ACP permission button height & SystemRowView numberOfLines == 0

    @MainActor
    @Test func testW2AC505_UIKitToolCallButtonHeightAndSystemRowMultiline() {
        let parsedRequest = ACPPermissionRequestParser.parse(params: .object([
            "sessionId": .string("s-1"),
            "toolCall": .object([
                "toolCallId": .string("tc-1"),
                "title": .string("Run build"),
                "kind": .string("execute")
            ]),
            "options": .array([
                .object(["optionId": .string("allow_once"), "name": .string("Allow once"), "kind": .string("allow_once")]),
                .object(["optionId": .string("reject_once"), "name": .string("Reject once"), "kind": .string("reject_once")])
            ])
        ]))
        let options = parsedRequest?.options ?? []
        #expect(options.count == 2)

        let baseTool = ToolCallDisplay(toolCallId: "tc-1", title: "Run build", kind: "execute", status: "in_progress")
        let permTool = ToolCallDisplay(
            toolCallId: "tc-1",
            title: "Run build",
            kind: "execute",
            status: "awaiting_permission",
            permissionOptions: options,
            acpPermissionRequestId: .int(1)
        )
        let baseEntry = ChatEntry.toolCall(messageId: UUID(), segment: AssistantSegment(kind: .toolCall, text: "Run build", toolCall: baseTool), isStreaming: false)
        let permEntry = ChatEntry.toolCall(messageId: UUID(), segment: AssistantSegment(kind: .toolCall, text: "Run build", toolCall: permTool), isStreaming: false)
        let baseHeight = ToolCallRowView.estimatedHeight(for: ToolCallRowView.Payload(entry: baseEntry), width: 320)
        let permHeight = ToolCallRowView.estimatedHeight(for: ToolCallRowView.Payload(entry: permEntry), width: 320)
        #expect(permHeight > baseHeight)

        // SystemRowView wraps multiline error messages cleanly (numberOfLines == 0)
        func collectLabels(in view: UIView) -> [UILabel] {
            var res: [UILabel] = []
            if let lbl = view as? UILabel { res.append(lbl) }
            for sub in view.subviews { res.append(contentsOf: collectLabels(in: sub)) }
            return res
        }
        let sysRow = SystemRowView(isError: true)
        let labels = collectLabels(in: sysRow)
        #expect(!labels.isEmpty)
        #expect(labels.allSatisfy { $0.numberOfLines == 0 })
    }

    // MARK: - W2-AC-503: CLDR plural variations (including Russian one/few/many/other)

    @Test func testW2AC503_PluralVariationsAcrossLocalesIncludingRussian() {
        func localizedFiles(_ count: Int, localeId: String) -> String {
            AppLocalization.localized("\(count) files changed", locale: Locale(identifier: localeId))
        }

        // Russian: 1 (one), 2 (few), 5 (many) must produce 3 distinct plural forms
        let ru1 = localizedFiles(1, localeId: "ru")
        let ru2 = localizedFiles(2, localeId: "ru")
        let ru5 = localizedFiles(5, localeId: "ru")
        #expect(Set([ru1, ru2, ru5]).count == 3)

        // English: 1 vs 2 distinct
        let en1 = localizedFiles(1, localeId: "en")
        let en2 = localizedFiles(2, localeId: "en")
        #expect(en1 != en2)

        // German: 1 vs 2 distinct
        let de1 = localizedFiles(1, localeId: "de")
        let de2 = localizedFiles(2, localeId: "de")
        #expect(de1 != de2)

        // Chinese: non-empty and localized
        let zh2 = localizedFiles(2, localeId: "zh-Hans")
        #expect(zh2.contains("2"))
        #expect(zh2 != en2)
    }
#endif
}
