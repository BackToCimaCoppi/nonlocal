import Foundation
import SwiftUI
import Combine
import ACPClient
import ACP

enum SessionRenameError: LocalizedError, Equatable {
    case emptySessionId
    case pendingSessionNotMaterialized
    case notConnected
    case unsupportedRemoteRename
    case rpcFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptySessionId:
            return String(localized: "Cannot rename: session ID is empty.")
        case .pendingSessionNotMaterialized:
            return String(localized: "Send the first message before renaming this session.")
        case .notConnected:
            return String(localized: "Not connected to server; cannot rename session.")
        case .unsupportedRemoteRename:
            return String(localized: "This server does not support remote renaming.")
        case .rpcFailed(let message):
            let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? String(localized: "Failed to rename session.") : trimmed
        }
    }
}

/// Phase 2: ServerViewModel
/// Each server has its own ServerViewModel instance managing:
/// - Connection state and lifecycle
/// - Sessions for this server
/// - Server configuration
@MainActor
final class ServerViewModel: ObservableObject, Identifiable {
    // `ACP` also defines `SessionSummary`; keep local usages pinned to ACPClient.
    typealias SessionSummary = ACPClientSessionSummary

    /// Synthetic capability-probe session IDs that must never be remembered or displayed as chats.
    static let ignoredProbeSessionIds: Set<String> = ["capability-probe"]

    // MARK: - Server Configuration

    let id: UUID
    @Published var name: String
    @Published var scheme: String
    @Published var host: String
    @Published var token: String
    @Published var workingDirectory: String

    var endpointURLString: String {
        "\(scheme)://\(host)"
    }

    // MARK: - Connection State

    /// Connection state delegated to connectionManager.
    var connectionState: ACPConnectionState { connectionManager.connectionState }
    /// Whether a connection attempt is in progress.
    var isConnecting: Bool { connectionManager.isConnecting }
    /// Whether network is available.
    var isNetworkAvailable: Bool { connectionManager.isNetworkAvailable }
    /// Last successful connection timestamp.
    var lastConnectedAt: Date? { connectionManager.lastConnectedAt }
    /// Whether initialize has completed for the current connection.
    var isInitialized: Bool { connectionManager.isInitialized }

    // MARK: - Sessions

    /// Dictionary of session view models keyed by session ID (from Phase 1)
    var sessionViewModels: [String: ACPSessionViewModel] = [:]
    var sessionViewModelCancellables: [String: AnyCancellable] = [:]
    var sessionConfigOptionsCache: [String: [ACPSessionConfigOption]] = [:]
    var latestServerConfigOptions: [ACPSessionConfigOption]?
    var sessionModesCache: [String: ACPModesInfo] = [:]
    var sessionCommandsCache: [String: [SessionCommand]] = [:]
    var defaultModelPreferences: DefaultModelPreferences = DefaultModelPreferences()

    @Published var sessionSummaries: [SessionSummary] = []
    @Published var selectedSessionId: String?
    @Published var sessionId: String = ""

    /// Returns or lazily creates the SessionViewModel for an arbitrary session ID.
    func sessionViewModel(for targetSessionId: String) -> ACPSessionViewModel {
        if let existing = sessionViewModels[targetSessionId] {
            return existing
        }
        let viewModel = createSessionViewModel(for: targetSessionId)
        viewModel.setSessionContext(serverId: id, sessionId: targetSessionId)
        sessionViewModels[targetSessionId] = viewModel
        setupSessionViewModelObservation(for: targetSessionId, viewModel: viewModel)
        return viewModel
    }

    func existingSessionViewModel(for targetSessionId: String) -> ACPSessionViewModel? {
        sessionViewModels[targetSessionId]
    }

    func allSessionViewModels() -> [String: ACPSessionViewModel] {
        sessionViewModels
    }

    func cacheConfigOptions(_ options: [ACPSessionConfigOption], for targetSessionId: String) {
        guard !targetSessionId.isEmpty, !options.isEmpty else { return }
        sessionConfigOptionsCache[targetSessionId] = options
        latestServerConfigOptions = options
    }

