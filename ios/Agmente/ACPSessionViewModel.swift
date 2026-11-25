import Foundation
import ACPClient
import ACP
import UIKit

/// Pure in-memory delegate protocol for session cache operations (SD-2.4).
/// Strictly decoupled from Core Data persistence (`ACPSessionStorageDelegate`).
@MainActor
protocol ACPSessionCacheDelegate: AnyObject {
    func saveMessages(_ messages: [ChatMessage], for serverId: UUID, sessionId: String)
    func loadMessages(for serverId: UUID, sessionId: String) -> [ChatMessage]?
    func saveStopReason(_ reason: String, for serverId: UUID, sessionId: String)
    func loadStopReason(for serverId: UUID, sessionId: String) -> String?
    func clearCache(for serverId: UUID, sessionId: String)
    func clearCache(for serverId: UUID)
    func migrateCache(serverId: UUID, from placeholderId: String, to resolvedId: String)
    func hasCachedMessages(serverId: UUID, sessionId: String) -> Bool
    func getLastMessagePreview(for serverId: UUID, sessionId: String) -> String?
}

/// Persistent Core Data storage delegate owned by `ServerViewModel` (SD-2.4).
@MainActor
protocol ACPSessionStorageDelegate: AnyObject {
    func loadChatFromStorage(sessionId: String, serverId: UUID) -> [ChatMessage]
    func persistChatToStorage(serverId: UUID, sessionId: String, allowEmpty: Bool)
}

extension ACPSessionStorageDelegate {
    func persistChatToStorage(serverId: UUID, sessionId: String) {
        persistChatToStorage(serverId: serverId, sessionId: sessionId, allowEmpty: false)
    }
}

struct PendingPromptDelivery: Equatable {
    let userMessageId: UUID
    let promptText: String
    let images: [ImageAttachment]
    var clientTurnId: String?
}

struct FailedPromptDelivery: Equatable {
    let userMessageId: UUID
    let errorMessageId: UUID?
    let promptText: String
    let images: [ImageAttachment]
}

/// Delegate protocol for session events that require app-level handling.
/// Allows ACPSessionViewModel to notify AppViewModel about events without coupling.
@MainActor
protocol ACPSessionEventDelegate: AnyObject {
    /// Called when session mode changes.
    func sessionModeDidChange(_ modeId: String, serverId: UUID, sessionId: String)

    /// Called when stop reason is received and streaming should finish.
    func sessionDidReceiveStopReason(_ reason: String, serverId: UUID, sessionId: String)

    /// Called when session load completes and streaming should finish.
    func sessionLoadDidComplete(serverId: UUID, sessionId: String)

    /// Called when session metadata (title / last-activity timestamp) is updated
    /// via a `session_info_update` notification. Optional — defaults to a no-op
    /// for delegates that don't surface a session list.
    func sessionInfoDidUpdate(_ info: ACPSessionInfo, serverId: UUID, sessionId: String)

    /// Called when session config options are applied for a session so parent
    /// server view models can keep per-session snapshots intact across views.
    func sessionConfigOptionsDidUpdate(_ options: [ACPSessionConfigOption], serverId: UUID, sessionId: String)

    /// Called when available slash commands are updated for a session so parent
    /// server view models can keep per-session command caches intact across views.
    func sessionAvailableCommandsDidUpdate(_ commands: [SessionCommand], serverId: UUID, sessionId: String)

    /// Called when passive streaming settles after an idle timeout or post-prompt unresolved tool tail.
    func sessionPassiveStreamingDidSettle(serverId: UUID, sessionId: String)

    /// Called when a turn terminates with an error.
    func sessionDidFailTurn(serverId: UUID, sessionId: String)

    /// Called when a session pauses awaiting a user permission or approval decision.
    func sessionDidRequestUserAction(serverId: UUID, sessionId: String)
}

extension ACPSessionEventDelegate {
    func sessionInfoDidUpdate(_ info: ACPSessionInfo, serverId: UUID, sessionId: String) {}
    func sessionConfigOptionsDidUpdate(_ options: [ACPSessionConfigOption], serverId: UUID, sessionId: String) {}
    func sessionAvailableCommandsDidUpdate(_ commands: [SessionCommand], serverId: UUID, sessionId: String) {}
    func sessionPassiveStreamingDidSettle(serverId: UUID, sessionId: String) {}
    func sessionDidFailTurn(serverId: UUID, sessionId: String) {}
    func sessionDidRequestUserAction(serverId: UUID, sessionId: String) {}
}

