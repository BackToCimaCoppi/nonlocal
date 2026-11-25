import SwiftUI
import Combine
import ACPClient
import ACP

/// Application-level coordinator (SD-2.4).
/// Unidirectionally composes `ServerConnectionPool`, `BridgeServerValidator`, `BridgeSyncCoordinator`,
/// `QuotaManager`, `ChatMessageCache`, `ProjectStore`, and per-server `ServerViewModel` instances.
@MainActor
final class AppViewModel: ObservableObject, ServerConnectionSlotDelegateOwner, ACPSessionCacheDelegate {
    typealias SessionSummary = ACPClientSessionSummary

    // MARK: - Composed Domain Components (Unique State Owners)

    let storage: SessionStorage
    let defaults: UserDefaults
    let projectStore: ProjectStore
    let connectionPool: ServerConnectionPool
    let validator: BridgeServerValidator
    let syncCoordinator: BridgeSyncCoordinator
    let quotaManager: QuotaManager
    let chatCache: ChatMessageCache

    // MARK: - Top-Level Observable State

    @Published var devModeEnabled: Bool = false {
        didSet { defaults.set(devModeEnabled, forKey: devModeKey) }
    }
    @Published private(set) var servers: [ACPServerConfiguration] = []
    @Published var selectedServerId: UUID?
    @Published private(set) var activeViewingServerId: UUID?
    @Published private(set) var activeViewingSessionId: String?
    @Published private(set) var availableModes: [AgentModeOption] = []
    @Published private(set) var initializationSummary: String = "Not initialized"
    @Published private(set) var isInitialAppLaunch: Bool = true
    private var hasHandledColdLaunchAutoSession: Bool = false
    @Published var persistedHomeDisplayMode: HomeDisplayMode?
    @Published var lastNewSessionServerId: UUID?

    // Protected internal byte anchors (G-7 / SC-AC-011)
    @Published var clientName: String = "Agmente iOS"
    @Published var clientVersion: String = "0.1.0"
    @Published var supportsFSRead: Bool = false
    @Published var supportsFSWrite: Bool = false
    @Published var supportsTerminal: Bool = false

    let lastServerKey = "Agmente.lastServerId"
    let homeDisplayModeKey = "nonlocal.homeDisplayMode.v1"
    private let devModeKey = "Agmente.devModeEnabled"
    private static let legacyClientIdKey = "Agmente.clientId"
    private static let legacyLastConnectedAtKey = "Agmente.lastConnectedAt"
    private static let connectionClientIdKey = "ACPClientManager.clientId"
    private static let connectionLastConnectedAtKey = "ACPClientManager.lastConnectedAt"
    private static let legacyCodexLoggingKey = "Agmente.codexSessionLoggingEnabled"
    private static let legacyHighPerformanceRendererKey = "Agmente.useHighPerformanceChatRenderer"
    private static let legacySummaryCardCollapsedKey = "summaryCardCollapsed"
    private static let legacyCodexPermissionPresetPrefix = "Agmente.codexPermissionPreset."

    var serverViewModels: [UUID: ServerViewModel] = [:]
    private var serverViewModelCancellables: [UUID: AnyCancellable] = [:]

    var onSessionDeletedPop: ((UUID, String) -> Void)?

    private let encoder = JSONEncoder()
    private var agentInfoCache: [UUID: AgentProfile] = [:]
    private var initializationCache: [UUID: String] = [:]
    var initializedServers: Set<UUID> = []
    var sessionCache: [UUID: String] = [:]
    var resumeRefreshTask: Task<Void, Never>?
    private var lastResumeRefreshAt: Date?

    // MARK: - Read-Only Selected Server Config (SD-2.7: no shadow @Published / didSet persistence)

    var selectedServer: ACPServerConfiguration? {
        guard let id = selectedServerId else { return nil }
        return servers.first(where: { $0.id == id })
    }

    var scheme: String { selectedServer?.scheme ?? BridgeServerValidator.defaultScheme }
    var endpointHost: String { selectedServer?.host ?? "" }
    var token: String { selectedServer?.token ?? "" }
    var workingDirectory: String { selectedServer?.workingDirectory ?? "/" }

    var selectedServerViewModel: ServerViewModel? {
        guard let serverId = selectedServerId else { return nil }
        return serverViewModels[serverId]
    }

    // MARK: - Connection Pool Projections

    var connectionSlots: [UUID: ServerConnectionSlot] { connectionPool.slots }
    var activeConnectionManager: ACPClientManager? { selectedServerId.flatMap { connectionPool.managerIfExists(for: $0) } }
    var connectionState: ACPConnectionState { activeConnectionManager?.connectionState ?? .disconnected }
    var isConnecting: Bool { activeConnectionManager?.isConnecting ?? false }
    var isNetworkAvailable: Bool { activeConnectionManager?.isNetworkAvailable ?? true }
    var lastConnectedAt: Date? { activeConnectionManager?.lastConnectedAt }
    var wasPreempted: Bool { activeConnectionManager?.wasPreempted ?? false }
    var service: ACPService? { selectedServerId.flatMap { connectionPool.service(for: $0) } }
    var updates: [LogLine] { selectedServerId.flatMap { connectionPool.updates(for: $0) } ?? [] }

    var hasEnteredBackgroundSinceLastActive: Bool {
        get { connectionPool.hasEnteredBackgroundSinceLastActive }
        set { connectionPool.hasEnteredBackgroundSinceLastActive = newValue }
    }

    // MARK: - Sync & Quota Projections

    var isSyncingByServer: [UUID: Bool] { syncCoordinator.isSyncingByServer }
    var currentBridgeInstanceId: [UUID: String] { syncCoordinator.currentBridgeInstanceId }
    var quotaSnapshotByServer: [UUID: NonlocalUsageResult] { quotaManager.snapshotByServer }
    var quotaConfirmedSupportByServer: [UUID: Bool] { quotaManager.confirmedSupportByServer }
    var connectionUsageStateByServer: [UUID: ConnectionUsageState] { quotaManager.connectionUsageStateByServer }
    var currentQuotaSnapshot: NonlocalUsageResult? { quotaManager.snapshot(for: selectedServerId) }
    var isCurrentServerQuotaSupported: Bool { quotaManager.shouldShowQuotaCard(for: selectedServerId) }
    var isAppInForeground: Bool {
        get { quotaManager.isAppInForeground }
        set { quotaManager.isAppInForeground = newValue }
    }

    // MARK: - Selected Server Convenience Projections

    var serverSessionSummaries: [SessionSummary] { selectedServerViewModel?.sessionSummaries ?? [] }
    var serverSessionId: String { selectedServerViewModel?.sessionId ?? "" }
    var serverIsStreaming: Bool { selectedServerViewModel?.isStreaming ?? false }
    var serverAgentInfo: AgentProfile? { selectedServerViewModel?.agentInfo }
    var serverIsPendingSession: Bool { selectedServerViewModel?.isPendingSession ?? false }
    var isPendingSession: Bool { selectedServerViewModel?.isPendingSession ?? false }
    var currentServerName: String { selectedServer?.name ?? AppLocalization.localized("Select server") }
    var currentAgentInfo: AgentProfile? { selectedServerId.flatMap { agentInfoCache[$0] } }
    var currentSessionListSupport: Bool? { selectedServerId.flatMap { agentInfoCache[$0]?.capabilities.listSessions } }
    var currentLoadSessionSupport: Bool? { selectedServerId.flatMap { agentInfoCache[$0]?.capabilities.loadSession } }
    var defaultWorkingDirectory: String { selectedServer?.workingDirectory ?? "/" }
    var runningSessionCount: Int { selectedServerViewModel?.runningSessionCount ?? 0 }
    var unreadSessionCount: Int { selectedServerViewModel?.unreadSessionCount ?? 0 }

    func sessionRowStatus(for sessionId: String) -> SessionRowStatus {
        selectedServerViewModel?.sessionRowStatus(for: sessionId) ?? .read
    }

    var currentSessionCwd: String {
        guard let serverId = selectedServerId else { return defaultWorkingDirectory }
        return currentSessionCwd(for: serverId, sessionId: serverSessionId)
    }

    func currentSessionCwd(for serverId: UUID, sessionId: String) -> String {
        let serverDefault = servers.first(where: { $0.id == serverId })?.workingDirectory ?? "~"
        guard !sessionId.isEmpty else { return serverDefault }
        if let summary = serverViewModels[serverId]?.sessionSummaries.first(where: { $0.id == sessionId }),
           let cwd = summary.cwd, !cwd.isEmpty {
            return cwd
        }
        return serverDefault
    }

    func usedWorkingDirectoryHistory(for serverId: UUID, currentSessionCwd overrideCwd: String? = nil) -> [String] {
        var directories = storage.fetchUsedWorkingDirectories(forServerId: serverId)
        let serverDefault = servers.first(where: { $0.id == serverId })?.workingDirectory
        let candidates = [overrideCwd, serverDefault].compactMap { $0 }
        for candidate in candidates {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if !directories.contains(trimmed) {
                directories.insert(trimmed, at: 0)
            }
        }
        return directories
    }

    var usedWorkingDirectoryHistory: [String] {
        guard let serverId = selectedServerId else { return [] }
        return usedWorkingDirectoryHistory(for: serverId, currentSessionCwd: currentSessionCwd)
    }

    func normalizedDefaultDirectoryForBrowsing(for serverId: UUID) -> String {
        let raw = servers.first(where: { $0.id == serverId })?.workingDirectory ?? "~"
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "~" : trimmed
    }