    func cachedConfigOptions(for targetSessionId: String) -> [ACPSessionConfigOption]? {
        sessionConfigOptionsCache[targetSessionId]
    }

    func serverConfigOptionsForModelCatalog() -> [ACPSessionConfigOption]? {
        if let latest = latestServerConfigOptions, !latest.isEmpty {
            return latest
        }
        return sessionConfigOptionsCache.values.first(where: { !$0.isEmpty })
    }

    func makeSessionCreatePayload(workingDirectory: String) -> ACPSessionCreatePayload {
        ACPSessionCreatePayload(
            workingDirectory: workingDirectory,
            mcpServers: [],
            meta: defaultModelPreferences.sessionCreateMeta(
                for: id,
                serverConfigOptions: serverConfigOptionsForModelCatalog()
            )
        )
    }

    func cacheModes(_ modes: ACPModesInfo, for targetSessionId: String) {
        guard !targetSessionId.isEmpty, !modes.availableModes.isEmpty else { return }
        sessionModesCache[targetSessionId] = modes
        if availableModes.isEmpty {
            availableModes = modes.availableModes
        }
        if defaultModeId == nil {
            defaultModeId = modes.currentModeId
        }
    }

    func cachedModes(for targetSessionId: String) -> ACPModesInfo? {
        sessionModesCache[targetSessionId]
    }

    func cacheAvailableCommands(_ commands: [SessionCommand], for targetSessionId: String, allowEmpty: Bool = false) {
        guard !targetSessionId.isEmpty else { return }
        if commands.isEmpty {
            if allowEmpty {
                sessionCommandsCache.removeValue(forKey: targetSessionId)
            }
            return
        }
        sessionCommandsCache[targetSessionId] = commands
    }

    func cachedAvailableCommands(for targetSessionId: String) -> [SessionCommand]? {
        sessionCommandsCache[targetSessionId]
    }

    func updateAvailableModesIfEmpty(_ modes: [AgentModeOption]) {
        guard !modes.isEmpty, availableModes.isEmpty else { return }
        availableModes = modes
    }

    /// Returns the SessionViewModel for the currently selected session.
    var currentSessionViewModel: ACPSessionViewModel? {
        guard let sessionId = selectedSessionId, !sessionId.isEmpty else { return nil }
        return sessionViewModel(for: sessionId)
    }

    var isStreaming: Bool {
        currentSessionViewModel?.chatMessages.contains(where: { $0.isStreaming }) ?? false
    }

    /// True when the active session hasn't been materialized on the server yet.
    var isPendingSession: Bool {
        pendingLocalSessions.contains(sessionId)
    }

    // MARK: - Activity Dot & Unread State

    let unreadTracker = SessionUnreadTracker()
    var manuallyCancelledSessionIds: Set<String> = []
    var localPinnedTimestampsBySessionId: [String: Date] = [:]
    var sessionsAwaitingServerTimestamp: Set<String> = []
    var activeViewingSessionId: String? {
        didSet {
            guard activeViewingSessionId != oldValue else { return }
            if let sid = activeViewingSessionId, !sid.isEmpty {
                markSessionRead(sid)
            } else {
                objectWillChange.send()
            }
        }
    }

    var hasInitializedUnreadBaseline: Bool {
        unreadTracker.hasInitializedBaseline
    }

    func isSessionRunning(_ sessionId: String) -> Bool {
        sessionViewModels[sessionId]?.isActivelyRunning ?? false
    }

    func isSessionWaitingForUser(_ sessionId: String) -> Bool {
        sessionViewModels[sessionId]?.hasPendingUserAction ?? false
    }

    func isSessionUnread(_ sessionId: String) -> Bool {
        unreadTracker.isUnread(sessionId)
    }