@MainActor
final class ACPSessionViewModel: ObservableObject {
    typealias PassiveStreamingSettleDelays = Agmente.PassiveStreamingSettleDelays

    struct Dependencies {
        let getService: () -> ACPService?
        let append: (String) -> Void
        let logWire: (String, ACPWireMessage) -> Void
    }

    @Published var currentModeId: String?
    @Published private(set) var availableModes: [AgentModeOption] = []
    @Published private(set) var sessionConfigOptions: [ACPSessionConfigOption] = []
    /// The model id selected in this app session, applied via the spec method
    /// `session/set_config_option`. Distinct from mode selection.
    @Published private(set) var selectedModelId: String?
    @Published private(set) var availableCommands: [SessionCommand] = []
    @Published var promptText: String = ""
    @Published private(set) var attachedImages: [ImageAttachment] = []
    @Published private(set) var supportsImageAttachment: Bool = false
    @Published var chatMessages: [ChatMessage] = []
    @Published private(set) var stopReason: String = ""
    /// Latest context-window usage / cost reported by the agent via `usage_update`.
    @Published var usage: ACPUsageInfo?
    /// Current agent plan for the active session.
    @Published var plan: [ACPPlanEntry] = []
    /// Single-line real-time activity indicator shown in the trailing spinner bubble for ACP sessions.
    @Published var liveActivityStatus: String?
    private(set) var pendingPromptDelivery: PendingPromptDelivery?
    @Published private(set) var failedDeliveriesByMessageId: [UUID: FailedPromptDelivery] = [:]

    var failedDeliveryMessageIds: Set<UUID> {
        Set(failedDeliveriesByMessageId.keys)
    }

    weak var cacheDelegate: ACPSessionCacheDelegate?
    weak var storageDelegate: ACPSessionStorageDelegate?
    weak var eventDelegate: ACPSessionEventDelegate?
    let dependencies: Dependencies
    let passiveSettler: PassiveStreamingSettler
    let sessionUpdateHandler = ACPSessionUpdateHandler()
    var streamingMessageId: UUID?
    var hasExplicitActiveTurn = false
    var currentServerId: UUID?
    var currentSessionId: String?
    var sessionModeCache: [UUID: [String: String]] = [:]
    var pendingPermissionRequests: [ACP.ID: (sessionId: String, toolCallId: String?)] = [:]
    var recentToolCallMetadata: [String: (title: String, kind: String?)] = [:]
    var sessionCommandsCache: [UUID: [String: [SessionCommand]]] = [:]

    var replayBufferMessages: [ChatMessage]?
    var activeReplayMode = false
    var replayDirtyMessageIndices: Set<Int> = []
    var toolCallSegmentLocations: [String: (messageIndex: Int, segmentIndex: Int)] = [:]

    var isReplayingHistory: Bool {
        activeReplayMode
    }

    init(
        dependencies: Dependencies,
        passiveSettleDelays: PassiveStreamingSettleDelays = .default
    ) {
        self.dependencies = dependencies
        self.passiveSettler = PassiveStreamingSettler(delays: passiveSettleDelays)
        self.passiveSettler.onSettle = { [weak self] notifySettle in
            guard let self,
                  !self.activeReplayMode,
                  !self.hasExplicitActiveTurn,
                  !self.hasPendingUserAction,
                  self.isActivelyRunning else {
                return
            }
            self.finishStreamingMessage()
            if notifySettle,
               let serverId = self.currentServerId,
               let sessionId = self.currentSessionId,
               !sessionId.isEmpty {
                self.eventDelegate?.sessionPassiveStreamingDidSettle(serverId: serverId, sessionId: sessionId)
            }
        }
    }

    func resetStreamingState() {
        hasExplicitActiveTurn = false
        passiveSettler.reset()
        streamingMessageId = nil
    }

    /// Clears transient streaming state before an off-screen history reload while keeping
    /// currently visible messages on screen until replay finishes atomically.
    func prepareForHistoryReload() {
        hasExplicitActiveTurn = false
        passiveSettler.reset()
        streamingMessageId = nil
        liveActivityStatus = nil
        recentToolCallMetadata.removeAll()
        clearAllStreamingFlags(in: &chatMessages)
    }

