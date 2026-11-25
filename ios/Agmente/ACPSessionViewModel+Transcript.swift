import Foundation
import ACPClient
import ACP

extension ACPSessionViewModel {
    func handleChatUpdate(
        _ params: ACP.Value?,
        activeSessionId: String,
        serverId: UUID?
    ) {
        guard let updateSessionId = ACPSessionUpdateHandler.sessionId(from: params),
              updateSessionId == activeSessionId else { return }

        let events = sessionUpdateHandler.handle(params: params, activeSessionId: activeSessionId)
        for event in events {
            applySessionUpdateEvent(event, serverId: serverId, sessionId: activeSessionId)
        }
    }


    func handleSessionUpdateEvents(
        _ params: ACP.Value?,
        activeSessionId: String,
        serverId: UUID?
    ) {
        handleChatUpdate(params, activeSessionId: activeSessionId, serverId: serverId)
    }


    private func applySessionUpdateEvent(
        _ event: ACPSessionUpdateEvent,
        serverId: UUID?,
        sessionId: String
    ) {
        switch event {
        case .agentThought:
            updateLiveActivityStatus(String(localized: "Thinking…"))

        case .userMessage(let text):
            appendUserChunk(text)

        case .agentMessage(let text):
            if !activeReplayMode, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                clearPendingPromptDelivery()
            }
            updateLiveActivityStatus(String(localized: "Generating reply…"))
            appendAssistantText(text, kind: .message)

        case .toolCall(let info):
            if !activeReplayMode {
                clearPendingPromptDelivery()
            }
            handleACPToolCallStatus(
                toolCallId: info.toolCallId,
                title: info.title,
                kind: info.kind,
                status: info.status
            )

        case .toolCallUpdate(let update):
            handleACPToolCallUpdateStatus(update)

        case .modeChange(let modeId):
            currentModeId = modeId
            cacheCurrentMode(serverId: serverId, sessionId: sessionId)
            // Notify delegate about mode change
            if let serverId = serverId {
                eventDelegate?.sessionModeDidChange(modeId, serverId: serverId, sessionId: sessionId)
            }

        case .configOptionsUpdate(let options):
            applySessionConfigOptions(options, serverId: serverId, sessionId: sessionId)
            dependencies.append("Config options updated (\(options.count))")

        case .availableCommandsUpdate(let commands):
            handleAvailableCommandsUpdate(
                commands,
                serverId: serverId,
                sessionId: sessionId
            )
            dependencies.append("Available commands updated (\(commands.count))")

        case .usageUpdate(let info):
            usage = info

        case .sessionInfoUpdate(let info):
            // Session title / activity lives on the session list, not this VM —
            // forward to the delegate that owns the summaries.
            if let serverId = serverId {
                eventDelegate?.sessionInfoDidUpdate(info, serverId: serverId, sessionId: sessionId)
            }

        case .plan(let entries):
            // Full snapshot: replace the current plan (empty clears it).
            plan = entries
            if entries.isEmpty {
                dependencies.append("Plan cleared")
            } else {
                dependencies.append("Plan updated (\(entries.count) item(s))")
            }
        }