    func markSessionRead(_ sessionId: String) {
        guard !sessionId.isEmpty else { return }
        objectWillChange.send()
        let awaitServer = sessionsAwaitingServerTimestamp.remove(sessionId) != nil
        let absorb = awaitServer || unreadTracker.latestKnownServerUpdatedAt(for: sessionId) == nil
        unreadTracker.markRead(
            sessionId,
            absorbNextServerTime: absorb,
            forServerId: id,
            storage: storage
        )
    }

    func hydrateUnreadStateFromStorage() {
        guard let storage else { return }
        let stored = Self.fetchCleanStoredSessions(from: storage, serverId: id)
        let initialized = storage.isUnreadBaselineInitialized(forServerId: id)
        unreadTracker.hydrate(from: stored, baselineInitialized: initialized)
        for info in stored {
            if let seen = info.lastSeenServerUpdatedAt {
                lastKnownServerUpdatedAt[info.sessionId] = seen
            }
        }
    }

    // MARK: - Agent Info & Modes

    @Published private(set) var agentInfo: AgentProfile?
    @Published var availableModes: [AgentModeOption] = []
    @Published private(set) var initializationSummary: String = "Not initialized"
    
    /// The default mode ID from the initialize response, applied to new sessions.
    var defaultModeId: String?

    /// Update agent info after initialization. Called by AppViewModel to sync capabilities.
    func updateAgentInfo(_ info: AgentProfile) {
        self.agentInfo = info
        if !info.modes.isEmpty {
            self.availableModes = info.modes
        }
        
        // Propagate capability changes to all active session view models
        let supportsImages = info.capabilities.promptCapabilities.image
        for viewModel in sessionViewModels.values {
            viewModel.setSupportsImageAttachment(supportsImages)
        }
    }

    // MARK: - Three-State Row Status & Counts (SD-2.3)

    func isSessionCurrentlyVisible(_ sessionId: String) -> Bool {
        !sessionId.isEmpty && activeViewingSessionId == sessionId
    }

    func sessionRowStatus(for sessionId: String) -> SessionRowStatus {
        let isVisible = isSessionCurrentlyVisible(sessionId)
        if isSessionWaitingForUser(sessionId), !isVisible {
            return .unread
        }
        if isSessionRunning(sessionId) {
            return .running
        }
        if isSessionUnread(sessionId), !isVisible {
            return .unread
        }
        return .read
    }

    var runningSessionCount: Int {
        sessionSummaries.reduce(0) { count, summary in
            count + (sessionRowStatus(for: summary.id) == .running ? 1 : 0)
        }
    }

    var unreadSessionCount: Int {
        sessionSummaries.reduce(0) { count, summary in
            count + (sessionRowStatus(for: summary.id) == .unread ? 1 : 0)
        }
    }

    // MARK: - Private State

    /// Connection manager handles network monitoring, reconnection, and connection lifecycle.
    let connectionManager: ACPClientManager
    /// Convenience accessor for the active service.
    var service: ACPService? { connectionManager.service }

    /// Cache delegates and dependencies
    weak var cacheDelegate: ACPSessionCacheDelegate?
    weak var eventDelegate: ACPSessionEventDelegate?
    weak var storage: SessionStorage?
    let getServiceClosure: () -> ACPService?
    let appendClosure: (String) -> Void
    let logWireClosure: (String, ACPWireMessage) -> Void

    /// Session-related state (internal for extension split across ServerViewModel+SessionList / +SessionLifecycle)
    var sessionCache: String = ""
    var lastLoadedSession: String?
    var pendingLocalSessions: Set<String> = []
    var pendingLocalSessionCwds: [String: String] = [:]
    var pendingLocalSessionNewCwds: [String: Bool] = [:]
    var creatingSessionTasks: [String: Task<Void, Never>] = [:]
    var pendingSessionLoad: String?

    /// Placeholder ID -> Resolved ID mapping (active handoff table consumed by submitPrompt/openSession)
    var resolvedSessionIds: [String: String] = [:]
    var inFlightSessionLoads: Set<String> = []
    var pendingReloadSessions: Set<String> = []
    var lastKnownServerUpdatedAt: [String: Date] = [:]