    func markExplicitActiveTurn() {
        hasExplicitActiveTurn = true
        passiveSettler.reset()
    }

    func clearExplicitActiveTurn() {
        hasExplicitActiveTurn = false
    }

    func restoreStreamingState(from messages: [ChatMessage]) {
        streamingMessageId = messages.last(where: { $0.isStreaming })?.id
    }

    func currentStreamingAssistantMessageId() -> UUID? {
        streamingMessageId
    }

    var isStreaming: Bool {
        if activeReplayMode {
            return false
        }
        return streamingMessageId != nil || chatMessages.contains(where: { $0.isStreaming })
    }

    var hasPendingUserAction: Bool {
        !pendingPermissionRequests.isEmpty
    }

    var isActivelyRunning: Bool {
        if activeReplayMode || hasPendingUserAction {
            return false
        }
        return hasExplicitActiveTurn
            || passiveSettler.hasActiveWork
            || streamingMessageId != nil
            || liveActivityStatus != nil
            || chatMessages.contains(where: { $0.isStreaming })
    }

    var hasUnresolvedPassiveToolCalls: Bool {
        passiveSettler.hasUnresolvedPassiveToolCalls
    }

    var hasInMemorySessionData: Bool {
        !(replayBufferMessages ?? chatMessages).isEmpty
            || streamingMessageId != nil
            || !sessionConfigOptions.isEmpty
            || !availableModes.isEmpty
            || selectedModelId != nil
    }

    func ownsPermissionRequest(_ requestId: ACP.ID) -> Bool {
        pendingPermissionRequests[requestId] != nil
    }

    // MARK: - Image Attachments

    var canAttachMoreImages: Bool {
        supportsImageAttachment && attachedImages.count < ImageProcessor.maxAttachments
    }

    func setSupportsImageAttachment(_ supports: Bool) {
        supportsImageAttachment = supports
        if !supports {
            clearImageAttachments()
        }
    }

    func replaceAttachments(_ attachments: [ImageAttachment]) {
        attachedImages = attachments
    }

    @discardableResult
    func addImageAttachment(_ image: UIImage) -> Bool {
        guard canAttachMoreImages else {
            dependencies.append("Cannot attach more images (limit: \(ImageProcessor.maxAttachments))")
            return false
        }

        guard let attachment = ImageProcessor.processImage(image) else {
            dependencies.append("Failed to process image")
            return false
        }

        attachedImages.append(attachment)
        dependencies.append("Attached image (\(attachment.sizeDescription))")
        return true
    }

    func removeImageAttachment(_ id: UUID) {
        attachedImages.removeAll { $0.id == id }
    }

    func clearImageAttachments() {
        attachedImages.removeAll()
    }

    func setCurrentModeId(_ modeId: String?) {
        currentModeId = modeId
    }

    func setAvailableModes(_ modes: [AgentModeOption], currentModeId: String? = nil) {
        if !modes.isEmpty {
            availableModes = modes
        } else if availableModes.isEmpty,
                  let modeInfo = ACPSessionConfigOptionParser.modeInfo(from: sessionConfigOptions),
                  !modeInfo.availableModes.isEmpty {
            availableModes = modeInfo.availableModes
        }
        if let currentModeId {
            self.currentModeId = currentModeId
        }
    }

    func applySessionConfigOptions(
        _ options: [ACPSessionConfigOption],
        serverId: UUID?,
        sessionId: String
    ) {
        sessionConfigOptions = options

        if let modeInfo = ACPSessionConfigOptionParser.modeInfo(from: options) {
            availableModes = modeInfo.availableModes
            if let modeId = modeInfo.currentModeId {
                currentModeId = modeId
                cacheCurrentMode(serverId: serverId, sessionId: sessionId)
            }
        }

        // Adopt the agent-reported current model, if it surfaces one as a config
        // option, so the picker reflects it. Intentionally do NOT clear
        // `selectedModelId` when the snapshot omits the model option — a
        // defensive/partial snapshot must not wipe a live selection; only a
        // session switch/reset (loadChatState/resetChatState) clears it.
        if let modelValue = options.first(where: { $0.id == ACPModelConfig.configId })?.currentValue.stringValue,
           !modelValue.isEmpty {
            selectedModelId = modelValue
        }

        if let serverId, !sessionId.isEmpty, !options.isEmpty {
            eventDelegate?.sessionConfigOptionsDidUpdate(options, serverId: serverId, sessionId: sessionId)
        }
    }