        trackPassiveStreamingEvent(event)
    }


    var canSchedulePassiveStreamingSettle: Bool {
        !activeReplayMode && !hasExplicitActiveTurn && !hasPendingUserAction && isActivelyRunning
    }

    func trackPassiveStreamingEvent(_ event: ACPSessionUpdateEvent) {
        guard !activeReplayMode else { return }
        passiveSettler.trackEvent(
            event,
            hasExplicitActiveTurn: hasExplicitActiveTurn,
            canSchedule: canSchedulePassiveStreamingSettle
        )
    }

    func schedulePassiveStreamingSettle() {
        passiveSettler.reschedule(canSchedule: canSchedulePassiveStreamingSettle)
    }

    func updateLiveActivityStatus(_ newValue: String?) {
        guard !activeReplayMode else { return }
        let normalized = newValue?
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = (normalized?.isEmpty == false) ? normalized : nil
        guard liveActivityStatus != resolved else { return }
        liveActivityStatus = resolved
    }

    static func formatPermissionStatus(title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return String(localized: "Waiting for permission…") }
        return String(localized: "Waiting for confirmation: \(trimmed)")
    }

    private static func formatLiveToolStatus(title: String, kind: String?) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return String(localized: "Running: \(trimmedTitle)")
        }
        if let trimmedKind, !trimmedKind.isEmpty {
            return String(localized: "Running: \(trimmedKind)")
        }
        return String(localized: "Calling tool…")
    }

    private func handleACPToolCallStatus(
        toolCallId: String?,
        title: String,
        kind: String?,
        status: String
    ) {
        if let toolCallId, !toolCallId.isEmpty {
            let previous = recentToolCallMetadata[toolCallId]
            let mergedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? (previous?.title ?? "")
                : title
            let mergedKind = (kind?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? kind
                : previous?.kind
            recentToolCallMetadata[toolCallId] = (title: mergedTitle, kind: mergedKind)
        }

        let loweredStatus = status.lowercased()
        if loweredStatus == "awaiting_permission" {
            updateLiveActivityStatus(Self.formatPermissionStatus(title: title))
        } else if ["completed", "failed", "cancelled", "canceled", "rejected", "denied", "error"].contains(loweredStatus) {
            if let toolCallId {
                clearACPPendingPermissions(forToolCallId: toolCallId)
            }
            if pendingPermissionRequests.isEmpty {
                updateLiveActivityStatus(String(localized: "Continuing…"))
            }
        } else {
            updateLiveActivityStatus(Self.formatLiveToolStatus(title: title, kind: kind))
        }
    }

    private func handleACPToolCallUpdateStatus(_ update: ACPToolCallUpdate) {
        let previous = update.toolCallId.flatMap { recentToolCallMetadata[$0] }
        let resolvedTitle: String = {
            if let title = update.title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return title
            }
            return previous?.title ?? ""
        }()
        let resolvedKind: String? = {
            if let kind = update.kind, !kind.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return kind
            }
            return previous?.kind
        }()
        if let toolCallId = update.toolCallId, !toolCallId.isEmpty {
            recentToolCallMetadata[toolCallId] = (title: resolvedTitle, kind: resolvedKind)
        }

        let loweredStatus = update.status?.lowercased() ?? ""
        if loweredStatus == "awaiting_permission" {
            updateLiveActivityStatus(Self.formatPermissionStatus(title: resolvedTitle))
        } else if ["completed", "failed", "cancelled", "canceled", "rejected", "denied", "error"].contains(loweredStatus) {
            if let toolCallId = update.toolCallId {
                clearACPPendingPermissions(forToolCallId: toolCallId)
            }
            if pendingPermissionRequests.isEmpty {
                updateLiveActivityStatus(String(localized: "Continuing…"))
            }
        } else if !resolvedTitle.isEmpty || resolvedKind != nil {
            updateLiveActivityStatus(Self.formatLiveToolStatus(title: resolvedTitle, kind: resolvedKind))
        }
    }


    /// Buffers incoming `session/update` replay mutations off `@Published chatMessages`,
    /// skipping intermediate Core Data writes and redundant content rebuilds until replay ends.
    func beginHistoryReplay(preserveExistingMessages: Bool = false) {
        passiveSettler.reset()
        if !preserveExistingMessages {
            hasExplicitActiveTurn = false
        }
        liveActivityStatus = nil
        if !activeReplayMode {
            activeReplayMode = true
            replayBufferMessages = preserveExistingMessages
                ? Self.sanitizeProcessArtifacts(
                    in: chatMessages,
                    keepPermissionRequestIds: activeACPPermissionRequestIds(forSessionId: currentSessionId)
                )
                : []
            replayDirtyMessageIndices.removeAll()
            if !preserveExistingMessages {
                streamingMessageId = nil
                toolCallSegmentLocations.removeAll()
            }
        } else if !preserveExistingMessages {
            replayBufferMessages = []
            replayDirtyMessageIndices.removeAll()
            streamingMessageId = nil
            toolCallSegmentLocations.removeAll()
        }
    }

    /// Commits buffered replay mutations to `chatMessages` in a single UI + storage update.
    func finishHistoryReplay(clearRemainingStreaming: Bool = true) {
        guard activeReplayMode else { return }
        activeReplayMode = false
        var buffer = replayBufferMessages ?? []
        replayBufferMessages = nil

        for index in replayDirtyMessageIndices.sorted() where buffer.indices.contains(index) {
            if let rebuilt = Self.rebuiltAssistantContent(for: buffer[index].segments) {
                buffer[index].content = rebuilt
            }
        }
        replayDirtyMessageIndices.removeAll()

        if clearRemainingStreaming {
            hasExplicitActiveTurn = false
            passiveSettler.reset()
            clearAllStreamingFlags(in: &buffer)
            streamingMessageId = nil
            liveActivityStatus = nil
            recentToolCallMetadata.removeAll()
            clearTrackedACPPendingPermissions(forSessionId: currentSessionId)
        }

        let keepIds = clearRemainingStreaming ? [] : activeACPPermissionRequestIds(forSessionId: currentSessionId)
        buffer = Self.sanitizeProcessArtifacts(in: buffer, keepPermissionRequestIds: keepIds)
        rebuildToolCallLocations(from: buffer)

        if !failedDeliveriesByMessageId.isEmpty {
            var failedBubbleIds = Set<UUID>()
            for record in failedDeliveriesByMessageId.values {
                failedBubbleIds.insert(record.userMessageId)
                if let errorMessageId = record.errorMessageId {
                    failedBubbleIds.insert(errorMessageId)
                }
            }
            var bufferIds = Set(buffer.map(\.id))
            for existing in chatMessages where failedBubbleIds.contains(existing.id) && !bufferIds.contains(existing.id) {
                buffer.append(existing)
                bufferIds.insert(existing.id)
            }
        }

        chatMessages = buffer
        if !clearRemainingStreaming {
            restoreStreamingState(from: chatMessages)
        }
        saveChatState(persistToStorage: true)
    }

    /// Drops an aborted replay buffer without modifying published `chatMessages`.
    func discardHistoryReplay() {
        activeReplayMode = false
        replayBufferMessages = nil
        replayDirtyMessageIndices.removeAll()
        toolCallSegmentLocations.removeAll()
    }

    func withWorkingMessages<Result>(_ body: (inout [ChatMessage]) -> Result) -> Result {
        if activeReplayMode {
            var buffer = replayBufferMessages ?? []
            // Clear backing storage during mutation so the local buffer maintains unique ownership (zero CoW).
            replayBufferMessages = nil
            defer { replayBufferMessages = buffer }
            return body(&buffer)
        }
        return body(&chatMessages)
    }

    func clearAllStreamingFlags(in messages: inout [ChatMessage]) {
        for index in messages.indices where messages[index].isStreaming {
            messages[index].isStreaming = false
        }
    }

    func markOrRebuildAssistantContent(at index: Int, in messages: inout [ChatMessage]) {
        if activeReplayMode {
            replayDirtyMessageIndices.insert(index)
            return
        }
        guard messages.indices.contains(index),
              let rebuilt = Self.rebuiltAssistantContent(for: messages[index].segments) else { return }
        messages[index].content = rebuilt
    }


    private func appendUserChunk(_ text: String) {
        guard !text.isEmpty else { return }

        let didMutate = withWorkingMessages { messages -> Bool in
            if streamingMessageId != nil {
                if let streamingIndex = messages.firstIndex(where: { $0.id == streamingMessageId }),
                   streamingIndex > 0,
                   messages[streamingIndex - 1].role == .user,
                   messages[streamingIndex - 1].content.contains(text) {
                    return false
                }
                finishStreamingMessage(in: &messages)
            }

            if let last = messages.indices.last, messages[last].role == .user {
                messages[last].content.append(text)
            } else {
                messages.append(ChatMessage(role: .user, content: text, isStreaming: false))
            }
            return true
        }
        if didMutate {
            saveChatState()
        }
    }

    func appendAssistantText(_ text: String, kind: AssistantSegment.Kind) {
        guard !text.isEmpty else { return }
        if !activeReplayMode, kind == .message, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            clearPendingPromptDelivery()
        }
        if kind != .message {
            if kind == .thought {
                updateLiveActivityStatus(String(localized: "Thinking…"))
            }
            return
        }
        let shouldPersist = withWorkingMessages { messages -> Bool in
            let index = ensureStreamingAssistantMessage(in: &messages)

            if kind == .message, messages[index].segments.isEmpty {
                let existing = messages[index].content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !existing.isEmpty {
                    // Resume snapshots can restore plain assistant content without segments.
                    // Seed a message segment first so subsequent deltas append instead of replacing content.
                    messages[index].segments.append(AssistantSegment(kind: .message, text: messages[index].content))
                }
            }

            if let lastIndex = messages[index].segments.indices.last,
               messages[index].segments[lastIndex].kind == kind,
               messages[index].segments[lastIndex].toolCall == nil {
                let lastText = messages[index].segments[lastIndex].text
                if lastText.hasSuffix("characters)") {
                    messages[index].segments.append(AssistantSegment(kind: kind, text: text))
                } else {
                    messages[index].segments[lastIndex].text.append(text)
                }
            } else {
                messages[index].segments.append(AssistantSegment(kind: kind, text: text))
            }
            markOrRebuildAssistantContent(at: index, in: &messages)
            return !messages[index].isStreaming
        }
        saveChatState(persistToStorage: shouldPersist)
    }

    func addAssistantSegments(_ segments: [AssistantSegment]) {
        guard !segments.isEmpty else { return }
        withWorkingMessages { messages in
            let message = ChatMessage(role: .assistant, content: "", isStreaming: false, segments: segments)
            messages.append(message)
            let index = messages.indices.last ?? 0
            markOrRebuildAssistantContent(at: index, in: &messages)
        }
        saveChatState()
    }


    func ensureStreamingAssistantMessage() -> Int {
        withWorkingMessages { messages in
            ensureStreamingAssistantMessage(in: &messages)
        }
    }

    func ensureStreamingAssistantMessage(in messages: inout [ChatMessage]) -> Int {
        if let streamingId = streamingMessageId,
           let index = messages.firstIndex(where: { $0.id == streamingId && $0.role == .assistant }) {
            // If a newer user prompt exists after the current streaming assistant row,
            // this pointer is stale (commonly after reopen/merge). Start a fresh
            // streaming assistant row at the tail so deltas attach to the latest turn.
            if let lastUserIndex = messages.lastIndex(where: { $0.role == .user }),
               lastUserIndex > index {
                messages[index].isStreaming = false
            } else {
                return index
            }
        }

        let message = ChatMessage(role: .assistant, content: "", isStreaming: true)
        messages.append(message)
        streamingMessageId = message.id
        return messages.indices.last ?? 0
    }

    /// Rebinds streaming state to a specific assistant message.
    /// If `messageId` is nil, all assistant messages are marked non-streaming.
    func bindStreamingAssistantMessage(to messageId: UUID?) {
        let didChange = withWorkingMessages { messages -> Bool in
            var changed = false
            for index in messages.indices {
                guard messages[index].role == .assistant else { continue }
                let shouldStream = (messages[index].id == messageId)
                if messages[index].isStreaming != shouldStream {
                    messages[index].isStreaming = shouldStream
                    changed = true
                }
            }
            if streamingMessageId != messageId {
                streamingMessageId = messageId
                changed = true
            }
            return changed
        }
        if didChange {
            saveChatState()
        }
    }

    func rebuildAssistantContent(at index: Int) {
        withWorkingMessages { messages in
            markOrRebuildAssistantContent(at: index, in: &messages)
        }
    }

    static func rebuiltAssistantContent(for segments: [AssistantSegment]) -> String? {
        guard !segments.isEmpty else { return nil }

        let lines = segments.compactMap { segment -> String? in
            switch segment.kind {
            case .message:
                return segment.text
            case .thought, .toolCall, .plan:
                return nil
            }
        }

        return lines.joined(separator: "\n")
    }

    func finishStreamingMessage() {
        hasExplicitActiveTurn = false
        passiveSettler.reset()
        withWorkingMessages { messages in
            finishStreamingMessage(in: &messages)
            clearAllStreamingFlags(in: &messages)
        }
        liveActivityStatus = nil
        recentToolCallMetadata.removeAll()
        saveChatState()
    }

    private func finishStreamingMessage(in messages: inout [ChatMessage]) {
        if let streamingId = streamingMessageId,
           let index = messages.firstIndex(where: { $0.id == streamingId }) {
            messages[index].isStreaming = false
        }
        streamingMessageId = nil

        liveActivityStatus = nil
        recentToolCallMetadata.removeAll()
        clearTrackedACPPendingPermissions(forSessionId: currentSessionId)
        messages = Self.sanitizeProcessArtifacts(in: messages, keepPermissionRequestIds: [])
        messages.removeAll { msg in
            msg.role == .assistant && !msg.isStreaming && !Self.hasRenderableAssistantPayload(msg)
        }
        rebuildToolCallLocations(from: messages)
    }

    func abandonStreamingMessage() {
        hasExplicitActiveTurn = false
        passiveSettler.reset()
        withWorkingMessages { messages in
            if let streamingId = streamingMessageId,
               let index = messages.firstIndex(where: { $0.id == streamingId }) {
                let message = messages[index]
                if message.segments.isEmpty && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    messages.remove(at: index)
                    toolCallSegmentLocations.removeAll()
                } else {
                    messages[index].isStreaming = false
                }
            }
            streamingMessageId = nil
            clearAllStreamingFlags(in: &messages)

            liveActivityStatus = nil
            recentToolCallMetadata.removeAll()
            clearTrackedACPPendingPermissions(forSessionId: currentSessionId)
            messages = Self.sanitizeProcessArtifacts(in: messages, keepPermissionRequestIds: [])
            messages.removeAll { msg in
                msg.role == .assistant && !msg.isStreaming && !Self.hasRenderableAssistantPayload(msg)
            }
            rebuildToolCallLocations(from: messages)
        }
        liveActivityStatus = nil
        recentToolCallMetadata.removeAll()
        saveChatState()
    }


    func rebuildToolCallLocations(from messages: [ChatMessage]) {
        toolCallSegmentLocations.removeAll()
        for msgIdx in messages.indices {
            for segIdx in messages[msgIdx].segments.indices {
                guard messages[msgIdx].segments[segIdx].kind == .toolCall,
                      let toolCallId = messages[msgIdx].segments[segIdx].toolCall?.toolCallId,
                      !toolCallId.isEmpty else { continue }
                toolCallSegmentLocations[toolCallId] = (msgIdx, segIdx)
            }
        }
    }

    static func hasRenderableAssistantPayload(_ message: ChatMessage) -> Bool {
        if message.isError || !message.images.isEmpty {
            return true
        }
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        return message.segments.contains { segment in
            switch segment.kind {
            case .message:
                return !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            case .toolCall:
                return segment.toolCall?.permissionOptions?.isEmpty == false
                    || segment.toolCall?.acpPermissionRequestId != nil
                    || segment.toolCall?.status == "awaiting_permission"
            case .thought, .plan:
                return false
            }
        }
    }

    /// Removes thought/plan/non-pending toolCall segments and legacy `"Tool call:"` plain lines
    /// from ACP chat histories while preserving active permission request cards.
    static func sanitizeProcessArtifacts(
        in messages: [ChatMessage],
        keepPermissionRequestIds: Set<ACP.ID>
    ) -> [ChatMessage] {
        var result: [ChatMessage] = []
        result.reserveCapacity(messages.count)

        for var message in messages {
            guard message.role == .assistant else {
                result.append(message)
                continue
            }

            let hadOriginalSegments = !message.segments.isEmpty
            if hadOriginalSegments {
                message.segments = message.segments.filter { segment in
                    switch segment.kind {
                    case .message:
                        return true
                    case .thought, .plan:
                        return false
                    case .toolCall:
                        let isPending = segment.toolCall?.permissionOptions?.isEmpty == false
                            || segment.toolCall?.status == "awaiting_permission"
                        guard isPending else { return false }
                        if let reqId = segment.toolCall?.acpPermissionRequestId {
                            return keepPermissionRequestIds.contains(reqId)
                        }
                        return !keepPermissionRequestIds.isEmpty
                    }
                }
            }

            if !message.segments.isEmpty {
                message.content = rebuiltAssistantContent(for: message.segments) ?? ""
            } else if hadOriginalSegments {
                message.content = ""
            } else {
                let rawLines = message.content.components(separatedBy: "\n")
                let filteredLines = rawLines.filter { line in
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    return !trimmed.hasPrefix("Tool call:")
                }
                if filteredLines.count != rawLines.count {
                    message.content = filteredLines
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }

            if message.isStreaming || hasRenderableAssistantPayload(message) {
                result.append(message)
            }
        }

        return result
    }
}