    /// Connection-related state
    var pendingNewSessionCwd: String?
    var pendingNewSessionPlaceholderId: String?
    var openSessionRequestTokens: [String: UInt64] = [:]
    var nextOpenSessionToken: UInt64 = 0

    /// Exact prune & external deletion protection state (T3 / DP-2.2)
    var listFetchGeneration: UInt64 = 0
    var activeListFetchGeneration: UInt64 = 0
    var recentlyCreatedSessionGenerations: [String: UInt64] = [:]
    var recentlyDeletedSessionGenerations: [String: UInt64] = [:]

    func markSessionRecentlyDeleted(_ sessionId: String) {
        guard !sessionId.isEmpty else { return }
        recentlyDeletedSessionGenerations[sessionId] = listFetchGeneration
    }
    var syncedProtectedSessionIds: Set<String> = []
    var hasCompletedNonlocalSync: Bool = false
    var deferredCompleteSessionList: (sessions: [SessionSummary], generation: UInt64)?
    var onActiveSessionPruned: ((String) -> Void)?

    var hasInitialSyncPendingClosure: (() -> Bool)?
    var initialSyncBarrier: (() async -> Void)?
    var recordSentClientTurnId: ((String, String) -> Void)?
    var clearClientTurnId: ((String, String) -> Void)?
    var markClientTurnCompleted: ((String, String) -> Void)?
    var passiveSettleDelays: ACPSessionViewModel.PassiveStreamingSettleDelays = .default

    func pendingNewSessionContext() -> (placeholderId: String?, cwd: String?) {
        (pendingNewSessionPlaceholderId, pendingNewSessionCwd)
    }

    func clearPendingNewSessionContext() {
        pendingNewSessionCwd = nil
        pendingNewSessionPlaceholderId = nil
    }

    func startupLog(_ message: String) {
        print("[APP][STARTUP] \(message)")
    }

    // MARK: - Initialization

    init(
        id: UUID,
        name: String,
        scheme: String,
        host: String,
        token: String,
        workingDirectory: String = "/",
        connectionManager: ACPClientManager,
        getService: @escaping () -> ACPService?,
        append: @escaping (String) -> Void,
        logWire: @escaping (String, ACPWireMessage) -> Void,
        cacheDelegate: ACPSessionCacheDelegate? = nil,
        storage: SessionStorage? = nil
    ) {
        self.id = id
        self.name = name
        self.scheme = scheme
        self.host = host
        self.token = token
        self.workingDirectory = workingDirectory
        self.connectionManager = connectionManager
        self.getServiceClosure = getService
        self.appendClosure = append
        self.logWireClosure = logWire
        self.cacheDelegate = cacheDelegate
        self.eventDelegate = self  // ServerViewModel now implements ACPSessionEventDelegate
        self.storage = storage
        hydrateUnreadStateFromStorage()
    }

    // MARK: - Session ViewModel Management (from Phase 1)

    /// Creates a new SessionViewModel instance for the given session ID.
    func createSessionViewModel(for sessionId: String) -> ACPSessionViewModel {
        let viewModel = ACPSessionViewModel(
            dependencies: .init(
                getService: getServiceClosure,
                append: appendClosure,
                logWire: logWireClosure
            ),
            passiveSettleDelays: passiveSettleDelays
        )

        // Set delegates and context upfront so background permissions/settles know serverId & sessionId.
        viewModel.setSessionContext(serverId: id, sessionId: sessionId)
        viewModel.cacheDelegate = cacheDelegate
        viewModel.storageDelegate = self
        viewModel.eventDelegate = eventDelegate

        // Set image attachment support based on agent capabilities
        let supportsImages = agentInfo?.capabilities.promptCapabilities.image ?? false
        viewModel.setSupportsImageAttachment(supportsImages)

        return viewModel
    }