    func visibleConfigOptions() -> [ACPSessionConfigOption] {
        sessionConfigOptions.filter { !$0.isModeSelector }
    }

    // MARK: - Model Selection

    /// The active model id: the local selection, else an agent-reported "model"
    /// config option value.
    var currentModelId: String? {
        selectedModelId
            ?? sessionConfigOptions.first(where: { $0.id == ACPModelConfig.configId })?.currentValue.stringValue
    }

    /// Applies a model selection via the spec method
    /// `session/set_config_option` (`configId: "model"`).
    ///
    /// The selection is applied optimistically and **reverted on every failure
    /// path** (not connected, no active session, or an RPC error) so the picker
    /// never strands a phantom active model.
    func sendSetModel(
        _ modelId: String,
        sessionId: String,
        serverId: UUID?
    ) {
        // Guard preconditions before touching state, so a disconnected/no-session
        // tap never shows the model as active.
        guard let service = dependencies.getService() else {
            dependencies.append("Not connected")
            return
        }
        guard !sessionId.isEmpty else {
            dependencies.append("No active session")
            return
        }

        // Optimistically reflect the selection, capturing the prior value so we
        // can revert if the set is rejected.
        let previousModelId = selectedModelId
        selectedModelId = modelId

        let payload = ACPSessionSetConfigOptionPayload(
            sessionId: sessionId,
            configId: ACPModelConfig.configId,
            value: .string(modelId)
        )

        Task { @MainActor in
            do {
                _ = try await service.setSessionConfigOption(payload)
                if let index = sessionConfigOptions.firstIndex(where: { $0.id == ACPModelConfig.configId }) {
                    let existing = sessionConfigOptions[index]
                    sessionConfigOptions[index] = ACPSessionConfigOption(
                        id: existing.id,
                        name: existing.name,
                        description: existing.description,
                        category: existing.category,
                        kind: existing.kind,
                        currentValue: .string(modelId)
                    )
                    applySessionConfigOptions(sessionConfigOptions, serverId: serverId, sessionId: sessionId)
                }
                dependencies.append("Set model to: \(modelId)")
            } catch {
                // Revert so the picker doesn't strand a phantom active model.
                selectedModelId = previousModelId
                dependencies.append("Failed to set model: \(error)")
            }
        }
    }

    func cacheCurrentMode(serverId: UUID?, sessionId: String) {
        guard let serverId, !sessionId.isEmpty else { return }
        var serverModes = sessionModeCache[serverId] ?? [:]
        if let modeId = currentModeId {
            serverModes[sessionId] = modeId
        } else {
            serverModes.removeValue(forKey: sessionId)
        }
        sessionModeCache[serverId] = serverModes
    }

    func cachedMode(for serverId: UUID, sessionId: String) -> String? {
        sessionModeCache[serverId]?[sessionId]
    }

    func migrateSessionModeCache(for serverId: UUID, from placeholderId: String, to resolvedId: String) {
        guard placeholderId != resolvedId else { return }
        if var serverModes = sessionModeCache[serverId],
           let mode = serverModes[placeholderId],
           serverModes[resolvedId] == nil {
            serverModes[resolvedId] = mode
            sessionModeCache[serverId] = serverModes
        }
    }

    // MARK: - Commands

    func resetCommands() {
        availableCommands = []
    }

    func handleAvailableCommandsUpdate(
        _ commands: [SessionCommand],
        serverId: UUID?,
        sessionId: String
    ) {
        availableCommands = commands.map { cmd in
            SessionCommand(id: cmd.id, name: cmd.name, description: cmd.description, inputHint: cmd.inputHint)
        }
        cacheAvailableCommands(serverId: serverId, sessionId: sessionId)
        if let serverId, !sessionId.isEmpty {
            eventDelegate?.sessionAvailableCommandsDidUpdate(availableCommands, serverId: serverId, sessionId: sessionId)
        }
    }

    func restoreAvailableCommands(for serverId: UUID, sessionId: String, isNew: Bool) {
        if let cached = sessionCommandsCache[serverId]?[sessionId] {
            availableCommands = cached
        } else if isNew {
            availableCommands = []
        }
    }

