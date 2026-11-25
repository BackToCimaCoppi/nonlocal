import Foundation
import ACPClient
import ACP

extension ACPSessionViewModel {
    /// Respond to a pending permission request with the user's choice.
    func sendPermissionResponse(requestId: ACP.ID, optionId: String) {
        guard let service = dependencies.getService() else {
            dependencies.append("Not connected")
            return
        }
        if let pending = pendingPermissionRequests.removeValue(forKey: requestId) {
            clearPermissionOptionsForToolCall(pending.toolCallId, requestId: requestId)
        }
        if pendingPermissionRequests.isEmpty, streamingMessageId != nil {
            updateLiveActivityStatus(String(localized: "Continuing…"))
        }
        if !activeReplayMode, !hasExplicitActiveTurn, pendingPermissionRequests.isEmpty,
           (isStreaming || liveActivityStatus != nil) {
            schedulePassiveStreamingSettle()
        }

        let response = ACPMessageBuilder.permissionResponseSelected(
            requestId: requestId,
            optionId: optionId
        )

        Task { @MainActor in
            do {
                try await service.sendMessage(response)
                dependencies.logWire("→", response)
                dependencies.append("Permission response: selected \(optionId)")
            } catch {
                dependencies.append("Failed to send permission response: \(error)")
            }
        }
    }

    /// Cancel all pending permission requests for a session.
    func cancelPendingPermissionRequests(for sessionIdToCancel: String) {
        let requestsToCancel = pendingPermissionRequests.filter { $0.value.sessionId == sessionIdToCancel }
        for (requestId, pending) in requestsToCancel {
            pendingPermissionRequests.removeValue(forKey: requestId)
            clearPermissionOptionsForToolCall(pending.toolCallId, requestId: requestId)

            guard let service = dependencies.getService() else { continue }
            let response = ACPMessageBuilder.permissionResponseCancelled(requestId: requestId)

            Task { @MainActor in
                do {
                    try await service.sendMessage(response)
                    dependencies.logWire("→", response)
                } catch {
                    dependencies.append("Failed to send cancelled permission response: \(error)")
                }
            }
        }
        if !requestsToCancel.isEmpty, pendingPermissionRequests.isEmpty {
            if streamingMessageId == nil {
                liveActivityStatus = nil
            } else {
                updateLiveActivityStatus(String(localized: "Permission request cancelled"))
            }
        }
    }

    /// Handle an incoming permission request from the agent.
    func handlePermissionRequest(_ request: ACP.AnyRequest) {
        guard let parsed = ACPPermissionRequestParser.parse(params: request.params) else {
            dependencies.append("Invalid permission request: missing params")
            return
        }

        let requestSessionId = parsed.sessionId ?? ""
        let toolCallId = parsed.toolCallId
        let toolTitle = parsed.toolCallTitle
        let toolKind = parsed.toolCallKind
        let requestId = request.id

        let options = parsed.options
        pendingPermissionRequests[requestId] = (sessionId: requestSessionId, toolCallId: toolCallId)

        updateToolCallWithPermission(
            toolCallId: toolCallId,
            title: toolTitle,
            kind: toolKind,
            options: options,
            requestId: requestId
        )
        updateLiveActivityStatus(Self.formatPermissionStatus(title: toolTitle))
        if !activeReplayMode, !hasExplicitActiveTurn {
            passiveSettler.cancelTimer()
        }

        let targetSessionId = requestSessionId.isEmpty ? (currentSessionId ?? "") : requestSessionId
        if let serverId = currentServerId, !targetSessionId.isEmpty {
            eventDelegate?.sessionDidRequestUserAction(serverId: serverId, sessionId: targetSessionId)
        }

        dependencies.append("Permission requested for: \(toolTitle) (options: \(options.map { $0.name }.joined(separator: ", ")))")
    }