    /// Sets up observation for a session view model to forward its changes.
    func setupSessionViewModelObservation(for sessionId: String, viewModel: ACPSessionViewModel) {
        let cancellable = viewModel.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sessionViewModelCancellables[sessionId] = cancellable
    }

    /// Tracks placeholder session IDs that have resolved to server-assigned session IDs so navigation destinations stay bound.
    var resolvedSessionIdsByPlaceholder: [String: String] = [:]

    func effectiveSessionId(for sessionId: String) -> String {
        resolvedSessionIdsByPlaceholder[sessionId] ?? sessionId
    }

    /// Migrates a session view model from placeholder ID to resolved ID,
    /// merging safely if the resolved VM already exists from an earlier response/sync.
    func migrateSessionViewModel(from placeholderId: String, to resolvedId: String) {
        guard placeholderId != resolvedId else { return }
        resolvedSessionIdsByPlaceholder[placeholderId] = resolvedId

        if let cachedConfigs = sessionConfigOptionsCache.removeValue(forKey: placeholderId),
           sessionConfigOptionsCache[resolvedId] == nil {
            sessionConfigOptionsCache[resolvedId] = cachedConfigs
        }
        if let cachedModes = sessionModesCache.removeValue(forKey: placeholderId),
           sessionModesCache[resolvedId] == nil {
            sessionModesCache[resolvedId] = cachedModes
        }
        if let cachedCommands = sessionCommandsCache.removeValue(forKey: placeholderId),
           sessionCommandsCache[resolvedId] == nil {
            sessionCommandsCache[resolvedId] = cachedCommands
        }

        if let placeholderViewModel = sessionViewModels.removeValue(forKey: placeholderId) {
            if let existingResolved = sessionViewModels[resolvedId] {
                sessionViewModelCancellables.removeValue(forKey: placeholderId)?.cancel()
                existingResolved.mergePreservingRuntimeState(
                    from: placeholderViewModel,
                    serverId: id,
                    sessionId: resolvedId
                )
            } else {
                sessionViewModels[resolvedId] = placeholderViewModel
                placeholderViewModel.setSessionContext(serverId: id, sessionId: resolvedId)

                if let cancellable = sessionViewModelCancellables.removeValue(forKey: placeholderId) {
                    sessionViewModelCancellables[resolvedId] = cancellable
                }
            }
        }
    }

    /// Removes a session view model and cleans up its observation.
    func removeSessionViewModel(for sessionId: String) {
        sessionViewModels.removeValue(forKey: sessionId)
        sessionViewModelCancellables.removeValue(forKey: sessionId)?.cancel()
    }

    /// Removes all session view models for this server.
    func removeAllSessionViewModels() {
        sessionViewModels.removeAll()
        for cancellable in sessionViewModelCancellables.values {
            cancellable.cancel()
        }
        sessionViewModelCancellables.removeAll()
    }

    // MARK: - Session Helper Methods

    /// Check if this server supports session/load capability.
    func canLoadSession() -> Bool {
        agentInfo?.capabilities.loadSession ?? true
    }

    /// Check if there are cached messages for a session.
    func hasCachedMessages(sessionId: String) -> Bool {
        return cacheDelegate?.loadMessages(for: id, sessionId: sessionId)?.isEmpty == false
    }

    /// Core Data message persistence owned directly by ServerViewModel (SD-2.4 / SC-AC-044).
    func loadChatFromStorage(sessionId: String) -> [ChatMessage] {
        guard let storage else { return [] }
        return storage.fetchMessages(forSessionId: sessionId, serverId: id).map { ChatMessage(from: $0) }
    }