    func migrateSessionCommandsCache(for serverId: UUID, from placeholderId: String, to resolvedId: String) {
        guard placeholderId != resolvedId else { return }
        if var serverCommands = sessionCommandsCache[serverId],
           let commands = serverCommands[placeholderId],
           serverCommands[resolvedId] == nil {
            serverCommands[resolvedId] = commands
            sessionCommandsCache[serverId] = serverCommands
        }
    }

    func removeCommands(for serverId: UUID, sessionId: String) {
        var serverCommands = sessionCommandsCache[serverId] ?? [:]
        serverCommands.removeValue(forKey: sessionId)
        sessionCommandsCache[serverId] = serverCommands
    }

    func removeServerCommandsCache(for serverId: UUID) {
        sessionCommandsCache.removeValue(forKey: serverId)
    }

    private func cacheAvailableCommands(serverId: UUID?, sessionId: String) {
        guard let serverId, !sessionId.isEmpty else { return }
        var serverCommands = sessionCommandsCache[serverId] ?? [:]
        serverCommands[sessionId] = availableCommands
        sessionCommandsCache[serverId] = serverCommands
    }

    func sendSetMode(
        _ modeId: String,
        sessionId: String,
        serverId: UUID?
    ) {
        guard let service = dependencies.getService() else {
            dependencies.append("Not connected")
            return
        }
        guard !sessionId.isEmpty else {
            dependencies.append("No active session")
            return
        }

        Task { @MainActor in
            do {
                if let modeOption = sessionConfigOptions.first(where: { $0.isModeSelector }) {
                    let payload = ACPSessionSetConfigOptionPayload(
                        sessionId: sessionId,
                        configId: modeOption.id,
                        value: .string(modeId)
                    )
                    _ = try await service.setSessionConfigOption(payload)
                } else {
                    let payload = ACPSessionSetModePayload(sessionId: sessionId, modeId: modeId)
                    _ = try await service.setSessionMode(payload)
                }
                setCurrentModeId(modeId)
                cacheCurrentMode(serverId: serverId, sessionId: sessionId)
                dependencies.append("Set mode to: \(modeId)")
            } catch {
                dependencies.append("Failed to set mode: \(error)")
            }
        }
    }

    func sendSetConfigOption(
        configId: String,
        value: ACPSessionConfigOptionValue,
        sessionId: String,
        serverId: UUID?
    ) {
        guard let service = dependencies.getService() else {
            dependencies.append("Not connected")
            return
        }
        guard !sessionId.isEmpty else {
            dependencies.append("No active session")
            return
        }

        let payload = ACPSessionSetConfigOptionPayload(
            sessionId: sessionId,
            configId: configId,
            value: value
        )

        Task { @MainActor in
            do {
                _ = try await service.setSessionConfigOption(payload)
                if let index = sessionConfigOptions.firstIndex(where: { $0.id == configId }) {
                    let existing = sessionConfigOptions[index]
                    sessionConfigOptions[index] = ACPSessionConfigOption(
                        id: existing.id,
                        name: existing.name,
                        description: existing.description,
                        category: existing.category,
                        kind: existing.kind,
                        currentValue: value
                    )
                    applySessionConfigOptions(sessionConfigOptions, serverId: serverId, sessionId: sessionId)
                }
                dependencies.append("Updated \(configId)")
            } catch {
                dependencies.append("Failed to update \(configId): \(error)")
            }
        }
    }

    // MARK: - Message Composition Helpers

    /// Adds a user message to the chat with optional images.
    @discardableResult
    func addUserMessage(content: String, images: [ChatImageData]) -> UUID {
        let message = ChatMessage(role: .user, content: content, isStreaming: false, images: images)
        withWorkingMessages { messages in
            messages.append(message)
        }
        saveChatState()
        return message.id
    }

    // MARK: - Undelivered Prompt Tracking & Manual Restore

    func recordPendingPromptDelivery(
        userMessageId: UUID,
        promptText: String,
        images: [ImageAttachment],
        clientTurnId: String? = nil
    ) {
        pendingPromptDelivery = PendingPromptDelivery(
            userMessageId: userMessageId,
            promptText: promptText,
            images: images,
            clientTurnId: clientTurnId
        )
    }

    func setPendingPromptDeliveryClientTurnId(_ clientTurnId: String?) {
        pendingPromptDelivery?.clientTurnId = clientTurnId
    }