    /// Send an error response to a request.
    func sendErrorResponse(to requestId: ACP.ID, code: Int, message: String) {
        guard let service = dependencies.getService() else { return }

        let errorResponse = ACPMessageBuilder.errorResponse(requestId: requestId, code: code, message: message)

        Task { @MainActor in
            do {
                try await service.sendMessage(errorResponse)
                dependencies.logWire("→", errorResponse)
            } catch {
                dependencies.append("Failed to send error response: \(error)")
            }
        }
    }

    func findToolCallSegment(
        toolCallId: String,
        in messages: [ChatMessage],
        assistantOnly: Bool,
        preferredMessageIndex: Int? = nil
    ) -> (messageIndex: Int, segmentIndex: Int)? {
        if let cached = toolCallSegmentLocations[toolCallId],
           messages.indices.contains(cached.messageIndex),
           (!assistantOnly || messages[cached.messageIndex].role == .assistant),
           messages[cached.messageIndex].segments.indices.contains(cached.segmentIndex) {
            let segment = messages[cached.messageIndex].segments[cached.segmentIndex]
            if (!assistantOnly || segment.kind == .toolCall),
               segment.toolCall?.toolCallId == toolCallId {
                return cached
            }
        }

        if let preferredMessageIndex,
           messages.indices.contains(preferredMessageIndex),
           (!assistantOnly || messages[preferredMessageIndex].role == .assistant),
           let segIdx = messages[preferredMessageIndex].segments.lastIndex(where: {
               (!assistantOnly || $0.kind == .toolCall) && $0.toolCall?.toolCallId == toolCallId
           }) {
            let location = (preferredMessageIndex, segIdx)
            toolCallSegmentLocations[toolCallId] = location
            return location
        }

        for msgIdx in messages.indices {
            if assistantOnly && messages[msgIdx].role != .assistant { continue }
            if let segIdx = messages[msgIdx].segments.firstIndex(where: {
                (!assistantOnly || $0.kind == .toolCall) && $0.toolCall?.toolCallId == toolCallId
            }) {
                let location = (msgIdx, segIdx)
                toolCallSegmentLocations[toolCallId] = location
                return location
            }
        }
        return nil
    }

    func recordToolCallLocation(_ toolCallId: String?, messageIndex: Int, segmentIndex: Int) {
        guard let toolCallId, !toolCallId.isEmpty else { return }
        toolCallSegmentLocations[toolCallId] = (messageIndex, segmentIndex)
    }

    func updateToolCallWithPermission(
        toolCallId: String?,
        title: String,
        kind: String?,
        options: [ACPPermissionOption],
        requestId: ACP.ID
    ) {
        withWorkingMessages { messages in
            if let toolCallId,
               let loc = findToolCallSegment(toolCallId: toolCallId, in: messages, assistantOnly: true) {
                messages[loc.messageIndex].segments[loc.segmentIndex].toolCall?.permissionOptions = options
                messages[loc.messageIndex].segments[loc.segmentIndex].toolCall?.acpPermissionRequestId = requestId
                messages[loc.messageIndex].segments[loc.segmentIndex].toolCall?.status = "awaiting_permission"
                markOrRebuildAssistantContent(at: loc.messageIndex, in: &messages)
                return
            }

            let index = ensureStreamingAssistantMessage(in: &messages)
            guard messages.indices.contains(index) else { return }

            if let toolCallId,
               let loc = findToolCallSegment(toolCallId: toolCallId, in: messages, assistantOnly: true, preferredMessageIndex: index),
               loc.messageIndex == index {
                messages[index].segments[loc.segmentIndex].toolCall?.permissionOptions = options
                messages[index].segments[loc.segmentIndex].toolCall?.acpPermissionRequestId = requestId
                messages[index].segments[loc.segmentIndex].toolCall?.status = "awaiting_permission"
            } else {
                var toolCall = ToolCallDisplay(toolCallId: toolCallId, title: title, kind: kind, status: "awaiting_permission")
                toolCall.permissionOptions = options
                toolCall.acpPermissionRequestId = requestId
                let newSegIndex = messages[index].segments.count
                messages[index].segments.append(AssistantSegment(kind: .toolCall, text: title, toolCall: toolCall))
                recordToolCallLocation(toolCallId, messageIndex: index, segmentIndex: newSegIndex)
            }

            markOrRebuildAssistantContent(at: index, in: &messages)
        }
        saveChatState()
    }

