import SwiftUI
import MarkdownView

struct ChatTranscriptInsets: Equatable {
    let top: CGFloat
    let left: CGFloat
    let bottom: CGFloat
    let right: CGFloat

    static let zero = ChatTranscriptInsets(top: 0, left: 0, bottom: 0, right: 0)
}

#if canImport(UIKit)
import UIKit

private extension ChatTranscriptInsets {
    var platformInsets: UIEdgeInsets {
        UIEdgeInsets(top: top, left: left, bottom: bottom, right: right)
    }
}

struct ChatTranscriptContainerView: UIViewRepresentable {
    let state: ChatTranscriptState
    let messages: [ChatMessage]
    var liveStatusText: String? = nil
    var failedDeliveryMessageIds: Set<UUID> = []
    let contentInsets: ChatTranscriptInsets
    let actionHandlers: ChatEntryActionHandlers
    var onAtBottomChanged: ((Bool) -> Void)?
    var onRetryFailedMessage: ((UUID) -> Void)? = nil
    var config: ChatRendererConfig = .default

    private var resolvedActionHandlers: ChatEntryActionHandlers {
        var handlers = actionHandlers
        if let onRetryFailedMessage {
            handlers.onRetryFailedMessage = onRetryFailedMessage
        }
        return handlers
    }

    final class Coordinator {
        var hasRendered = false
        var lastMessages: [ChatMessage] = []
        var lastLiveStatusText: String? = nil
        var lastFailedDeliveryMessageIds: Set<UUID> = []
        var lastInsets: ChatTranscriptInsets = .zero
        var onAtBottomChanged: ((Bool) -> Void)?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> HighPerformanceChatListView {
        let view = HighPerformanceChatListView()
        view.config = config
        view.actionHandlers = resolvedActionHandlers
        view.updateContentInsets(contentInsets.platformInsets)
        context.coordinator.lastInsets = contentInsets
        context.coordinator.onAtBottomChanged = onAtBottomChanged
        view.onAtBottomChanged = { [weak state] isAtBottom in
            Task { @MainActor in
                state?.isAtBottom = isAtBottom
            }
            context.coordinator.onAtBottomChanged?(isAtBottom)
        }
        state.listView = view
        state.scrollToBottomHandler = nil
        return view
    }

    func updateUIView(_ uiView: HighPerformanceChatListView, context: Context) {
        uiView.config = config
        uiView.actionHandlers = resolvedActionHandlers
        context.coordinator.onAtBottomChanged = onAtBottomChanged
        if context.coordinator.lastInsets != contentInsets {
            uiView.updateContentInsets(contentInsets.platformInsets)
            context.coordinator.lastInsets = contentInsets
        }
        _ = applyRenderIfNeeded(to: uiView, coordinator: context.coordinator)
        state.listView = uiView
        state.scrollToBottomHandler = nil
    }

    @discardableResult
    func applyRenderIfNeeded(to uiView: HighPerformanceChatListView, coordinator: Coordinator) -> Bool {
        guard !coordinator.hasRendered
            || coordinator.lastMessages != messages
            || coordinator.lastLiveStatusText != liveStatusText
            || coordinator.lastFailedDeliveryMessageIds != failedDeliveryMessageIds else {
            return false
        }
        let shouldAnimateScrollToBottom = shouldAnimateScrollToBottom(
            from: coordinator.lastMessages,
            to: messages,
            hasRendered: coordinator.hasRendered
        )
        uiView.render(
            messages: messages,
            liveStatusText: liveStatusText,
            failedDeliveryMessageIds: failedDeliveryMessageIds,
            animated: false,
            scrollToBottomAnimated: shouldAnimateScrollToBottom
        )
        coordinator.lastMessages = messages
        coordinator.lastLiveStatusText = liveStatusText
        coordinator.lastFailedDeliveryMessageIds = failedDeliveryMessageIds
        coordinator.hasRendered = true
        return true
    }

    private func shouldAnimateScrollToBottom(
        from oldMessages: [ChatMessage],
        to newMessages: [ChatMessage],
        hasRendered: Bool
    ) -> Bool {
        ChatScrollAnimationPolicy.shouldAnimateScrollToBottom(
            from: oldMessages,
            to: newMessages,
            hasRendered: hasRendered
        )
    }
}
#endif