    func clearPendingPromptDelivery() {
        pendingPromptDelivery = nil
    }

    func markPendingPromptDeliveryFailed(errorMessageId: UUID?) {
        guard let pending = pendingPromptDelivery else { return }
        pendingPromptDelivery = nil
        failedDeliveriesByMessageId[pending.userMessageId] = FailedPromptDelivery(
            userMessageId: pending.userMessageId,
            errorMessageId: errorMessageId,
            promptText: pending.promptText,
            images: pending.images
        )
    }

    func restoreFailedDelivery(for userMessageId: UUID) {
        guard let record = failedDeliveriesByMessageId.removeValue(forKey: userMessageId) else {
            return
        }

        if !record.promptText.isEmpty {
            if promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                promptText = record.promptText
            } else {
                promptText = "\(promptText)\n\(record.promptText)"
            }
        }

        if !record.images.isEmpty {
            let merged = attachedImages + record.images
            replaceAttachments(Array(merged.prefix(ImageProcessor.maxAttachments)))
        }

        var idsToRemove: Set<UUID> = [record.userMessageId]
        if let errorMessageId = record.errorMessageId {
            idsToRemove.insert(errorMessageId)
        }
        chatMessages.removeAll { idsToRemove.contains($0.id) }
        if replayBufferMessages != nil {
            replayBufferMessages?.removeAll { idsToRemove.contains($0.id) }
        }
        rebuildToolCallLocations(from: chatMessages)