    func persistChatToStorage(sessionId: String, allowEmpty: Bool = false) {
        guard let storage else { return }
        let targetVM = existingSessionViewModel(for: sessionId)
        let messagesToStore = targetVM?.chatMessages.filter { !$0.isStreaming } ?? []
        if messagesToStore.isEmpty {
            if allowEmpty {
                storage.saveMessages([], forSessionId: sessionId, serverId: id)
                return
            }
            if let targetVM, !targetVM.isStreaming, targetVM.chatMessages.isEmpty {
                let existingStored = storage.fetchMessages(forSessionId: sessionId, serverId: id)
                if !existingStored.isEmpty {
                    let sanitizedStored = ACPSessionViewModel.sanitizeProcessArtifacts(
                        in: existingStored.map { ChatMessage(from: $0) },
                        keepPermissionRequestIds: []
                    )
                    if sanitizedStored.isEmpty {
                        storage.saveMessages([], forSessionId: sessionId, serverId: id)
                    }
                }
            }
            return
        }

        let matchedSummary = sessionSummaries.first(where: { $0.id == sessionId })
        let title = matchedSummary?.title
        let cwd = matchedSummary?.cwd
        storage.saveSession(
            StoredSessionInfo(sessionId: sessionId, title: title, cwd: cwd, updatedAt: nil),
            forServerId: id,
            clearTitleWhenNil: (matchedSummary != nil && title == nil)
        )
        let storedMessages = messagesToStore.map { $0.toStoredInfo() }
        storage.saveMessages(storedMessages, forSessionId: sessionId, serverId: id)
    }

    /// Sanitize working directory input.
    func sanitizeWorkingDirectory(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "~" : trimmed
    }

    /// Resolved working directory for this server.
    var resolvedWorkingDirectory: String {
        sanitizeWorkingDirectory(workingDirectory)
    }

    /// Remember a working directory as recently used.
    /// Returns true if this is a new working directory that was just added.
    @discardableResult
    func rememberUsedWorkingDirectory(_ cwd: String) -> Bool {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return storage?.addUsedWorkingDirectory(trimmed, forServerId: id) ?? false
    }

    /// Re-fetch sessions if a new working directory was added and the agent supports session listing.
    func refetchSessionsIfNeeded(newCwdAdded: Bool) {
        guard newCwdAdded else { return }
        guard let agentInfo = agentInfo, agentInfo.capabilities.listSessions else { return }
        guard connectionState == .connected else { return }

        appendClosure("New working directory detected; re-fetching sessions from all directories")
        fetchSessionList(force: true)
    }

    /// Remember session in cache and storage.
    /// Returns true if a new working directory was added.
    @discardableResult
    func rememberSession(_ sessionId: String, cwd: String? = nil, updateSessionCache: Bool = true) -> Bool {
        guard !sessionId.isEmpty, !Self.ignoredProbeSessionIds.contains(sessionId) else { return false }
        if updateSessionCache {
            sessionCache = sessionId
        }
        let sessionCwd = cwd ?? resolvedWorkingDirectory
        let now = Date()

        // Track timestamp and title from existing session (if any)
        let existingSession = sessionSummaries.first(where: { $0.id == sessionId })
        let timestamp = existingSession?.updatedAt ?? now
        let title = existingSession?.title

        if let index = sessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            let existing = sessionSummaries[index]
            if cwd != nil && existing.cwd != sessionCwd {
                sessionSummaries[index] = SessionSummary(
                    id: existing.id,
                    title: existing.title,
                    cwd: sessionCwd,
                    updatedAt: existing.updatedAt
                )
                setSessionSummaries(sessionSummaries)
            }
        } else {
            sessionSummaries.insert(SessionSummary(id: sessionId, title: nil, cwd: sessionCwd, updatedAt: now), at: 0)
            setSessionSummaries(sessionSummaries)
        }

        // Never persist local-only draft sessions.
        guard !pendingLocalSessions.contains(sessionId) else { return false }

        let sessionInfo = StoredSessionInfo(sessionId: sessionId, title: title, cwd: sessionCwd, updatedAt: timestamp)
        storage?.saveSession(sessionInfo, forServerId: id)
        return rememberUsedWorkingDirectory(sessionCwd)
    }
}

// MARK: - ACPSessionStorageDelegate