    /// Reconciles active ACP pending permissions against a bridge `nonlocal/sync` snapshot,
    /// removing temporary permission cards that are no longer awaiting a user response.
    func reconcilePendingPermissions(validRequestIds: Set<ACP.ID>) {
        let staleEntries = pendingPermissionRequests.filter { !validRequestIds.contains($0.key) }
        for (reqId, pending) in staleEntries {
            pendingPermissionRequests.removeValue(forKey: reqId)
            clearPermissionOptionsForToolCall(pending.toolCallId, requestId: reqId)
        }
        if !staleEntries.isEmpty, pendingPermissionRequests.isEmpty {
            if streamingMessageId == nil {
                liveActivityStatus = nil
            } else {
                updateLiveActivityStatus(String(localized: "Continuing…"))
            }
        }
    }

    func clearPermissionOptionsForToolCall(_ toolCallId: String?, requestId: ACP.ID? = nil) {
        let didUpdate = withWorkingMessages { messages -> Bool in
            var updatedIndexes: [Int] = []
            var removedAnySegment = false

            for msgIndex in messages.indices {
                guard messages[msgIndex].role == .assistant else { continue }
                let originalCount = messages[msgIndex].segments.count
                messages[msgIndex].segments.removeAll { segment in
                    guard segment.kind == .toolCall else { return false }
                    let matchesToolId = (toolCallId == nil || segment.toolCall?.toolCallId == toolCallId)
                    let matchesRequestId = (requestId == nil || segment.toolCall?.acpPermissionRequestId == requestId)
                    let hasPermission = segment.toolCall?.permissionOptions != nil
                        || segment.toolCall?.acpPermissionRequestId != nil
                        || segment.toolCall?.status == "awaiting_permission"
                    return matchesToolId && matchesRequestId && hasPermission
                }
                if messages[msgIndex].segments.count != originalCount {
                    removedAnySegment = true
                    updatedIndexes.append(msgIndex)
                }
            }

            guard !updatedIndexes.isEmpty else { return false }
            for index in Set(updatedIndexes) {
                markOrRebuildAssistantContent(at: index, in: &messages)
            }
            messages.removeAll { msg in
                msg.role == .assistant
                    && !msg.isStreaming
                    && !Self.hasRenderableAssistantPayload(msg)
            }
            if removedAnySegment {
                rebuildToolCallLocations(from: messages)
            }
            return true
        }
        if didUpdate {
            saveChatState()
        }
    }


    func clearACPPendingPermissions(forToolCallId toolCallId: String) {
        let matching = pendingPermissionRequests.filter { $0.value.toolCallId == toolCallId }
        for (reqId, pending) in matching {
            pendingPermissionRequests.removeValue(forKey: reqId)
            clearPermissionOptionsForToolCall(pending.toolCallId, requestId: reqId)
        }
    }

    func clearTrackedACPPendingPermissions(forSessionId sessionId: String?) {
        let keysToRemove = pendingPermissionRequests.compactMap { entry -> ACP.ID? in
            if let sessionId, !sessionId.isEmpty {
                return entry.value.sessionId.isEmpty || entry.value.sessionId == sessionId ? entry.key : nil
            }
            return entry.key
        }
        for key in keysToRemove {
            pendingPermissionRequests.removeValue(forKey: key)
        }
    }

    func activeACPPermissionRequestIds(forSessionId sessionId: String?) -> Set<ACP.ID> {
        Set(pendingPermissionRequests.compactMap { entry in
            if let sessionId, !sessionId.isEmpty {
                return entry.value.sessionId.isEmpty || entry.value.sessionId == sessionId ? entry.key : nil
            }
            return entry.key
        })
    }
}