        saveChatState(persistToStorage: true, allowEmpty: true)
    }

    /// Adds a completed assistant message to the chat.
    func addAssistantMessage(_ content: String) {
        let message = ChatMessage(role: .assistant, content: content, isStreaming: false)
        withWorkingMessages { messages in
            messages.append(message)
        }
        saveChatState()
    }

    /// Adds a system message (informational, not error) to the chat.
    func addSystemMessage(_ content: String) {
        let message = ChatMessage(role: .system, content: content, isStreaming: false, isError: false)
        withWorkingMessages { messages in
            messages.append(message)
        }
        saveChatState()
    }

    /// Starts a new streaming assistant response.
    func startNewStreamingResponse() {
        hasExplicitActiveTurn = true
        passiveSettler.reset()
        withWorkingMessages { messages in
            let streaming = ChatMessage(role: .assistant, content: "", isStreaming: true)
            messages.append(streaming)
            streamingMessageId = streaming.id
            restoreStreamingState(from: messages)
        }
        updateLiveActivityStatus(String(localized: "Thinking…"))
        saveChatState(persistToStorage: false)
    }

    /// Adds a system error message to the chat.
    @discardableResult
    func addSystemErrorMessage(_ message: String) -> UUID {
        let errorMessage = ChatMessage(role: .system, content: message, isStreaming: false, isError: true)
        withWorkingMessages { messages in
            messages.append(errorMessage)
        }
        saveChatState()
        return errorMessage.id
    }

    // MARK: - Chat State Management

    /// Set the current session context for state management.
    func setSessionContext(serverId: UUID?, sessionId: String?) {
        currentServerId = serverId
        currentSessionId = sessionId
    }

    /// Save current chat messages and stop reason to cache.
    func saveChatState(persistToStorage: Bool = true, allowEmpty: Bool = false) {
        guard !activeReplayMode else { return }
        guard let serverId = currentServerId, let sessionId = currentSessionId, !sessionId.isEmpty else { return }

        // Save to cache via delegate
        cacheDelegate?.saveMessages(chatMessages, for: serverId, sessionId: sessionId)
        if !stopReason.isEmpty {
            cacheDelegate?.saveStopReason(stopReason, for: serverId, sessionId: sessionId)
        }

        // Persist to storage if needed (for agents without session/load support)
        if persistToStorage {
            storageDelegate?.persistChatToStorage(serverId: serverId, sessionId: sessionId, allowEmpty: allowEmpty)
        }
    }

    /// Load chat messages and stop reason from cache or storage.
    func loadChatState(serverId: UUID, sessionId: String, canLoadFromStorage: Bool) {
        hasExplicitActiveTurn = false
        passiveSettler.reset()
        discardHistoryReplay()
        currentServerId = serverId
        currentSessionId = sessionId
        liveActivityStatus = nil
        recentToolCallMetadata.removeAll()

        // Plan is a live, non-persisted snapshot scoped to a session; clear it
        // on switch so a stale plan never bleeds into another session.
        plan = []

        // Config options and the model selection are likewise live, session-scoped
        // state — the agent re-advertises them per session via activation and
        // `config_option_update`. Clear on switch so a stale set/selection never
        // bleeds into another session before the new session's snapshot arrives.
        sessionConfigOptions = []
        selectedModelId = nil

        var shouldPersistCleanedStorage = false

        // Check cache first via delegate
        if let cachedChat = cacheDelegate?.loadMessages(for: serverId, sessionId: sessionId) {
            let keepIds = activeACPPermissionRequestIds(forSessionId: sessionId)
            let cleaned = Self.sanitizeProcessArtifacts(in: cachedChat, keepPermissionRequestIds: keepIds)
            chatMessages = cleaned
            if cleaned != cachedChat {
                cacheDelegate?.saveMessages(cleaned, for: serverId, sessionId: sessionId)
            }
        } else if canLoadFromStorage {
            let storedMessages = storageDelegate?.loadChatFromStorage(sessionId: sessionId, serverId: serverId) ?? []
            if !storedMessages.isEmpty {
                let cleaned = Self.sanitizeProcessArtifacts(in: storedMessages, keepPermissionRequestIds: [])
                chatMessages = cleaned
                cacheDelegate?.saveMessages(cleaned, for: serverId, sessionId: sessionId)
                shouldPersistCleanedStorage = (cleaned != storedMessages)
                dependencies.append("Restored \(cleaned.count) message(s) from local storage")
            } else {
                chatMessages = []
            }
        } else {
            chatMessages = []
        }

        rebuildToolCallLocations(from: chatMessages)

        // Load stop reason from cache via delegate
        if let cachedStop = cacheDelegate?.loadStopReason(for: serverId, sessionId: sessionId) {
            stopReason = cachedStop
        } else {
            stopReason = ""
        }

        restoreStreamingState(from: chatMessages)
        if shouldPersistCleanedStorage {
            storageDelegate?.persistChatToStorage(serverId: serverId, sessionId: sessionId)
        }
    }

    /// Reset chat state (clear messages and stop reason).
    func resetChatState() {
        hasExplicitActiveTurn = false
        passiveSettler.reset()
        discardHistoryReplay()
        chatMessages = []
        stopReason = ""
        usage = nil
        plan = []
        sessionConfigOptions = []
        selectedModelId = nil
        streamingMessageId = nil
        liveActivityStatus = nil
        recentToolCallMetadata.removeAll()
        pendingPermissionRequests.removeAll()
        pendingPromptDelivery = nil
        failedDeliveriesByMessageId.removeAll()
        currentServerId = nil
        currentSessionId = nil
    }

    /// Set stop reason and save to cache.
    func setStopReason(_ reason: String) {
        stopReason = reason
        saveChatState()
    }

    /// Handle stop reason received from server.
    func handleStopReason(
        _ reason: String,
        hasUnresolvedToolCalls: Bool = false,
        notifyList: Bool = true,
        serverId: UUID,
        sessionId: String
    ) {
        setSessionContext(serverId: serverId, sessionId: sessionId)
        if reason != "error" {
            clearPendingPromptDelivery()
        }
        setStopReason(reason)
        if reason != "cancelled", hasUnresolvedToolCalls {
            hasExplicitActiveTurn = false
            passiveSettler.markDeferredStopCompletion(
                hasUnresolvedToolCalls: true,
                notifyOnSettle: notifyList,
                canSchedule: canSchedulePassiveStreamingSettle
            )
            return
        }
        finishStreamingMessage()
        if notifyList {
            eventDelegate?.sessionDidReceiveStopReason(reason, serverId: serverId, sessionId: sessionId)
        }
    }

    /// Handle session load completion.
    func handleSessionLoadCompleted(serverId: UUID, sessionId: String) {
        if activeReplayMode {
            finishHistoryReplay(clearRemainingStreaming: true)
        } else {
            hasExplicitActiveTurn = false
            passiveSettler.reset()
            clearAllStreamingFlags(in: &chatMessages)
            streamingMessageId = nil
            liveActivityStatus = nil
            recentToolCallMetadata.removeAll()
            clearTrackedACPPendingPermissions(forSessionId: sessionId)
            chatMessages = Self.sanitizeProcessArtifacts(in: chatMessages, keepPermissionRequestIds: [])
            rebuildToolCallLocations(from: chatMessages)
            saveChatState()
        }
        // Notify delegate
        eventDelegate?.sessionLoadDidComplete(serverId: serverId, sessionId: sessionId)
    }

    /// Set chat messages directly (for backward compatibility).
    func setChatMessages(_ messages: [ChatMessage]) {
        discardHistoryReplay()
        let keepIds = activeACPPermissionRequestIds(forSessionId: currentSessionId)
        chatMessages = Self.sanitizeProcessArtifacts(in: messages, keepPermissionRequestIds: keepIds)
        rebuildToolCallLocations(from: chatMessages)
        restoreStreamingState(from: chatMessages)
    }

    func handleNonlocalTurnError(_ message: String, notifyList: Bool = true, serverId: UUID, sessionId: String) {
        setSessionContext(serverId: serverId, sessionId: sessionId)
        abandonStreamingMessage()
        let errorMessageId = addSystemErrorMessage(message)
        if pendingPromptDelivery != nil {
            markPendingPromptDeliveryFailed(errorMessageId: errorMessageId)
        }
        if notifyList {
            eventDelegate?.sessionDidFailTurn(serverId: serverId, sessionId: sessionId)
        }
    }

    /// Merges draft state and messages from a placeholder VM into an already-created
    /// resolved VM without clobbering resolved session config options or modes.
    func mergePreservingRuntimeState(from placeholder: ACPSessionViewModel, serverId: UUID, sessionId: String) {
        setSessionContext(serverId: serverId, sessionId: sessionId)
        if pendingPromptDelivery == nil, let placeholderPending = placeholder.pendingPromptDelivery {
            pendingPromptDelivery = placeholderPending
        }
        for (userMessageId, record) in placeholder.failedDeliveriesByMessageId where failedDeliveriesByMessageId[userMessageId] == nil {
            failedDeliveriesByMessageId[userMessageId] = record
        }
        if promptText.isEmpty, !placeholder.promptText.isEmpty {
            promptText = placeholder.promptText
        }
        if attachedImages.isEmpty, !placeholder.attachedImages.isEmpty {
            replaceAttachments(placeholder.attachedImages)
        }
        if availableCommands.isEmpty, !placeholder.availableCommands.isEmpty {
            handleAvailableCommandsUpdate(
                placeholder.availableCommands,
                serverId: serverId,
                sessionId: sessionId
            )
        }
        if sessionConfigOptions.isEmpty, !placeholder.sessionConfigOptions.isEmpty {
            applySessionConfigOptions(placeholder.sessionConfigOptions, serverId: serverId, sessionId: sessionId)
        }
        if availableModes.isEmpty, !placeholder.availableModes.isEmpty {
            setAvailableModes(placeholder.availableModes, currentModeId: placeholder.currentModeId)
        }
        if selectedModelId == nil, let selected = placeholder.selectedModelId {
            selectedModelId = selected
        }
        if chatMessages.isEmpty, !placeholder.chatMessages.isEmpty {
            hasExplicitActiveTurn = hasExplicitActiveTurn || placeholder.hasExplicitActiveTurn
            placeholder.passiveSettler.reset()
            toolCallSegmentLocations.removeAll()
            let keepIds = activeACPPermissionRequestIds(forSessionId: sessionId)
            chatMessages = Self.sanitizeProcessArtifacts(
                in: placeholder.chatMessages,
                keepPermissionRequestIds: keepIds
            )
            rebuildToolCallLocations(from: chatMessages)
            restoreStreamingState(from: chatMessages)
        } else if !placeholder.failedDeliveriesByMessageId.isEmpty {
            var failedBubbleIds = Set<UUID>()
            for record in placeholder.failedDeliveriesByMessageId.values {
                failedBubbleIds.insert(record.userMessageId)
                if let errorMessageId = record.errorMessageId {
                    failedBubbleIds.insert(errorMessageId)
                }
            }
            var existingIds = Set(chatMessages.map(\.id))
            for msg in placeholder.chatMessages where failedBubbleIds.contains(msg.id) && !existingIds.contains(msg.id) {
                chatMessages.append(msg)
                existingIds.insert(msg.id)
            }
        }
        saveChatState()
    }

}