extension ServerViewModel: ACPSessionStorageDelegate {
    func loadChatFromStorage(sessionId: String, serverId: UUID) -> [ChatMessage] {
        guard serverId == id else { return [] }
        return loadChatFromStorage(sessionId: sessionId)
    }

    func persistChatToStorage(serverId: UUID, sessionId: String, allowEmpty: Bool) {
        guard serverId == id else { return }
        persistChatToStorage(sessionId: sessionId, allowEmpty: allowEmpty)
    }
}

// MARK: - ACPSessionEventDelegate

extension ServerViewModel: ACPSessionEventDelegate {
    func sessionModeDidChange(_ modeId: String, serverId: UUID, sessionId: String) {
        // Log mode change for user visibility
        appendClosure("Mode changed to: \(modeId)")
        guard serverId == id else { return }
        if let existing = sessionModesCache[sessionId] {
            sessionModesCache[sessionId] = ACPModesInfo(
                availableModes: existing.availableModes,
                currentModeId: modeId
            )
        }
    }

    func sessionDidReceiveStopReason(_ reason: String, serverId: UUID, sessionId: String) {
        appendClosure("Prompt stopReason: \(reason)")
        guard serverId == id else { return }
        handleTurnPausedOrEnded(
            sessionId: sessionId,
            reasonCancelled: reason == "cancelled",
            isError: false,
            requiresUserAction: false
        )
    }

    func sessionPassiveStreamingDidSettle(serverId: UUID, sessionId: String) {
        guard serverId == id else { return }
        handleTurnPausedOrEnded(
            sessionId: sessionId,
            reasonCancelled: false,
            isError: false,
            requiresUserAction: false
        )
    }

    func sessionDidFailTurn(serverId: UUID, sessionId: String) {
        guard serverId == id else { return }
        handleTurnPausedOrEnded(
            sessionId: sessionId,
            reasonCancelled: false,
            isError: true,
            requiresUserAction: false
        )
    }

    func sessionDidRequestUserAction(serverId: UUID, sessionId: String) {
        guard serverId == id else { return }
        handleTurnPausedOrEnded(
            sessionId: sessionId,
            reasonCancelled: false,
            isError: false,
            requiresUserAction: true
        )
    }

    func sessionLoadDidComplete(serverId: UUID, sessionId: String) {
        // Track that this session was successfully loaded
        connectionManager.markSessionMaterialized(sessionId)
        lastLoadedSession = sessionId
    }

    func sessionConfigOptionsDidUpdate(_ options: [ACPSessionConfigOption], serverId: UUID, sessionId: String) {
        guard serverId == id else { return }
        cacheConfigOptions(options, for: sessionId)
    }

    func sessionAvailableCommandsDidUpdate(_ commands: [SessionCommand], serverId: UUID, sessionId: String) {
        guard serverId == id else { return }
        cacheAvailableCommands(commands, for: sessionId, allowEmpty: true)
    }

    func sessionInfoDidUpdate(_ info: ACPSessionInfo, serverId: UUID, sessionId: String) {
        guard serverId == id,
              let index = sessionSummaries.firstIndex(where: { $0.id == sessionId }) else { return }
        let existing = sessionSummaries[index]
        // Title updates never mutate updatedAt (list ordering only advances on prompt send and turn pause/end).
        let normalizedIncoming = info.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingTitle = (normalizedIncoming?.isEmpty == false) ? normalizedIncoming : nil
        let newTitle = info.hasTitle ? incomingTitle : existing.title
        guard newTitle != existing.title else { return }
        sessionSummaries[index] = SessionSummary(
            id: existing.id,
            title: newTitle,
            cwd: existing.cwd,
            updatedAt: existing.updatedAt
        )
        setSessionSummaries(sessionSummaries)
        if info.hasTitle {
            storage?.updateSession(
                sessionId: sessionId,
                forServerId: id,
                title: newTitle,
                touchUpdatedAt: false,
                clearTitle: (newTitle == nil)
            )
        }
    }
}