    func normalizedSessionDirectoryForBrowsing(for serverId: UUID, sessionId: String) -> String {
        let sessionDir = currentSessionCwd(for: serverId, sessionId: sessionId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !sessionDir.isEmpty {
            return sessionDir
        }
        return normalizedDefaultDirectoryForBrowsing(for: serverId)
    }

    // MARK: - Home Display Mode & Touch Bar

    var effectiveHomeDisplayMode: HomeDisplayMode {
        servers.count < 2 ? .singleServer : (persistedHomeDisplayMode ?? .allSessions)
    }

    func setHomeDisplayMode(_ mode: HomeDisplayMode) {
        persistedHomeDisplayMode = mode
        defaults.set(mode.rawValue, forKey: homeDisplayModeKey)
        objectWillChange.send()
    }

    func toggleHomeDisplayMode() {
        setHomeDisplayMode(effectiveHomeDisplayMode == .allSessions ? .singleServer : .allSessions)
    }

    var touchBarItems: [ServerTouchBarItem] {
        servers.map { server in
            let state = connectionState(for: server.id)
            return ServerTouchBarItem(
                id: server.id,
                name: server.name,
                isConnected: state == .connected,
                isConnecting: state == .connecting
            )
        }
    }

    var selectedServerIndex: Int {
        guard let selectedServerId,
              let idx = servers.firstIndex(where: { $0.id == selectedServerId }) else {
            return 0
        }
        return idx
    }

    var preferredNewSessionServerId: UUID? {
        if let lastId = lastNewSessionServerId,
           servers.contains(where: { $0.id == lastId }),
           connectionState(for: lastId) == .connected {
            return lastId
        }
        if let firstOnline = servers.first(where: { connectionState(for: $0.id) == .connected }) {
            return firstOnline.id
        }
        if let lastId = lastNewSessionServerId,
           servers.contains(where: { $0.id == lastId }) {
            return lastId
        }
        return selectedServerId ?? servers.first?.id
    }

    /// Servers currently halted due to WebSocket 4001 preemption in the active Home view mode.
    var preemptedServersInCurrentMode: [ACPServerConfiguration] {
        if effectiveHomeDisplayMode == .allSessions {
            return servers.filter {
                wasPreempted(for: $0.id)
                    && !isProtocolIncompatible(for: $0.id)
                    && connectionState(for: $0.id) != .connected
            }
        }
        guard let sid = selectedServerId,
              let server = servers.first(where: { $0.id == sid }),
              wasPreempted(for: sid),
              !isProtocolIncompatible(for: sid),
              connectionState(for: sid) != .connected else {
            return []
        }
        return [server]
    }

    /// Servers currently locked due to non-Nonlocal Bridge incompatibility in the active Home view mode (SD-1.2 / DEC-18).
    /// Always visible regardless of `devModeEnabled` and strictly isolated from orange 4001 banners.
    var protocolIncompatibleServersInCurrentMode: [ACPServerConfiguration] {
        if effectiveHomeDisplayMode == .allSessions {
            return servers.filter { isProtocolIncompatible(for: $0.id) }
        }
        guard let sid = selectedServerId,
              let server = servers.first(where: { $0.id == sid }),
              isProtocolIncompatible(for: sid) else {
            return []
        }
        return [server]
    }

    /// Whether `SessionListPage.onAppear` is allowed to auto-connect the selected server (Path 4 of SD-1.2).
    var shouldAutoConnectOnSessionListAppear: Bool {
        let manuallyDisconnected = selectedServerId.map { isManuallyDisconnected(serverId: $0) } ?? false
        let protocolLocked = selectedServerId.map { isProtocolIncompatible(for: $0) } ?? false
        return !isInitialAppLaunch
            && !manuallyDisconnected
            && !protocolLocked
            && !wasPreempted
            && connectionState == .disconnected
            && !isConnecting
    }

    // MARK: - Startup Migration & Legacy Cleanup (SC-AC-035 / SC-AC-036)

    static func migrateLegacyConnectionDefaultsIfNeeded(defaults: UserDefaults) {
        let currentClientId = defaults.string(forKey: connectionClientIdKey) ?? ""
        if currentClientId.isEmpty,
           let legacyId = defaults.string(forKey: legacyClientIdKey),
           !legacyId.isEmpty {
            defaults.set(legacyId, forKey: connectionClientIdKey)
        }

        if defaults.object(forKey: connectionLastConnectedAtKey) == nil,
           let legacyTimestamp = defaults.object(forKey: legacyLastConnectedAtKey) as? TimeInterval {
            defaults.set(legacyTimestamp, forKey: connectionLastConnectedAtKey)
        }
    }

    static func cleanupLegacyArtifactsIfNeeded(
        defaults: UserDefaults,
        applicationSupportURL: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        temporaryDirectoryURL: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        defaults.removeObject(forKey: legacyCodexLoggingKey)
        defaults.removeObject(forKey: legacyHighPerformanceRendererKey)
        defaults.removeObject(forKey: legacySummaryCardCollapsedKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(legacyCodexPermissionPresetPrefix) {
            defaults.removeObject(forKey: key)
        }

        if let appSupport = applicationSupportURL {
            let codexLogsDir = appSupport
                .appendingPathComponent("Agmente", isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
                .appendingPathComponent("codex", isDirectory: true)
            if fileManager.fileExists(atPath: codexLogsDir.path) {
                try? fileManager.removeItem(at: codexLogsDir)
            }
        }

        if let tmpItems = try? fileManager.contentsOfDirectory(
            at: temporaryDirectoryURL,
            includingPropertiesForKeys: nil,
            options: []
        ) {
            for item in tmpItems where item.lastPathComponent.hasPrefix("codex-logs-staging-") {
                try? fileManager.removeItem(at: item)
            }
        }
    }

    private func startupLog(_ message: String) {
        print("[APP][STARTUP] \(message)")
    }

    // MARK: - Initialization

    init(
        storage: SessionStorage = .shared,
        defaults: UserDefaults = .standard,
        connectionManagerFactory: ((UUID) -> ACPClientManager)? = nil,
        defaultSlotServiceFactory: ((ACPClientConfiguration, JSONEncoder) -> ACPService)? = nil,
        validatorServiceFactory: ((ACPClientConfiguration) -> ACPService)? = nil,
        projectStore: ProjectStore? = nil,
        shouldStartNetworkMonitoring: Bool = true,
        shouldConnectOnStartup: Bool = true,
        quotaClock: any QuotaUsageClock = SystemQuotaUsageClock()
    ) {
        self.storage = storage
        self.defaults = defaults
        self.projectStore = projectStore ?? ProjectStore(defaults: defaults)
        self.chatCache = ChatMessageCache()
        self.validator = BridgeServerValidator(defaults: defaults, serviceFactory: validatorServiceFactory)
        self.connectionPool = ServerConnectionPool(
            defaults: defaults,
            shouldStartNetworkMonitoring: shouldStartNetworkMonitoring,
            connectionManagerFactory: connectionManagerFactory,
            defaultSlotServiceFactory: defaultSlotServiceFactory
        )
        self.syncCoordinator = BridgeSyncCoordinator()
        self.quotaManager = QuotaManager(store: QuotaUsageStore(defaults: defaults), clock: quotaClock)

        Self.migrateLegacyConnectionDefaultsIfNeeded(defaults: defaults)
        Self.cleanupLegacyArtifactsIfNeeded(defaults: defaults)

        wireComponents()

        if let rawMode = defaults.string(forKey: homeDisplayModeKey),
           let parsedMode = HomeDisplayMode(rawValue: rawMode) {
            self.persistedHomeDisplayMode = parsedMode
        }

        servers = storage.fetchServers()
        quotaManager.hydrate(for: servers)
        restoreSelectionFromDefaults()
        devModeEnabled = defaults.bool(forKey: devModeKey)

        for server in servers {
            let serverVM = createServerViewModel(for: server)
            serverVM.loadCachedSessions()
            serverViewModels[server.id] = serverVM
            observeServerViewModel(serverVM)
        }

        startupLog(
            "init servers=\(servers.count) selectedServerId=\(selectedServerId?.uuidString ?? "nil") shouldConnectOnStartup=\(shouldConnectOnStartup)"
        )

#if DEBUG
        let hasDebugSeed = Self.hasWave2DebugSeedLaunchRequest()
#else
        let hasDebugSeed = false
#endif

        if shouldConnectOnStartup && !hasDebugSeed {
            startupLog("init invoking connectAllServers()")
            connectAllServers()
        }
#if DEBUG
        applyWave2DebugSeedIfRequested()
#endif
    }

    private func wireComponents() {
        connectionPool.setDelegateOwner(self)
        connectionPool.initializationPayloadProvider = { [weak self] in
            self?.makeInitializationPayload()
        }
        connectionPool.serversProvider = { [weak self] in
            self?.servers ?? []
        }
        connectionPool.selectedServerIdProvider = { [weak self] in
            self?.selectedServerId
        }

        quotaManager.selectedServerIdProvider = { [weak self] in self?.selectedServerId }
        quotaManager.serviceProvider = { [weak self] sid in self?.service(for: sid) }
        quotaManager.endpointSignatureProvider = { [weak self] sid in self?.endpointSignature(for: sid) ?? sid.uuidString }
        quotaManager.onChange = { [weak self] in self?.objectWillChange.send() }

        syncCoordinator.serviceProvider = { [weak self] sid in self?.service(for: sid) }
        syncCoordinator.serverViewModelProvider = { [weak self] sid in self?.serverViewModels[sid] }
        syncCoordinator.connectionManagerProvider = { [weak self] sid in self?.slotConnectionManagerIfExists(for: sid) }
        syncCoordinator.selectedServerIdProvider = { [weak self] in self?.selectedServerId }
        syncCoordinator.onAvailableModesDiscovered = { [weak self] sid, modes in
            guard let self, self.selectedServerId == sid else { return }
            if self.availableModes.isEmpty || self.serverViewModels[sid]?.selectedSessionId != nil {
                self.availableModes = modes
            }
        }
        syncCoordinator.onFailPendingTurn = { [weak self] msg, sid, sessionId in
            self?.failPendingTurn(msg, serverId: sid, sessionId: sessionId)
        }
        syncCoordinator.onApplyImmediateSessionDeletion = { [weak self] sessionId, sid in
            self?.applyImmediateSessionDeletion(sessionId: sessionId, serverId: sid)
        }
        syncCoordinator.onSyncSucceeded = { [weak self] sid, activeService in
            self?.releaseBusinessRPCsAfterSync(for: sid, service: activeService)
        }
        syncCoordinator.onProtocolIncompatible = { [weak self] sid, reason in
            self?.markServerProtocolIncompatible(serverId: sid, reason: reason)
        }
        syncCoordinator.onChange = { [weak self] in self?.objectWillChange.send() }
    }

    // MARK: - ServerViewModel Management

    func createServerViewModel(for config: ACPServerConfiguration) -> ServerViewModel {
        let slot = connectionSlot(for: config.id)
        let serverVM = ServerViewModel(
            id: config.id,
            name: config.name,
            scheme: config.scheme,
            host: config.host,
            token: config.token,
            workingDirectory: config.workingDirectory,
            connectionManager: slot.connectionManager,
            getService: { [weak self] in self?.service(for: config.id) },
            append: { [weak self] text in self?.append(text, serverId: config.id) },
            logWire: { [weak self] direction, message in self?.logWire(direction, message: message, serverId: config.id) },
            cacheDelegate: chatCache,
            storage: storage
        )
        serverVM.defaultModelPreferences = DefaultModelPreferences(defaults: defaults)
        serverVM.hasInitialSyncPendingClosure = { [weak self] in
            self?.hasInitialSyncPending(for: config.id) ?? false
        }
        serverVM.initialSyncBarrier = { [weak self] in
            await self?.awaitInitialSyncIfNeeded(for: config.id)
        }
        serverVM.recordSentClientTurnId = { [weak self] sid, clientTurnId in
            self?.syncCoordinator.recordSentClientTurnId(serverId: config.id, sessionId: sid, clientTurnId: clientTurnId)
        }
        serverVM.clearClientTurnId = { [weak self] sid, clientTurnId in
            self?.syncCoordinator.clearClientTurnId(serverId: config.id, sessionId: sid, clientTurnId: clientTurnId)
        }
        serverVM.markClientTurnCompleted = { [weak self] sid, clientTurnId in
            self?.syncCoordinator.markClientTurnCompleted(serverId: config.id, sessionId: sid, clientTurnId: clientTurnId)
        }
        serverVM.onActiveSessionPruned = { [weak self] prunedSessionId in
            guard let self else { return }
            if self.sessionCache[config.id] == prunedSessionId {
                self.sessionCache.removeValue(forKey: config.id)
            }
        }
        if config.id == activeViewingServerId {
            serverVM.activeViewingSessionId = activeViewingSessionId
        }
        return serverVM
    }

    private func updateServerViewModel(for config: ACPServerConfiguration) {
        if let existing = serverViewModels[config.id] {
            existing.name = config.name
            existing.scheme = config.scheme
            existing.host = config.host
            existing.token = config.token
            existing.workingDirectory = config.workingDirectory
        } else {
            let newVM = createServerViewModel(for: config)
            serverViewModels[config.id] = newVM
            observeServerViewModel(newVM)
        }
    }

    private func removeServerViewModel(for serverId: UUID) {
        serverViewModels[serverId]?.removeAllSessionViewModels()
        serverViewModels.removeValue(forKey: serverId)
        serverViewModelCancellables.removeValue(forKey: serverId)
    }

    func observeServerViewModel(_ serverVM: ServerViewModel) {
        let serverId = serverVM.id
        serverViewModelCancellables[serverId] = serverVM.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
    }

    // MARK: - Active Viewing & Server Selection

    func setActiveViewingSession(serverId: UUID?, sessionId: String?) {
        let normalizedSession = (sessionId?.isEmpty == false) ? sessionId : nil
        let changed = (activeViewingServerId != serverId || activeViewingSessionId != normalizedSession)
        activeViewingServerId = serverId
        activeViewingSessionId = normalizedSession

        for (id, vm) in serverViewModels {
            let targetSession: String? = (id == serverId) ? normalizedSession : nil
            if vm.activeViewingSessionId != targetSession {
                vm.activeViewingSessionId = targetSession
            }
        }
        if changed {
            objectWillChange.send()
        }
    }

    func selectServer(_ id: UUID) {
        selectedServerId = id
        defaults.set(id.uuidString, forKey: lastServerKey)
        applyCachedState(for: id)
        refreshImageAttachmentSupport(for: id)
        quotaManager.handleServerSelected(id, service: service(for: id))
        objectWillChange.send()
    }

    private func applyCachedState(for serverId: UUID) {
        if let serverVM = serverViewModels[serverId], serverVM.sessionSummaries.isEmpty {
            serverVM.loadCachedSessions()
        }
        initializationSummary = initializationCache[serverId] ?? "Not initialized"
    }

    private func restoreSelectionFromDefaults() {
        guard let firstServer = servers.first else { return }
        if let savedId = defaults.string(forKey: lastServerKey),
           let uuid = UUID(uuidString: savedId),
           servers.contains(where: { $0.id == uuid }) {
            selectServer(uuid)
        } else {
            selectServer(firstServer.id)
        }
    }

    private func refreshImageAttachmentSupport(for serverId: UUID? = nil) {
        let resolvedId = serverId ?? selectedServerId
        let supportsImages = resolvedId.flatMap { agentInfoCache[$0]?.capabilities.promptCapabilities.image } ?? false
        if let resolvedId {
            serverViewModels[resolvedId]?.currentSessionViewModel?.setSupportsImageAttachment(supportsImages)
        }
    }

    // MARK: - Server Admission, CRUD & Configuration

    func validateServerConfiguration(
        name: String,
        scheme: String,
        host: String,
        token: String,
        workingDirectory: String
    ) async -> Result<ValidatedServerConfiguration, Error> {
        await validator.validate(
            name: name,
            scheme: scheme,
            host: host,
            token: token,
            workingDirectory: workingDirectory,
            clientName: clientName,
            clientVersion: clientVersion,
            supportsFSRead: supportsFSRead,
            supportsFSWrite: supportsFSWrite,
            supportsTerminal: supportsTerminal
        )
    }

    func addValidatedServer(_ config: ValidatedServerConfiguration) {
        let newId = addServer(
            name: config.name,
            scheme: config.scheme,
            host: config.host,
            token: config.token,
            workingDirectory: config.workingDirectory,
            agentInfo: config.agentInfo
        )
        connectServer(newId)
    }

    @discardableResult
    func addServer(
        id explicitId: UUID? = nil,
        name: String,
        scheme: String,
        host: String,
        token: String,
        workingDirectory: String,
        agentInfo: AgentProfile? = nil
    ) -> UUID {
        let normalized = BridgeServerValidator.normalizeEndpoint(scheme: scheme, host: host)
        let label = name.isEmpty ? "\(normalized.scheme)://\(normalized.host)" : name
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let server = ACPServerConfiguration(
            id: explicitId ?? UUID(),
            name: label,
            scheme: normalized.scheme,
            host: normalized.host,
            token: trimmedToken,
            workingDirectory: sanitizeWorkingDirectory(workingDirectory)
        )
        servers.append(server)
        storage.saveServer(server)

        let serverVM = createServerViewModel(for: server)
        serverViewModels[server.id] = serverVM
        observeServerViewModel(serverVM)

        if let agentInfo {
            agentInfoCache[server.id] = agentInfo
            serverVM.updateAgentInfo(agentInfo)
            initializedServers.insert(server.id)
        }

        selectServer(server.id)
        return server.id
    }

    /// Updates server config. Per DEC-30 (SC-AC-024 / SC-AC-028):
    /// - If only `name` or `workingDirectory` changed, skips remote validation and preserves both
    ///   existing live connection AND any existing protocol-incompatibility lockout state & red banner.
    /// - If normalized `scheme`, `host`, or `trimmedToken` changed, clears lockout & quota state and reconnects.
    func updateServer(_ id: UUID, with config: ValidatedServerConfiguration) {
        guard let index = servers.firstIndex(where: { $0.id == id }) else { return }

        let normalized = BridgeServerValidator.normalizeEndpoint(scheme: config.scheme, host: config.host)
        let trimmedToken = config.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated = ACPServerConfiguration(
            id: id,
            name: config.name,
            scheme: normalized.scheme,
            host: normalized.host,
            token: trimmedToken,
            workingDirectory: sanitizeWorkingDirectory(config.workingDirectory)
        )

        let existingNormalized = BridgeServerValidator.normalizeEndpoint(
            scheme: servers[index].scheme,
            host: servers[index].host
        )
        let connectionChanged = existingNormalized.scheme != updated.scheme
            || existingNormalized.host != updated.host
            || servers[index].token.trimmingCharacters(in: .whitespacesAndNewlines) != trimmedToken

        servers[index] = updated
        storage.saveServer(updated)
        updateServerViewModel(for: updated)

        if let agentInfo = config.agentInfo {
            agentInfoCache[id] = agentInfo
            serverViewModels[id]?.updateAgentInfo(agentInfo)
        }

        if connectionChanged {
            connectionPool.clearProtocolIncompatibility(for: id)
            clearQuotaUsageState(for: id)
            unbindServices(for: id)
            projectStore.clearHomePath(forServerId: id)
            connectionPool.slotIfExists(for: id)?.hasProbedHomePath = false

            let wasManuallyDisconnected = isManuallyDisconnected(serverId: id)
            convergeStreamingSessions(for: id)
            initializedServers.remove(id)
            resetSyncCoordinationState(for: id)
            slotConnectionManagerIfExists(for: id)?.disconnect()
            if !wasManuallyDisconnected {
                connectServer(id, userInitiated: true)
            }
        }
        objectWillChange.send()
    }

    func deleteServer(_ id: UUID) {
        convergeStreamingSessions(for: id)
        storage.deleteServer(id: id)
        servers.removeAll { $0.id == id }
        if defaults.string(forKey: lastServerKey) == id.uuidString {
            defaults.removeObject(forKey: lastServerKey)
        }

        sessionCache.removeValue(forKey: id)
        chatCache.clearCache(for: id)
        initializationCache.removeValue(forKey: id)
        initializedServers.remove(id)
        agentInfoCache.removeValue(forKey: id)
        syncCoordinator.removeAllState(for: id)
        clearQuotaUsageState(for: id)
        unbindServices(for: id)
        projectStore.deleteProjects(forServerId: id)
        releaseConnectionSlot(for: id)
        serverViewModels[id]?.currentSessionViewModel?.removeServerCommandsCache(for: id)
        removeServerViewModel(for: id)

        if selectedServerId == id {
            if let newId = servers.first?.id {
                selectServer(newId)
            } else {
                selectedServerId = nil
                quotaManager.handleServerSelected(nil, service: nil)
                resetSyncCoordinationState(for: nil)
                refreshImageAttachmentSupport(for: nil)
            }
        }
        objectWillChange.send()
    }

    func sanitizeWorkingDirectory(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "~" : trimmed
    }

    // MARK: - Connection Pool Delegation

    func connectionSlot(for serverId: UUID) -> ServerConnectionSlot {
        connectionPool.slot(for: serverId)
    }

    func slotConnectionManager(for serverId: UUID) -> ACPClientManager {
        connectionPool.manager(for: serverId)
    }

    func slotConnectionManagerIfExists(for serverId: UUID) -> ACPClientManager? {
        connectionPool.managerIfExists(for: serverId)
    }

    func service(for serverId: UUID) -> ACPService? {
        connectionPool.service(for: serverId)
    }

    func connectionState(for serverId: UUID) -> ACPConnectionState {
        connectionPool.connectionState(for: serverId)
    }

    func wasPreempted(for serverId: UUID) -> Bool {
        connectionPool.wasPreempted(for: serverId)
    }

    func isProtocolIncompatible(for serverId: UUID) -> Bool {
        connectionPool.isProtocolIncompatible(for: serverId)
    }

    func protocolIncompatibleMessage(for serverId: UUID) -> String? {
        connectionPool.protocolIncompatibleMessage(for: serverId)
    }

    func lastConnectedAt(for serverId: UUID) -> Date? {
        connectionPool.lastConnectedAt(for: serverId)
    }

    func isManuallyDisconnected(serverId: UUID) -> Bool {
        connectionPool.isManuallyDisconnected(serverId: serverId)
    }

    func releaseConnectionSlot(for serverId: UUID) {
        syncCoordinator.reset(for: serverId)
        connectionPool.releaseSlot(for: serverId)
    }

    func connectAllServers() {
        connectionPool.connectAllServers(servers: servers)
    }

    func connectServer(_ serverId: UUID, userInitiated: Bool = true) {
        guard let config = servers.first(where: { $0.id == serverId }) else { return }
        if userInitiated {
            resetSyncCoordinationState(for: serverId)
        }
        connectionPool.connectServer(config, userInitiated: userInitiated)
        objectWillChange.send()
    }

    func connect(completion: ((Bool) -> Void)? = nil) {
        if selectedServerId == nil, let firstId = servers.first?.id {
            selectServer(firstId)
        }
        guard let targetServerId = selectedServerId,
              let config = servers.first(where: { $0.id == targetServerId }) else {
            completion?(false)
            return
        }
        resetSyncCoordinationState(for: targetServerId)
        connectionPool.connectServer(config, userInitiated: true, pingInterval: 15, completion: completion)
        objectWillChange.send()
    }

    func connectAndWait() async -> Bool {
        if selectedServerId == nil, let firstId = servers.first?.id {
            selectServer(firstId)
        }
        guard let targetServerId = selectedServerId,
              let config = servers.first(where: { $0.id == targetServerId }) else {
            return false
        }
        resetSyncCoordinationState(for: targetServerId)
        let ok = await connectionPool.connectServerAndWait(config, userInitiated: true, pingInterval: 15)
        objectWillChange.send()
        return ok
    }

    func disconnect(serverId: UUID) {
        if serverId == selectedServerId {
            quotaManager.cancelRefreshTimer()
            resumeRefreshTask?.cancel()
            resumeRefreshTask = nil
        }
        resetSyncCoordinationState(for: serverId)
        convergeStreamingSessions(for: serverId)
        connectionPool.disconnect(serverId: serverId, manual: true)
        objectWillChange.send()
    }

    func disconnect() {
        resumeRefreshTask?.cancel()
        resumeRefreshTask = nil
        guard let serverId = selectedServerId else { return }
        disconnect(serverId: serverId)
    }

    func initializeAndWait() async -> Bool {
        guard let serverId = selectedServerId else { return false }
        initializedServers.insert(serverId)
        let manager = slotConnectionManager(for: serverId)
        manager.shouldAutoInitialize = true
        return await manager.initializeAndWait(payload: makeInitializationPayload())
    }

    func sendInitialize() {
        Task { @MainActor in
            _ = await initializeAndWait()
        }
    }

    func handleScenePhaseChanged(_ phase: ScenePhase) {
        connectionPool.handleScenePhaseChanged(phase, servers: servers)
        quotaManager.handleScenePhaseChanged(phase)
        objectWillChange.send()
    }

    func resumeConnectionIfNeeded() {
        guard isNetworkAvailable else { return }
        let now = Date()
        if let last = lastResumeRefreshAt, now.timeIntervalSince(last) < 1 {
            return
        }
        lastResumeRefreshAt = now

        resumeRefreshTask?.cancel()
        resumeRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.resumeRefreshTask = nil }
            await self.refreshSessionsAfterResume()
        }
    }

    private func refreshSessionsAfterResume() async {
        guard isNetworkAvailable else {
            loadCachedSessions()
            return
        }
        guard let serverId = selectedServerId else { return }
        guard !isManuallyDisconnected(serverId: serverId),
              !isProtocolIncompatible(for: serverId),
              !wasPreempted(for: serverId) else {
            return
        }

        if connectionState(for: serverId) == .connected {
            await slotConnectionManager(for: serverId).verifyConnectionHealth()
        }

        if connectionState(for: serverId) != .connected {
            guard !slotConnectionManager(for: serverId).isConnecting else { return }
            guard let config = servers.first(where: { $0.id == serverId }) else { return }
            let connected = await connectionPool.connectServerAndWait(config, userInitiated: false, pingInterval: 15)
            guard connected else {
                loadCachedSessions()
                return
            }
        }

        if !slotConnectionManager(for: serverId).isInitialized {
            _ = await initializeAndWait()
        }

        guard !isProtocolIncompatible(for: serverId) else { return }
        if let syncTask = beginInitialSyncIfNeeded(for: serverId) {
            await syncTask.value
        } else if serverViewModels[serverId]?.hasCompletedNonlocalSync == true {
            if let activeService = service(for: serverId) {
                bindService(activeService, to: serverId)
                triggerQuotaProbeOrRefreshIfNeeded(for: serverId, service: activeService)
            }
            serverViewModels[serverId]?.fetchSessionList(force: true)
        }
    }

    /// Explicit user pull-to-refresh (unlocks protocol lockout for a single explicit attempt per SD-1.2 / SC-AC-028).
    func refreshServersForCurrentMode() async {
        if effectiveHomeDisplayMode == .allSessions {
            for server in servers {
                let slot = connectionSlot(for: server.id)
                let state = connectionState(for: server.id)
                switch state {
                case .connected:
                    serverViewModels[server.id]?.fetchSessionList(force: true)
                case .disconnected, .failed:
                    guard !slot.connectionManager.isConnecting else { break }
                    connectServer(server.id, userInitiated: true)
                case .connecting:
                    break
                }
            }
        } else {
            await refreshSessions()
        }
    }

    func refreshSessions() async {
        guard let serverId = selectedServerId else { return }
        if connectionState(for: serverId) != .connected {
            guard !slotConnectionManager(for: serverId).isConnecting else { return }
            let connected = await connectAndWait()
            guard connected else {
                loadCachedSessions()
                return
            }
            if !slotConnectionManager(for: serverId).isInitialized {
                _ = await initializeAndWait()
            }
        }
        guard !isProtocolIncompatible(for: serverId) else { return }
        if hasInitialSyncPending(for: serverId) {
            await awaitInitialSyncIfNeeded(for: serverId)
        }
        guard !isProtocolIncompatible(for: serverId) else { return }
        serverViewModels[serverId]?.fetchSessionList(force: true)
    }

    func makeInitializationPayload() -> ACPInitializationPayload {
        let clientCapabilities: [String: ACP.Value] = [
            "fs": .object([
                "readTextFile": .bool(supportsFSRead),
                "writeTextFile": .bool(supportsFSWrite)
            ]),
            "terminal": .bool(supportsTerminal),
        ]
        return ACPInitializationPayload(
            protocolVersion: 1,
            clientName: clientName,
            clientVersion: clientVersion,
            clientCapabilities: clientCapabilities
        )
    }

    private func markServerProtocolIncompatible(serverId: UUID, reason: String) {
        let serverName = servers.first(where: { $0.id == serverId })?.name ?? serverId.uuidString
        let displayMessage = BridgeServerValidator.incompatibleBridgeMessage(for: serverName)
        append("Incompatible bridge [\(serverName)]: \(reason)", serverId: serverId)
        convergeStreamingSessions(for: serverId)
        syncCoordinator.reset(for: serverId)
        connectionPool.markProtocolIncompatible(serverId: serverId, message: displayMessage)
        objectWillChange.send()
    }

    private func releaseBusinessRPCsAfterSync(for serverId: UUID, service activeService: ACPService) {
        guard !isProtocolIncompatible(for: serverId),
              self.service(for: serverId) === activeService else {
            return
        }
        bindService(activeService, to: serverId)
        probeHomePathIfNeeded(for: serverId, service: activeService)
        quotaManager.triggerRefreshIfNeeded(for: serverId, service: activeService)
        serverViewModels[serverId]?.fetchSessionList(force: false)

        if selectedServerId == serverId {
            if isInitialAppLaunch {
                isInitialAppLaunch = false
            }
            if !hasHandledColdLaunchAutoSession {
                hasHandledColdLaunchAutoSession = true
                ensureSessionForActiveServer()
            }
            loadPendingSessionIfPossible(for: serverId)
        }
    }

    // MARK: - Explicit Server-Scoped Operations (TD-2 Closure / SD-2.8)

    func loadCachedSessions() {
        selectedServerViewModel?.loadCachedSessions()
    }

    func openSession(_ id: String) {
        guard let serverId = selectedServerId else { return }
        openSession(serverId: serverId, sessionId: id)
    }

    func openSession(serverId: UUID, sessionId: String) {
        setActiveViewingSession(serverId: serverId, sessionId: sessionId)
        serverViewModels[serverId]?.openSession(sessionId)
    }

    func sendNewSession(workingDirectory: String? = nil) {
        guard let serverId = selectedServerId else { return }
        _ = sendNewSession(serverId: serverId, workingDirectory: workingDirectory)
    }

    @discardableResult
    func sendNewSession(serverId: UUID, workingDirectory: String? = nil) -> String? {
        lastNewSessionServerId = serverId
        guard let serverVM = serverViewModels[serverId] else { return nil }
        serverVM.sendNewSession(workingDirectory: workingDirectory)
        return serverVM.selectedSessionId ?? (serverVM.sessionId.isEmpty ? nil : serverVM.sessionId)
    }

    func updatePendingSessionWorkingDirectory(_ newValue: String) {
        guard let serverId = selectedServerId else { return }
        updatePendingSessionWorkingDirectory(serverId: serverId, newValue)
    }

    func updatePendingSessionWorkingDirectory(serverId: UUID, _ newValue: String) {
        serverViewModels[serverId]?.updatePendingSessionWorkingDirectory(newValue)
    }

    func sendLoadSession(_ sessionIdToLoad: String, cwd: String? = nil) {
        guard let serverId = selectedServerId else {
            append("No server selected")
            return
        }
        serverViewModels[serverId]?.sendLoadSession(sessionIdToLoad, cwd: cwd)
    }

    func fetchSessionList(force: Bool = false) {
        selectedServerViewModel?.fetchSessionList(force: force)
    }

    func deleteSession(_ sessionId: String) {
        guard let serverId = selectedServerId else { return }
        deleteSession(serverId: serverId, sessionId: sessionId)
    }

    func deleteSession(serverId: UUID, sessionId: String) {
        serverViewModels[serverId]?.deleteSession(sessionId)
    }

    func canRenameSession(_ sessionId: String, serverId: UUID? = nil) -> Bool {
        guard let targetServerId = serverId ?? selectedServerId,
              let serverVM = serverViewModels[targetServerId],
              !sessionId.isEmpty else {
            return false
        }
        return !serverVM.isPendingSessionId(sessionId)
    }

    func canViewSessionInfo(_ sessionId: String, serverId: UUID? = nil) -> Bool {
        guard let targetServerId = serverId ?? selectedServerId,
              let serverVM = serverViewModels[targetServerId],
              !sessionId.isEmpty else {
            return false
        }
        return !serverVM.isPendingSessionId(sessionId)
    }

    @discardableResult
    func renameSession(
        serverId targetServerId: UUID? = nil,
        sessionId: String,
        title: String
    ) async throws -> String? {
        guard let serverId = targetServerId ?? selectedServerId,
              let serverVM = serverViewModels[serverId] else {
            throw SessionRenameError.unsupportedRemoteRename
        }
        return try await serverVM.renameSession(sessionId: sessionId, title: title)
    }

    func fetchSessionInfo(serverId: UUID, sessionId: String) async throws -> NonlocalSessionInfoResult? {
        guard let svc = service(for: serverId) else { return nil }
        return try await svc.fetchSessionInfo(sessionId: sessionId)
    }

    func listRemoteDirectory(serverId: UUID, path: String? = nil, includeFiles: Bool = false) async throws -> NonlocalFsListResult? {
        guard let svc = service(for: serverId) else { throw ACPServiceError.disconnected }
        let res = try await svc.listDirectory(NonlocalFsListParams(path: path, includeFiles: includeFiles))
        if let home = res?.homePath, !home.isEmpty {
            projectStore.updateHomePath(home, forServerId: serverId)
        }
        return res
    }

    func listRemoteDirectory(serverId: UUID, params: NonlocalFsListParams) async throws -> NonlocalFsListResult? {
        guard let svc = service(for: serverId) else { throw ACPServiceError.disconnected }
        let res = try await svc.listDirectory(params)
        if let home = res?.homePath, !home.isEmpty {
            projectStore.updateHomePath(home, forServerId: serverId)
        }
        return res
    }

    func readRemoteFile(serverId: UUID, path: String) async throws -> NonlocalFsReadFileResult? {
        guard let svc = service(for: serverId) else { throw ACPServiceError.disconnected }
        return try await svc.readFile(path: path)
    }

    func probeHomePathIfNeeded(for serverId: UUID, service: ACPService) {
        let slot = connectionSlot(for: serverId)
        guard !slot.hasProbedHomePath else { return }
        slot.hasProbedHomePath = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if let res = try await service.listDirectory(NonlocalFsListParams(path: "~", includeFiles: false)),
                   !res.homePath.isEmpty {
                    self.projectStore.updateHomePath(res.homePath, forServerId: serverId)
                }
            } catch {
                // Non-fatal probe failure
            }
        }
    }

    func fetchSessionInfoForDeleteConfirmation(
        serverId: UUID,
        sessionId: String,
        timeoutSeconds: TimeInterval = 1.5
    ) async -> Int? {
        guard let svc = service(for: serverId) else { return nil }
        return await withTaskGroup(of: Int?.self) { group in
            group.addTask {
                do {
                    let info = try await svc.fetchSessionInfo(sessionId: sessionId)
                    return info?.subagents.count
                } catch {
                    return nil
                }
            }
            group.addTask {
                let ns = UInt64(max(0.05, timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: ns)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    func deleteRemoteSession(
        sessionId sid: String,
        serverId: UUID
    ) async -> Result<NonlocalDeleteSessionResult, RemoteSessionDeleteError> {
        guard let serverVM = serverViewModels[serverId] else {
            return .failure(.unsupportedRemoteDelete)
        }
        if serverVM.isPendingSessionId(sid) {
            applyImmediateSessionDeletion(sessionId: sid, serverId: serverId)
            return .success(
                NonlocalDeleteSessionResult(
                    sessionId: sid,
                    deleted: true,
                    alreadyAbsent: true,
                    deletedSubagentIds: [],
                    deletedSubagentCount: 0,
                    warnings: []
                )
            )
        }
        if serverVM.isSessionRunning(sid) || serverVM.isSessionWaitingForUser(sid) {
            return .failure(.activeSession)
        }
        guard serverVM.hasCompletedNonlocalSync else {
            return .failure(.unsupportedRemoteDelete)
        }
        guard let svc = service(for: serverId), connectionState(for: serverId) == .connected else {
            return .failure(.notConnected)
        }
        do {
            let result = try await svc.deleteSession(sessionId: sid) ?? NonlocalDeleteSessionResult(
                sessionId: sid,
                deleted: true,
                alreadyAbsent: false
            )
            applyImmediateSessionDeletion(sessionId: sid, serverId: serverId)
            return .success(result)
        } catch {
            return .failure(RemoteSessionDeleteError.from(error))
        }
    }

    func sendCancel(serverId explicitServerId: UUID? = nil, sessionId explicitSessionId: String? = nil) {
        let resolvedServerId = explicitServerId ?? selectedServerId
        guard let resolvedServerId,
              let targetService = service(for: resolvedServerId) else {
            return
        }
        let targetSessionId: String = {
            if let explicitSessionId, !explicitSessionId.isEmpty {
                return explicitSessionId
            }
            return serverViewModels[resolvedServerId]?.sessionId ?? ""
        }()
        guard !targetSessionId.isEmpty else {
            append("No session to cancel", serverId: resolvedServerId)
            return
        }
        let targetVM = serverViewModels[resolvedServerId]?.sessionViewModel(for: targetSessionId)
        syncCoordinator.pendingClientTurnIds[resolvedServerId]?.removeValue(forKey: targetSessionId)
        syncCoordinator.clearAppliedTurnProgress(serverId: resolvedServerId, sessionId: targetSessionId)
        serverViewModels[resolvedServerId]?.noteUserCancelled(sessionId: targetSessionId)
        targetVM?.cancelPendingPermissionRequests(for: targetSessionId)

        let payload = ACPSessionCancelPayload(sessionId: targetSessionId)
        Task { @MainActor [weak self] in
            do {
                _ = try await targetService.cancelSession(payload)
            } catch {
                self?.append("Failed to cancel session: \(error)", serverId: resolvedServerId)
            }
        }
        targetVM?.abandonStreamingMessage()
    }

    func sendSetMode(_ modeId: String, serverId explicitServerId: UUID? = nil, sessionId explicitSessionId: String? = nil) {
        guard let targetServerId = explicitServerId ?? selectedServerId,
              let serverVM = serverViewModels[targetServerId] else {
            return
        }
        let targetSessionId = (explicitSessionId?.isEmpty == false) ? explicitSessionId! : serverVM.sessionId
        let targetVM = serverVM.sessionViewModel(for: targetSessionId)
        targetVM.sendSetMode(modeId, sessionId: targetSessionId, serverId: targetServerId)
    }

    func sendPermissionResponse(requestId: ACP.ID, optionId: String, serverId explicitServerId: UUID? = nil) {
        guard let targetServerId = explicitServerId ?? selectedServerId else { return }
        serverViewModels[targetServerId]?.sendPermissionResponse(requestId: requestId, optionId: optionId)
    }

    func migrateSessionCaches(for serverId: UUID, from placeholderId: String, to resolvedId: String) {
        guard placeholderId != resolvedId else { return }
        chatCache.migrateCache(serverId: serverId, from: placeholderId, to: resolvedId)
        serverViewModels[serverId]?.migrateSessionViewModel(from: placeholderId, to: resolvedId)
        if let viewModel = serverViewModels[serverId]?.existingSessionViewModel(for: resolvedId)
            ?? serverViewModels[serverId]?.currentSessionViewModel {
            viewModel.migrateSessionCommandsCache(for: serverId, from: placeholderId, to: resolvedId)
            viewModel.migrateSessionModeCache(for: serverId, from: placeholderId, to: resolvedId)
        }
    }

    func convergeStreamingSessions(for serverId: UUID) {
        syncCoordinator.clearTurnStateOnDisconnect(for: serverId)
        guard let serverVM = serverViewModels[serverId] else { return }
        for (sid, vm) in serverVM.allSessionViewModels() where vm.isActivelyRunning || vm.isStreaming || vm.pendingPromptDelivery != nil {
            vm.abandonStreamingMessage()
            if vm.pendingPromptDelivery != nil {
                let errId = vm.addSystemErrorMessage("Message was not delivered before disconnect. Please try again.")
                vm.markPendingPromptDeliveryFailed(errorMessageId: errId)
            }
            serverVM.persistChatToStorage(sessionId: sid, allowEmpty: false)
        }
    }

    func ensureSessionForActiveServer() {
        guard let serverId = selectedServerId,
              let serverVM = serverViewModels[serverId] else { return }
        let sessionToResume = serverVM.pendingSessionLoad ?? sessionCache[serverId]
        guard let sessionToResume, !sessionToResume.isEmpty else {
            serverVM.pendingSessionLoad = nil
            return
        }
        serverVM.setActiveSession(sessionToResume)
        guard connectionState(for: serverId) == .connected else { return }
        if !slotConnectionManager(for: serverId).isSessionMaterialized(sessionToResume),
           (serverVM.lastLoadedSession != sessionToResume || serverVM.existingSessionViewModel(for: sessionToResume)?.chatMessages.isEmpty ?? true) {
            serverVM.sendLoadSession(sessionToResume)
        }
        serverVM.pendingSessionLoad = nil
    }

    private func loadPendingSessionIfPossible(for serverId: UUID) {
        guard selectedServerId == serverId,
              connectionState(for: serverId) == .connected,
              let serverVM = serverViewModels[serverId],
              let targetSession = serverVM.pendingSessionLoad,
              !targetSession.isEmpty,
              !serverVM.isPendingSessionId(targetSession) else {
            return
        }
        if !slotConnectionManager(for: serverId).isSessionMaterialized(targetSession),
           (serverVM.lastLoadedSession != targetSession || serverVM.existingSessionViewModel(for: targetSession)?.chatMessages.isEmpty ?? true) {
            serverVM.sendLoadSession(targetSession)
        }
        serverVM.pendingSessionLoad = nil
    }

    private func failPendingTurn(_ message: String, serverId: UUID, sessionId targetSessionId: String? = nil) {
        let fallbackSessionId = serverViewModels[serverId]?.selectedSessionId ?? ""
        let effectiveSessionId = (targetSessionId?.isEmpty == false) ? targetSessionId! : fallbackSessionId
        if !effectiveSessionId.isEmpty {
            syncCoordinator.clearAppliedTurnProgress(serverId: serverId, sessionId: effectiveSessionId)
        }
        serverViewModels[serverId]?.failPendingTurn(message, forSessionId: targetSessionId)
    }

    // MARK: - ServerConnectionSlotDelegateOwner

    func slotManager(_ manager: ACPClientManager, serverId: UUID, willSendRequest request: ACP.AnyRequest) {
        guard connectionPool.slotIfExists(for: serverId)?.connectionManager === manager else { return }
        let slot = connectionSlot(for: serverId)
        slot.pendingRequests[request.id] = request.method
        if let reqSessionId = request.params.objectValue?["sessionId"]?.stringValue, !reqSessionId.isEmpty {
            slot.pendingRequestSessionIds[request.id] = reqSessionId
        } else if request.method == "session/new" || request.method == "session/create",
                  let placeholderId = slot.pendingNewSessionPlaceholderId
                    ?? serverViewModels[serverId]?.pendingNewSessionContext().placeholderId {
            slot.pendingRequestSessionIds[request.id] = placeholderId
        }
        logWire("→", message: .request(request), serverId: serverId)
    }

    func slotManager(_ manager: ACPClientManager, serverId: UUID, didReceiveMessage message: ACPWireMessage) {
        guard connectionPool.slotIfExists(for: serverId)?.connectionManager === manager else { return }
        var completedMethod: String?
        var completedTargetSessionId: String?
        if case .response(let response) = message,
           let slot = connectionPool.slotIfExists(for: serverId) {
            completedMethod = slot.pendingRequests.removeValue(forKey: response.id)
            completedTargetSessionId = slot.pendingRequestSessionIds.removeValue(forKey: response.id)
        }
        handleIncoming(
            message,
            serverId: serverId,
            completedMethod: completedMethod,
            completedTargetSessionId: completedTargetSessionId
        )
    }

    func slotManager(_ manager: ACPClientManager, serverId: UUID, didReceiveNotification notification: ACP.AnyMessage) {
        // Notifications arrive through didReceiveMessage.
    }

    func slotManager(_ manager: ACPClientManager, serverId: UUID, didChangeState state: ACPConnectionState) {
        guard let slot = connectionPool.slotIfExists(for: serverId),
              slot.connectionManager === manager else {
            return
        }
        append("State: \(stateLabel(state))", serverId: serverId)
        switch state {
        case .connected:
            slot.lastConnectedAt = Date()
        case .failed, .disconnected:
            slot.pendingRequests.removeAll()
            slot.pendingRequestSessionIds.removeAll()
            slot.pendingNewSessionPlaceholderId = nil
            syncCoordinator.reset(for: serverId)
            resetConnectionUsageState(for: serverId)
        case .connecting:
            break
        }
        objectWillChange.send()
    }

    func slotManager(_ manager: ACPClientManager, serverId: UUID, didChangeNetworkAvailability available: Bool) {
        guard connectionPool.slotIfExists(for: serverId)?.connectionManager === manager else { return }
        append("Network: \(available ? "available" : "unavailable")", serverId: serverId)
        if available {
            connectionPool.resumeAllEligibleOnNetworkRecovery(servers: servers)
        }
        objectWillChange.send()
    }

    func slotManager(_ manager: ACPClientManager, serverId: UUID, didEncounterError error: Error) {
        guard connectionPool.slotIfExists(for: serverId)?.connectionManager === manager else { return }
        append("Error: \(error)", serverId: serverId)
        objectWillChange.send()
    }

    func slotManager(_ manager: ACPClientManager, serverId: UUID, didLog message: String) {
        guard connectionPool.slotIfExists(for: serverId)?.connectionManager === manager else { return }
        append(message, serverId: serverId)
    }

    func slotManager(_ manager: ACPClientManager, serverId: UUID, didCreateService service: ACPService) {
        guard connectionPool.slotIfExists(for: serverId)?.connectionManager === manager else { return }
        // SD-1.2 / SD-2.1: ZERO business RPCs in didCreateService; wait for nonlocal/sync identity verification.
        bindService(service, to: serverId)
        resetConnectionUsageState(for: serverId)
    }

    // MARK: - Incoming ACP Wire Dispatch

    func handleIncoming(
        _ message: ACPWireMessage,
        serverId explicitServerId: UUID? = nil,
        completedMethod: String? = nil,
        completedTargetSessionId: String? = nil
    ) {
        let resolvedServerId = explicitServerId ?? selectedServerId
        logWire("←", message: message, serverId: resolvedServerId, methodOverride: completedMethod)
        let isSelected = (resolvedServerId != nil && resolvedServerId == selectedServerId)

        switch message {
        case .response(let response):
            let method = completedMethod
            let requestTargetSessionId = completedTargetSessionId
            if shouldAppendStructuredResponseLog(response, method: method), let resolvedServerId {
                append(renderResponse(response, method: method), serverId: resolvedServerId)
            }

            if let error = response.errorValue {
                let errorActions = ACPResponseDispatcher.dispatchError(
                    code: error.code,
                    message: error.message,
                    method: method
                )
                for action in errorActions {
                    applyResponseAction(
                        action,
                        serverId: resolvedServerId,
                        method: method,
                        targetSessionId: requestTargetSessionId
                    )
                }

                // Pre-sync initialize phase error classification (SD-1.2 / SC-AC-071)
                if (method == "initialize" || method == "acp/initialize"),
                   let serverId = resolvedServerId {
                    if BridgeServerValidator.isAlreadyInitializedRPCError(error) {
                        initializedServers.insert(serverId)
                        _ = beginInitialSyncIfNeeded(for: serverId)
                    } else if BridgeServerValidator.isProtocolIncompatibilityRPCError(error, allowAlreadyInitialized: true) {
                        // Do NOT start nonlocal/sync; lock immediately!
                        markServerProtocolIncompatible(
                            serverId: serverId,
                            reason: "initialize error \(error.code): \(error.message)"
                        )
                    }
                    return
                }

                if method == "session/list", let serverId = resolvedServerId {
                    serverViewModels[serverId]?.loadCachedSessions()
                }
                return
            }

            // Pre-sync initialize phase success validation (SD-1.2 / SC-AC-071)
            if method == "initialize" || method == "acp/initialize" {
                guard let serverId = resolvedServerId else { return }
                guard let parsed = ACPInitializeParser.parse(result: response.resultValue) else {
                    // Empty {} or non-ACP response: 0 nonlocal/sync, 0 business RPCs, immediate lockout!
                    markServerProtocolIncompatible(
                        serverId: serverId,
                        reason: "initialize returned non-ACP payload"
                    )
                    return
                }
                applyInitializeResult(parsed, serverId: serverId)
                initializationCache[serverId] = initializationSummary
                initializedServers.insert(serverId)
                // Business RPCs (session/list, fs_list, usage, loadPending) are strictly gated behind nonlocal/sync success!
                _ = beginInitialSyncIfNeeded(for: serverId)
                objectWillChange.send()
                return
            }

            let targetServerVM = resolvedServerId.flatMap { serverViewModels[$0] }
            let serverPendingContext = targetServerVM?.pendingNewSessionContext()
            let effectivePlaceholderId = resolvedServerId.flatMap { connectionPool.slotIfExists(for: $0)?.pendingNewSessionPlaceholderId }
                ?? serverPendingContext?.placeholderId
            let effectivePendingCwd = serverPendingContext?.cwd
            let context = ACPResponseDispatchContext(
                pendingPlaceholderId: effectivePlaceholderId,
                pendingCwd: effectivePendingCwd,
                cwdTransform: { $0 }
            )

            if method == "session/new" || method == "session/create" {
                if let serverId = resolvedServerId {
                    connectionPool.slotIfExists(for: serverId)?.pendingNewSessionPlaceholderId = nil
                }
                targetServerVM?.clearPendingNewSessionContext()
            }

            let actions = ACPResponseDispatcher.dispatchSuccess(
                result: response.resultValue,
                method: method,
                context: context
            )
            var migratedPlaceholderByTarget: [String: String] = [:]
            for action in actions {
                if case .sessionMigrated(let from, let to) = action {
                    migratedPlaceholderByTarget[to] = from
                }
                let migratedFrom: String? = {
                    if case .sessionActivated(let activation) = action {
                        return migratedPlaceholderByTarget[activation.sessionId]
                    }
                    return nil
                }()
                applyResponseAction(
                    action,
                    serverId: resolvedServerId,
                    method: method,
                    targetSessionId: requestTargetSessionId,
                    migratedPlaceholderId: migratedFrom
                )
            }
            objectWillChange.send()

        case .notification(let notification):
            if let resolvedServerId {
                append(render("Notification", method: notification.method, payload: notification.params), serverId: resolvedServerId)
            }
            if notification.method == NonlocalMethods.turnCompleted, let resolvedServerId {
                if let parsed = NonlocalSessionSyncParser.parseTurnCompleted(from: notification.params) {
                    syncCoordinator.handleTurnCompleted(parsed, serverId: resolvedServerId)
                    objectWillChange.send()
                }
                return
            }
            if notification.method == NonlocalMethods.sessionStale, let resolvedServerId {
                if let parsed = NonlocalSessionSyncParser.parseSessionStale(from: notification.params) {
                    syncCoordinator.handleSessionStale(parsed, serverId: resolvedServerId)
                    objectWillChange.send()
                }
                return
            }
            if notification.method == NonlocalMethods.usageUpdated {
                if let parsed = NonlocalUsageParser.parse(from: notification.params) {
                    let targetService = resolvedServerId.flatMap { self.service(for: $0) }
                    quotaManager.handleUsageUpdated(parsed, from: targetService)
                }
                return
            }
            if notification.method == NonlocalMethods.sessionDeleted {
                if let parsed = NonlocalSessionInfoParser.parseSessionDeleted(from: notification.params),
                   let targetServerId = resolvedServerId {
                    syncCoordinator.handleSessionDeleted(parsed, serverId: targetServerId)
                }
                return
            }
            if notification.method == "session/update", let resolvedServerId {
                let summary = ACPSessionUpdateParser.summarize(params: notification.params) { [weak self] update in
                    guard let self else { return "{}" }
                    return ACPMessageFormatter.compact(update, encoder: self.encoder)
                }
                append(summary, serverId: resolvedServerId)
                syncCoordinator.handleChatUpdate(notification.params, serverId: resolvedServerId)
                objectWillChange.send()
            }

        case .request(let request):
            if let resolvedServerId {
                append(render("Request", method: request.method, payload: request.params), serverId: resolvedServerId)
            }
            if request.method == "session/request_permission" {
                let reqSessionId = ACPPermissionRequestParser.parse(params: request.params)?.sessionId
                    ?? request.params.objectValue?["sessionId"]?.stringValue
                let targetVM: ACPSessionViewModel? = {
                    if let serverId = resolvedServerId, let reqSessionId, !reqSessionId.isEmpty {
                        return serverViewModels[serverId]?.sessionViewModel(for: reqSessionId)
                    }
                    return isSelected ? selectedServerViewModel?.currentSessionViewModel : nil
                }()
                targetVM?.handlePermissionRequest(request)
                objectWillChange.send()
            } else {
                respondToNonInteractiveServerRequest(request, serverId: resolvedServerId)
            }
        }
    }

    private func applyInitializeResult(_ parsed: ACPInitializeResult, serverId: UUID) {
        let isSelected = (serverId == selectedServerId)
        guard let agentInfo = parsed.agentInfo else { return }
        agentInfoCache[serverId] = agentInfo
        serverViewModels[serverId]?.updateAgentInfo(agentInfo)
        refreshImageAttachmentSupport(for: serverId)

        let summary = agentInfo.displayNameWithVersion + " (initialized)"
        initializationCache[serverId] = summary
        if isSelected {
            initializationSummary = summary
            isInitialAppLaunch = false
        }
        append(AgentInfoDiagnostics.capabilitySummary(for: agentInfo), serverId: serverId)

        if !agentInfo.modes.isEmpty {
            if let currentMode = parsed.currentModeId {
                serverViewModels[serverId]?.setDefaultModeId(currentMode)
            }
            if isSelected {
                availableModes = agentInfo.modes
                if let currentMode = parsed.currentModeId {
                    selectedServerViewModel?.currentSessionViewModel?.setCurrentModeId(currentMode)
                }
                append("Modes: \(agentInfo.modes.map(\.name).joined(separator: ", ")), current: \(selectedServerViewModel?.currentSessionViewModel?.currentModeId ?? "none")", serverId: serverId)
            }
        }
        objectWillChange.send()
    }

    /// Unified server-initiated non-interactive RPC rejection (SD-2.7 / SC-AC-046):
    /// FS/Terminal -> -32001, unknown methods -> -32601.
    private func respondToNonInteractiveServerRequest(_ request: ACP.AnyRequest, serverId explicitServerId: UUID? = nil) {
        let resolvedServerId = explicitServerId ?? selectedServerId
        switch request.method {
        case "fs/read_text_file":
            let path = request.params.objectValue?["path"]?.stringValue ?? "unknown"
            append("FS read requested: \(path) - not supported on iOS client", serverId: resolvedServerId)
            sendServerRequestError(
                to: request.id,
                code: -32001,
                message: "Filesystem access not available from iOS client. The file '\(path)' cannot be read.",
                serverId: resolvedServerId
            )
        case "fs/write_text_file":
            let path = request.params.objectValue?["path"]?.stringValue ?? "unknown"
            append("FS write requested: \(path) - not supported on iOS client", serverId: resolvedServerId)
            sendServerRequestError(
                to: request.id,
                code: -32001,
                message: "Filesystem access not available from iOS client. The file '\(path)' cannot be written.",
                serverId: resolvedServerId
            )
        case "terminal/create", "terminal/write", "terminal/resize", "terminal/release":
            append("Terminal request: \(request.method) - not supported on iOS client", serverId: resolvedServerId)
            sendServerRequestError(
                to: request.id,
                code: -32001,
                message: "Terminal access not available from iOS client.",
                serverId: resolvedServerId
            )
        default:
            sendServerRequestError(
                to: request.id,
                code: -32601,
                message: "Method not found: \(request.method)",
                serverId: resolvedServerId
            )
        }
    }

    private func sendServerRequestError(to requestId: ACP.ID, code: Int, message: String, serverId explicitServerId: UUID? = nil) {
        guard let resolvedServerId = explicitServerId ?? selectedServerId,
              let targetService = service(for: resolvedServerId) else { return }
        let errorResponse = ACPMessageBuilder.errorResponse(requestId: requestId, code: code, message: message)
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await targetService.sendMessage(errorResponse)
                self.logWire("→", message: errorResponse, serverId: resolvedServerId)
            } catch {
                self.append("Failed to send error response: \(error)", serverId: resolvedServerId)
            }
        }
    }

    private func applyResponseAction(
        _ action: ACPResponseAction,
        serverId explicitServerId: UUID? = nil,
        method: String?,
        targetSessionId: String? = nil,
        migratedPlaceholderId: String? = nil
    ) {
        guard let serverId = explicitServerId ?? selectedServerId else { return }
        let isSelected = (serverId == selectedServerId)

        switch action {
        case .sessionMigrated(let from, let to):
            migrateSessionCaches(for: serverId, from: from, to: to)

        case .sessionActivated(let activation):
            let serverVM = serverViewModels[serverId]
            let currentForeground = serverVM?.selectedSessionId
            let shouldActivateForeground = (currentForeground == nil
                || currentForeground?.isEmpty == true
                || currentForeground == activation.sessionId
                || (migratedPlaceholderId != nil && currentForeground == migratedPlaceholderId))
            let targetVM = serverVM?.sessionViewModel(for: activation.sessionId)
            if isSelected && shouldActivateForeground {
                serverVM?.setActiveSession(activation.sessionId, cwd: activation.cwd, modes: activation.modes)
                if let vm = serverVM {
                    availableModes = vm.availableModes
                }
            } else {
                targetVM?.setSessionContext(serverId: serverId, sessionId: activation.sessionId)
                if let modes = activation.modes {
                    targetVM?.setAvailableModes(modes.availableModes, currentModeId: modes.currentModeId)
                    targetVM?.cacheCurrentMode(serverId: serverId, sessionId: activation.sessionId)
                }
                _ = serverVM?.rememberSession(activation.sessionId, cwd: activation.cwd, updateSessionCache: false)
            }
            if !activation.configOptions.isEmpty {
                targetVM?.applySessionConfigOptions(
                    activation.configOptions,
                    serverId: serverId,
                    sessionId: activation.sessionId
                )
            }

        case .sessionMaterialized(let sessionId):
            slotConnectionManagerIfExists(for: serverId)?.markSessionMaterialized(sessionId)

        case .modeChanged(let modeId):
            let sid = (targetSessionId?.isEmpty == false) ? targetSessionId! : (serverViewModels[serverId]?.sessionId ?? "")
            let targetVM = serverViewModels[serverId]?.sessionViewModel(for: sid)
            targetVM?.setCurrentModeId(modeId)
            targetVM?.cacheCurrentMode(serverId: serverId, sessionId: sid)
            append("Mode changed to: \(modeId)", serverId: serverId)

        case .configOptionsChanged(let options):
            let sid = (targetSessionId?.isEmpty == false) ? targetSessionId! : (serverViewModels[serverId]?.sessionId ?? "")
            let targetVM = serverViewModels[serverId]?.sessionViewModel(for: sid)
            targetVM?.applySessionConfigOptions(options, serverId: serverId, sessionId: sid)
            append("Config options updated (\(options.count))", serverId: serverId)

        case .initialized(let result):
            applyInitializeResult(result, serverId: serverId)

        case .stopReason(let reason):
            let sid = (targetSessionId?.isEmpty == false) ? targetSessionId! : (serverViewModels[serverId]?.sessionId ?? "")
            syncCoordinator.markStopReasonCompleted(serverId: serverId, sessionId: sid)
            let targetVM = serverViewModels[serverId]?.sessionViewModel(for: sid)
            targetVM?.handleStopReason(reason, serverId: serverId, sessionId: sid)

        case .sessionListReceived(let listResult):
            serverViewModels[serverId]?.handleSessionListResult(listResult.sessions)

        case .sessionLoadCompleted:
            let sid = (targetSessionId?.isEmpty == false) ? targetSessionId! : (serverViewModels[serverId]?.sessionId ?? "")
            if !sid.isEmpty {
                slotConnectionManagerIfExists(for: serverId)?.markSessionMaterialized(sid)
            }
            syncCoordinator.clearAppliedTurnProgress(serverId: serverId, sessionId: sid)
            let targetVM = serverViewModels[serverId]?.sessionViewModel(for: sid)
            targetVM?.handleSessionLoadCompleted(serverId: serverId, sessionId: sid)

        case .rpcError:
            break
        }
    }

    // MARK: - Sync & Deletion Coordination Wrappers

    func hasInitialSyncPending(for serverId: UUID?) -> Bool {
        syncCoordinator.hasInitialSyncPending(for: serverId)
    }

    func awaitInitialSyncIfNeeded(for serverId: UUID?) async {
        await syncCoordinator.awaitInitialSyncIfNeeded(for: serverId)
    }

    func resetSyncCoordinationState(for serverId: UUID? = nil) {
        syncCoordinator.reset(for: serverId)
        if serverId == nil {
            for vm in serverViewModels.values {
                vm.resetNonlocalSyncProtectionState()
            }
        }
    }

    @discardableResult
    func beginInitialSyncIfNeeded(for serverId: UUID) -> Task<Void, Never>? {
        syncCoordinator.beginInitialSyncIfNeeded(for: serverId)
    }

    func handleNonlocalSessionStale(_ notification: NonlocalSessionStaleNotification, serverId: UUID?) {
        guard let serverId else { return }
        syncCoordinator.handleSessionStale(notification, serverId: serverId)
        objectWillChange.send()
    }

    func handleNonlocalSessionDeleted(_ notice: NonlocalSessionDeletedNotification, serverId targetServerId: UUID?) {
        guard let serverId = targetServerId else { return }
        syncCoordinator.handleSessionDeleted(notice, serverId: serverId)
    }

    func applyImmediateSessionDeletion(sessionId sid: String, serverId: UUID) {
        guard !sid.isEmpty else { return }
        serverViewModels[serverId]?.deleteSession(sid)
        if sessionCache[serverId] == sid {
            sessionCache.removeValue(forKey: serverId)
        }
        syncCoordinator.clearSessionState(for: serverId, sessionId: sid)
        if let slot = connectionPool.slotIfExists(for: serverId) {
            slot.pendingRequestSessionIds = slot.pendingRequestSessionIds.filter { $0.value != sid }
        }
        chatCache.clearCache(for: serverId, sessionId: sid)
        storage.deleteSession(sessionId: sid, forServerId: serverId)
        onSessionDeletedPop?(serverId, sid)
    }

    // MARK: - Quota Delegation

    func endpointSignature(for serverId: UUID) -> String {
        guard let config = servers.first(where: { $0.id == serverId }) else {
            return serverId.uuidString
        }
        return "\(config.scheme)://\(config.host)"
    }

    func bindService(_ service: ACPService, to serverId: UUID) {
        quotaManager.bindService(service, to: serverId)
    }

    func unbindServices(for serverId: UUID) {
        quotaManager.unbindServices(for: serverId)
    }

    func resetConnectionUsageState(for serverId: UUID) {
        quotaManager.resetConnectionUsageState(for: serverId)
    }

    func clearQuotaUsageState(for serverId: UUID) {
        quotaManager.clear(for: serverId)
    }

    func shouldShowQuotaCard(for serverId: UUID?) -> Bool {
        quotaManager.shouldShowQuotaCard(for: serverId)
    }

    func cancelQuotaRefreshTimer() {
        quotaManager.cancelRefreshTimer()
    }

    func triggerQuotaProbeOrRefreshIfNeeded(for serverId: UUID, service: ACPService, force: Bool = false) {
        quotaManager.triggerRefreshIfNeeded(for: serverId, service: service, force: force)
    }

    func performQuotaFetch(for serverId: UUID, service: ACPService) async {
        await quotaManager.performFetch(for: serverId, service: service)
    }

    func handleNonlocalUsageUpdated(_ incoming: NonlocalUsageResult, from sourceService: ACPService?) {
        quotaManager.handleUsageUpdated(incoming, from: sourceService)
    }

    // MARK: - Testing Helpers (SC-AC-053)

    func acpService(_ service: ACPService, didReceiveMessage message: ACPWireMessage) {
        if case .notification(let notification) = message {
            if notification.method == NonlocalMethods.usageUpdated {
                if let parsed = NonlocalUsageParser.parse(from: notification.params) {
                    quotaManager.handleUsageUpdated(parsed, from: service)
                }
                return
            }
            if notification.method == NonlocalMethods.sessionDeleted {
                if let parsed = NonlocalSessionInfoParser.parseSessionDeleted(from: notification.params) {
                    let targetServerId = quotaManager.boundServerId(for: service)
                        ?? (self.service === service ? selectedServerId : nil)
                    if let targetServerId {
                        syncCoordinator.handleSessionDeleted(parsed, serverId: targetServerId)
                    }
                }
                return
            }
        }
        guard let targetServerId = quotaManager.boundServerId(for: service) ?? selectedServerId else {
            handleIncoming(message)
            return
        }
        let slot = connectionSlot(for: targetServerId)
        slotManager(slot.connectionManager, serverId: targetServerId, didReceiveMessage: message)
    }

    func acpService(_ service: ACPService, willSend request: ACP.AnyRequest) {
        guard let targetServerId = quotaManager.boundServerId(for: service) ?? selectedServerId else {
            return
        }
        let slot = connectionSlot(for: targetServerId)
        slotManager(slot.connectionManager, serverId: targetServerId, willSendRequest: request)
    }

    func setServiceForTesting(_ service: ACPService?) {
        guard let sid = selectedServerId else { return }
        let slot = connectionSlot(for: sid)
        slot.connectionManager.setServiceForTesting(service)
        if let service {
            bindService(service, to: sid)
        }
        objectWillChange.send()
    }

    func setServiceForTesting(_ service: ACPService, for serverId: UUID) {
        let slot = connectionSlot(for: serverId)
        slot.connectionManager.setServiceForTesting(service)
        bindService(service, to: serverId)
        slot.lastConnectedAt = Date()
        objectWillChange.send()
    }

    // MARK: - Per-Slot Logging & Formatting

    private func renderResponse(_ response: ACP.AnyResponse, method: String?) -> String {
        let idLabel = ACPMessageFormatter.idString(response.id)
        if let error = response.errorValue {
            let body = ACPMessageFormatter.compact(error, encoder: encoder)
            return "Error response id=\(idLabel) \(method.map { "(\($0))" } ?? ""): \(body)"
        }
        if let payload = response.resultValue {
            return "Response id=\(idLabel) \(method.map { "(\($0))" } ?? ""): \(ACPMessageFormatter.compact(payload, encoder: encoder))"
        }
        return "Response id=\(idLabel) \(method.map { "(\($0))" } ?? "")"
    }

    private func render(_ kind: String, method: String?, payload: ACP.Value?) -> String {
        let methodLabel = method ?? ""
        if let payload {
            return "\(kind) \(methodLabel): \(ACPMessageFormatter.compact(payload, encoder: encoder))"
        }
        return "\(kind) \(methodLabel)"
    }

    func logWire(_ direction: String, message: ACPWireMessage, serverId: UUID? = nil, methodOverride: String? = nil) {
        let targetServerId = serverId ?? selectedServerId
        let label: String?
        switch message {
        case .request(let request): label = request.method
        case .notification(let notification): label = notification.method
        case .response(let response):
            label = methodOverride
                ?? targetServerId.flatMap { connectionPool.slotIfExists(for: $0)?.pendingRequests[response.id] }
        }
        if shouldSummarizeServerLog(method: label) {
            append(summarizedServerLogLine(direction: direction, label: label), serverId: targetServerId)
            return
        }
        let body = ACPMessageFormatter.compact(message, encoder: encoder)
        if let label {
            append("\(direction) \(label): \(body)", serverId: targetServerId)
        } else {
            append("\(direction) \(body)", serverId: targetServerId)
        }
    }

    private func shouldSummarizeServerLog(method: String?) -> Bool {
        method == "session/update"
            || method == NonlocalMethods.fsList
            || method == NonlocalMethods.fsReadFile
    }

    private func shouldAppendStructuredResponseLog(_ response: ACP.AnyResponse, method: String?) -> Bool {
        if response.errorValue != nil { return true }
        return !shouldSummarizeServerLog(method: method)
    }

    private func summarizedServerLogLine(direction: String, label: String?) -> String {
        if let label {
            return "\(direction) \(label): [payload omitted in Server Logs]"
        }
        return "\(direction) [payload omitted in Server Logs]"
    }

    func append(_ text: String, serverId: UUID? = nil) {
        guard let targetServerId = serverId ?? selectedServerId else { return }
        let isSelected = connectionPool.appendLog(text, serverId: targetServerId)
        if isSelected {
            objectWillChange.send()
        }
    }

    func stateLabel(_ state: ACPConnectionState) -> String {
        switch state {
        case .disconnected: return AppLocalization.localized("Disconnected")
        case .connecting: return AppLocalization.localized("Connecting")
        case .connected: return AppLocalization.localized("Connected")
        case .failed(let error): return String(format: AppLocalization.localized("Failed: %@"), String(describing: error))
        }
    }

    func stateLabel(for serverId: UUID?) -> String {
        guard let serverId else {
            return wasPreempted && connectionState == .disconnected
                ? AppLocalization.localized("Taken over by another connection")
                : stateLabel(connectionState)
        }
        if isProtocolIncompatible(for: serverId) {
            return AppLocalization.localized("Incompatible bridge")
        }
        let state = connectionState(for: serverId)
        if state == .disconnected && wasPreempted(for: serverId) {
            return AppLocalization.localized("Taken over by another connection")
        }
        return stateLabel(state)
    }

    var currentStateLabel: String {
        stateLabel(for: selectedServerId)
    }

    // MARK: - ACPSessionCacheDelegate (Memory -> ChatMessageCache, Core Data -> ServerViewModel)

    func saveMessages(_ messages: [ChatMessage], for serverId: UUID, sessionId: String) {
        chatCache.saveMessages(messages, for: serverId, sessionId: sessionId)
    }

    func loadMessages(for serverId: UUID, sessionId: String) -> [ChatMessage]? {
        chatCache.loadMessages(for: serverId, sessionId: sessionId)
    }

    func saveStopReason(_ reason: String, for serverId: UUID, sessionId: String) {
        chatCache.saveStopReason(reason, for: serverId, sessionId: sessionId)
    }

    func loadStopReason(for serverId: UUID, sessionId: String) -> String? {
        chatCache.loadStopReason(for: serverId, sessionId: sessionId)
    }

    func clearCache(for serverId: UUID, sessionId: String) {
        chatCache.clearCache(for: serverId, sessionId: sessionId)
    }

    func clearCache(for serverId: UUID) {
        chatCache.clearCache(for: serverId)
    }

    func migrateCache(serverId: UUID, from placeholderId: String, to resolvedId: String) {
        chatCache.migrateCache(serverId: serverId, from: placeholderId, to: resolvedId)
    }

    func hasCachedMessages(serverId: UUID, sessionId: String) -> Bool {
        chatCache.hasCachedMessages(serverId: serverId, sessionId: sessionId)
    }

    func getLastMessagePreview(for serverId: UUID, sessionId: String) -> String? {
        chatCache.getLastMessagePreview(for: serverId, sessionId: sessionId)
    }

    func loadChatFromStorage(sessionId: String, serverId: UUID) -> [ChatMessage] {
        if let serverVM = serverViewModels[serverId] {
            return serverVM.loadChatFromStorage(sessionId: sessionId)
        }
        return storage.fetchMessages(forSessionId: sessionId, serverId: serverId).map { ChatMessage(from: $0) }
    }

    func persistChatToStorage(serverId: UUID, sessionId: String) {
        persistChatToStorage(serverId: serverId, sessionId: sessionId, allowEmpty: false)
    }

    func persistChatToStorage(serverId: UUID, sessionId: String, allowEmpty: Bool) {
        serverViewModels[serverId]?.persistChatToStorage(sessionId: sessionId, allowEmpty: allowEmpty)
    }
}
