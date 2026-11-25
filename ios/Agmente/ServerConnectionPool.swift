import Foundation
import SwiftUI
import ACP
import ACPClient

/// Per-server isolated connection slot owned by `ServerConnectionPool` (SD-2.1 / SD-2.2).
/// Strictly contains transport/routing/lockout/log state — zero sync fields and zero dead fields.
@MainActor
final class ServerConnectionSlot {
    let serverId: UUID
    let connectionManager: ACPClientManager
    let delegateBridge: ServerConnectionSlotDelegate

    var pendingRequests: [ACP.ID: String] = [:]
    var pendingRequestSessionIds: [ACP.ID: String] = [:]
    var pendingNewSessionPlaceholderId: String?
    var updates: [LogLine] = []
    var lastConnectedAt: Date?
    var isManuallyDisconnected: Bool = false
    var hasProbedHomePath: Bool = false
    /// Protocol-incompatibility lockout state (SD-1.2 / DEC-18 / DEC-19), strictly isolated from 4001 `wasPreempted`.
    var isProtocolIncompatible: Bool = false
    var protocolIncompatibleMessage: String?

    var service: ACPService? { connectionManager.service }
    var connectionState: ACPConnectionState { connectionManager.connectionState }

    init(
        serverId: UUID,
        connectionManager: ACPClientManager,
        owner: any ServerConnectionSlotDelegateOwner
    ) {
        self.serverId = serverId
        self.connectionManager = connectionManager
        self.delegateBridge = ServerConnectionSlotDelegate(serverId: serverId, owner: owner)
        self.connectionManager.delegate = self.delegateBridge
    }
}

/// Single-track multi-server connection pool managing all server slots, per-slot logs,
/// 5-path protocol-incompatibility lockout, 4001 preemption, ScenePhase transitions,
/// and multi-server network recovery (SD-2.1 / SD-2.2 / DEC-29).
@MainActor
final class ServerConnectionPool {
    static let maxLogLines = 300

    private(set) var slots: [UUID: ServerConnectionSlot] = [:]
    private let defaults: UserDefaults
    private let shouldStartNetworkMonitoring: Bool
    private let connectionManagerFactory: ((UUID) -> ACPClientManager)?
    private let defaultSlotServiceFactory: ((ACPClientConfiguration, JSONEncoder) -> ACPService)?
    private weak var delegateOwner: (any ServerConnectionSlotDelegateOwner)?

    var initializationPayloadProvider: () -> ACPInitializationPayload? = { nil }
    var serversProvider: () -> [ACPServerConfiguration] = { [] }
    var selectedServerIdProvider: () -> UUID? = { nil }

    /// Tracks whether the app genuinely entered `.background` since the last `.active` phase (DEC-2=A).
    var hasEnteredBackgroundSinceLastActive: Bool = false
    private var networkRecoveryTask: Task<Void, Never>?

    init(
        defaults: UserDefaults,
        shouldStartNetworkMonitoring: Bool,
        connectionManagerFactory: ((UUID) -> ACPClientManager)? = nil,
        defaultSlotServiceFactory: ((ACPClientConfiguration, JSONEncoder) -> ACPService)? = nil
    ) {
        self.defaults = defaults
        self.shouldStartNetworkMonitoring = shouldStartNetworkMonitoring
        self.connectionManagerFactory = connectionManagerFactory
        self.defaultSlotServiceFactory = defaultSlotServiceFactory
    }

    deinit {
        networkRecoveryTask?.cancel()
    }

    func setDelegateOwner(_ owner: any ServerConnectionSlotDelegateOwner) {
        self.delegateOwner = owner
    }

    func slot(for serverId: UUID) -> ServerConnectionSlot {
        if let existing = slots[serverId] {
            return existing
        }
        let manager: ACPClientManager
        if let factory = connectionManagerFactory {
            manager = factory(serverId)
        } else {
            manager = ACPClientManager(
                defaults: defaults,
                shouldStartNetworkMonitoring: shouldStartNetworkMonitoring,
                serviceFactory: defaultSlotServiceFactory
            )
        }
        manager.initializationPayloadProvider = { [weak self] in
            self?.initializationPayloadProvider()
        }
        guard let owner = delegateOwner else {
            preconditionFailure("ServerConnectionPool delegateOwner must be configured before creating slots")
        }
        let newSlot = ServerConnectionSlot(serverId: serverId, connectionManager: manager, owner: owner)
        slots[serverId] = newSlot
        return newSlot
    }

    func slotIfExists(for serverId: UUID) -> ServerConnectionSlot? {
        slots[serverId]
    }

    func manager(for serverId: UUID) -> ACPClientManager {
        slot(for: serverId).connectionManager
    }

    func managerIfExists(for serverId: UUID) -> ACPClientManager? {
        slots[serverId]?.connectionManager
    }

    func service(for serverId: UUID) -> ACPService? {
        guard let slot = slots[serverId] else { return nil }
        return slot.connectionState == .connected ? slot.service : nil
    }

    func connectionState(for serverId: UUID) -> ACPConnectionState {
        slots[serverId]?.connectionState ?? .disconnected
    }

    func wasPreempted(for serverId: UUID) -> Bool {
        slots[serverId]?.connectionManager.wasPreempted ?? false
    }

    func isProtocolIncompatible(for serverId: UUID) -> Bool {
        slots[serverId]?.isProtocolIncompatible ?? false
    }

    func protocolIncompatibleMessage(for serverId: UUID) -> String? {
        slots[serverId]?.protocolIncompatibleMessage
    }

    func lastConnectedAt(for serverId: UUID) -> Date? {
        slots[serverId]?.lastConnectedAt
    }

    func isManuallyDisconnected(serverId: UUID) -> Bool {
        slots[serverId]?.isManuallyDisconnected ?? false
    }

    func updates(for serverId: UUID) -> [LogLine] {
        slots[serverId]?.updates ?? []
    }

    @discardableResult
    func appendLog(_ text: String, serverId: UUID) -> Bool {
        let targetSlot = slot(for: serverId)
        let log = LogLine(id: UUID(), timestamp: Date(), message: text)
        if targetSlot.updates.count >= Self.maxLogLines {
            targetSlot.updates.removeFirst(targetSlot.updates.count - Self.maxLogLines + 1)
        }
        targetSlot.updates.append(log)
        return serverId == selectedServerIdProvider()
    }

    /// Marks `serverId` as protocol-incompatible, immediately disconnects (stopping backoff auto-reconnect),
    /// and preserves `wasPreempted == false` (SD-1.2 / DEC-18 / DEC-19).
    func markProtocolIncompatible(serverId: UUID, message: String) {
        let targetSlot = slot(for: serverId)
        targetSlot.isProtocolIncompatible = true
        targetSlot.protocolIncompatibleMessage = message
        targetSlot.pendingRequests.removeAll()
        targetSlot.pendingRequestSessionIds.removeAll()
        targetSlot.pendingNewSessionPlaceholderId = nil
        targetSlot.connectionManager.disconnect()
    }

    func clearProtocolIncompatibility(for serverId: UUID) {
        guard let targetSlot = slots[serverId] else { return }
        targetSlot.isProtocolIncompatible = false
        targetSlot.protocolIncompatibleMessage = nil
    }

    func releaseSlot(for serverId: UUID) {
        guard let removed = slots.removeValue(forKey: serverId) else { return }
        removed.pendingRequests.removeAll()
        removed.pendingRequestSessionIds.removeAll()
        removed.pendingNewSessionPlaceholderId = nil
        removed.connectionManager.disconnect()
    }

    /// Connects all eligible (non-manually-disconnected, non-protocol-incompatible) servers (Path 5).
    func connectAllServers(servers: [ACPServerConfiguration]) {
        for server in servers {
            let targetSlot = slot(for: server.id)
            guard !targetSlot.isManuallyDisconnected else { continue }
            guard !targetSlot.isProtocolIncompatible else { continue }
            guard !targetSlot.connectionManager.isConnecting else { continue }
            switch targetSlot.connectionState {
            case .disconnected, .failed:
                connectServer(server, userInitiated: false)
            case .connected, .connecting:
                break
            }
        }
    }

    func connectServer(
        _ config: ACPServerConfiguration,
        userInitiated: Bool,
        pingInterval: TimeInterval = 20,
        completion: ((Bool) -> Void)? = nil
    ) {
        let targetSlot = slot(for: config.id)
        if userInitiated {
            targetSlot.isProtocolIncompatible = false
            targetSlot.protocolIncompatibleMessage = nil
        } else if targetSlot.isProtocolIncompatible {
            completion?(false)
            return
        }
        targetSlot.isManuallyDisconnected = false
        targetSlot.pendingRequests.removeAll()
        targetSlot.pendingRequestSessionIds.removeAll()

        let normalized = BridgeServerValidator.normalizeEndpoint(scheme: config.scheme, host: config.host)
        let urlString = "\(normalized.scheme)://\(normalized.host)"
        guard let url = URL(string: urlString) else {
            _ = appendLog("Invalid endpoint: \(urlString)", serverId: config.id)
            completion?(false)
            return
        }
        let trimmedToken = config.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let connConfig = ACPConnectionConfig(
            endpoint: url,
            authToken: trimmedToken.isEmpty ? nil : trimmedToken,
            pingInterval: pingInterval
        )
        targetSlot.connectionManager.shouldAutoInitialize = true
        targetSlot.connectionManager.connect(config: connConfig, completion: completion)
    }

    func connectServerAndWait(
        _ config: ACPServerConfiguration,
        userInitiated: Bool,
        pingInterval: TimeInterval = 15
    ) async -> Bool {
        let targetSlot = slot(for: config.id)
        if userInitiated {
            targetSlot.isProtocolIncompatible = false
            targetSlot.protocolIncompatibleMessage = nil
        } else if targetSlot.isProtocolIncompatible {
            return false
        }
        targetSlot.isManuallyDisconnected = false
        targetSlot.pendingRequests.removeAll()
        targetSlot.pendingRequestSessionIds.removeAll()

        let normalized = BridgeServerValidator.normalizeEndpoint(scheme: config.scheme, host: config.host)
        let urlString = "\(normalized.scheme)://\(normalized.host)"
        guard let url = URL(string: urlString) else {
            _ = appendLog("Invalid endpoint: \(urlString)", serverId: config.id)
            return false
        }
        let trimmedToken = config.token.trimmingCharacters(in: .whitespacesAndNewlines)
        let connConfig = ACPConnectionConfig(
            endpoint: url,
            authToken: trimmedToken.isEmpty ? nil : trimmedToken,
            pingInterval: pingInterval
        )
        targetSlot.connectionManager.shouldAutoInitialize = true
        return await targetSlot.connectionManager.connectAndWait(config: connConfig)
    }

    func disconnect(serverId: UUID, manual: Bool) {
        let targetSlot = slot(for: serverId)
        if manual {
            targetSlot.isManuallyDisconnected = true
        }
        targetSlot.pendingRequests.removeAll()
        targetSlot.pendingRequestSessionIds.removeAll()
        targetSlot.pendingNewSessionPlaceholderId = nil
        targetSlot.connectionManager.disconnect()
    }

    /// 3-state ScenePhase lifecycle handler (Path 3 / DEC-2=A / SD-1.2):
    /// - `.background`: marks `hasEnteredBackgroundSinceLastActive = true` and disconnects active/connecting slots.
    /// - `.active`: reconnects eligible slots (skipping `isManuallyDisconnected`, `isProtocolIncompatible`,
    ///   and `wasPreempted` unless `cameFromBackground`).
    func handleScenePhaseChanged(_ phase: ScenePhase, servers: [ACPServerConfiguration]) {
        switch phase {
        case .inactive:
            break
        case .background:
            hasEnteredBackgroundSinceLastActive = true
            for targetSlot in slots.values {
                if targetSlot.connectionState == .connected
                    || targetSlot.connectionState == .connecting
                    || targetSlot.connectionManager.isConnecting {
                    targetSlot.connectionManager.disconnect()
                }
            }
        case .active:
            let cameFromBackground = hasEnteredBackgroundSinceLastActive
            hasEnteredBackgroundSinceLastActive = false
            for server in servers {
                let targetSlot = slot(for: server.id)
                guard !targetSlot.isManuallyDisconnected else { continue }
                guard !targetSlot.isProtocolIncompatible else { continue }
                if targetSlot.connectionState != .connected && !targetSlot.connectionManager.isConnecting {
                    if targetSlot.connectionManager.wasPreempted && !cameFromBackground {
                        continue
                    }
                    connectServer(server, userInitiated: false)
                }
            }
        @unknown default:
            break
        }
    }

    /// Multi-server network recovery (Path 2 / DEC-29 / SC-AC-040):
    /// Checks EVERY eligible slot (non-manual, non-4001, non-protocol-locked).
    /// - `.connected` slots run `verifyConnectionHealth()` (`ping()`) and reconnect if half-open dead.
    /// - `.disconnected`/`.failed` slots immediately reconnect.
    func resumeAllEligibleOnNetworkRecovery(servers: [ACPServerConfiguration]) {
        networkRecoveryTask?.cancel()
        networkRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for server in servers {
                guard !Task.isCancelled else { return }
                let targetSlot = self.slot(for: server.id)
                guard !targetSlot.isManuallyDisconnected else { continue }
                guard !targetSlot.isProtocolIncompatible else { continue }
                guard !targetSlot.connectionManager.wasPreempted else { continue }

                if targetSlot.connectionState == .connected {
                    await targetSlot.connectionManager.verifyConnectionHealth()
                    guard !Task.isCancelled else { return }
                    guard !targetSlot.isManuallyDisconnected,
                          !targetSlot.isProtocolIncompatible,
                          !targetSlot.connectionManager.wasPreempted else {
                        continue
                    }
                    if targetSlot.connectionState != .connected && !targetSlot.connectionManager.isConnecting {
                        self.connectServer(server, userInitiated: false)
                    }
                } else if !targetSlot.connectionManager.isConnecting {
                    self.connectServer(server, userInitiated: false)
                }
            }
        }
    }
}

@MainActor
protocol ServerConnectionSlotDelegateOwner: AnyObject {
    func slotManager(_ manager: ACPClientManager, serverId: UUID, didChangeState state: ACPConnectionState)
    func slotManager(_ manager: ACPClientManager, serverId: UUID, didChangeNetworkAvailability available: Bool)
    func slotManager(_ manager: ACPClientManager, serverId: UUID, didEncounterError error: Error)
    func slotManager(_ manager: ACPClientManager, serverId: UUID, didLog message: String)
    func slotManager(_ manager: ACPClientManager, serverId: UUID, didCreateService service: ACPService)
    func slotManager(_ manager: ACPClientManager, serverId: UUID, didReceiveMessage message: ACPWireMessage)
    func slotManager(_ manager: ACPClientManager, serverId: UUID, didReceiveNotification notification: ACP.AnyMessage)
    func slotManager(_ manager: ACPClientManager, serverId: UUID, willSendRequest request: ACP.AnyRequest)
}

/// Thin forwarding delegate carrying the originating `serverId` so concurrent multi-server callbacks never cross-talk.
final class ServerConnectionSlotDelegate: ACPClientManagerDelegate {
    let serverId: UUID
    weak var owner: (any ServerConnectionSlotDelegateOwner)?

    init(serverId: UUID, owner: any ServerConnectionSlotDelegateOwner) {
        self.serverId = serverId
        self.owner = owner
    }

    func clientManager(_ manager: ACPClientManager, didChangeState state: ACPConnectionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.slotManager(manager, serverId: self.serverId, didChangeState: state)
        }
    }

    func clientManager(_ manager: ACPClientManager, didChangeNetworkAvailability available: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.slotManager(manager, serverId: self.serverId, didChangeNetworkAvailability: available)
        }
    }

    func clientManager(_ manager: ACPClientManager, didEncounterError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.slotManager(manager, serverId: self.serverId, didEncounterError: error)
        }
    }

    func clientManager(_ manager: ACPClientManager, didLog message: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.slotManager(manager, serverId: self.serverId, didLog: message)
        }
    }

    func clientManager(_ manager: ACPClientManager, didCreateService service: ACPService) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.slotManager(manager, serverId: self.serverId, didCreateService: service)
        }
    }

    func clientManager(_ manager: ACPClientManager, didReceiveMessage message: ACPWireMessage) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.slotManager(manager, serverId: self.serverId, didReceiveMessage: message)
        }
    }

    func clientManager(_ manager: ACPClientManager, didReceiveNotification notification: ACP.AnyMessage) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.slotManager(manager, serverId: self.serverId, didReceiveNotification: notification)
        }
    }

    func clientManager(_ manager: ACPClientManager, willSendRequest request: ACP.AnyRequest) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.owner?.slotManager(manager, serverId: self.serverId, willSendRequest: request)
        }
    }
}

/// Host-layer structured error for `nonlocal/delete_session` (T2 / SD-1.9 & W2-AC-125).
public enum RemoteSessionDeleteError: Error, Equatable, Sendable {
    case activeSession
    case dbBusy
    case deleteFailed(String?)
    case storageUnconfigured
    case unsupportedRemoteDelete
    case notConnected
    case other(String)

    public static func from(_ error: Error) -> RemoteSessionDeleteError {
        if let deleteErr = error as? RemoteSessionDeleteError {
            return deleteErr
        }
        if let serviceError = error as? ACPServiceError {
            if let code = serviceError.rpcCode {
                if code == -32601 {
                    return .unsupportedRemoteDelete
                }
                if let mapped = NonlocalDeleteErrorCode(rawValue: code) {
                    switch mapped {
                    case .sessionActive:
                        return .activeSession
                    case .dbBusy:
                        return .dbBusy
                    case .deleteFailed:
                        return .deleteFailed(serviceError.rpcMessage)
                    case .storageUnconfigured:
                        return .storageUnconfigured
                    }
                }
            }
            if case .disconnected = serviceError {
                return .notConnected
            }
            return .other(serviceError.rpcMessage ?? serviceError.localizedDescription)
        }
        return .other(error.localizedDescription)
    }

    public var localizedMessage: String {
        switch self {
        case .activeSession:
            return String(localized: "Session is currently running or awaiting approval. Please stop it first.")
        case .dbBusy:
            return String(localized: "Host session database is busy. Please try again.")
        case .deleteFailed(let detail):
            if let detail, !detail.isEmpty {
                return String(localized: "Failed to delete session: \(detail)")
            }
            return String(localized: "Failed to delete session on host. Please try again.")
        case .storageUnconfigured:
            return String(localized: "Host session storage directory is not configured.")
        case .unsupportedRemoteDelete:
            return String(localized: "This server does not support remote session deletion.")
        case .notConnected:
            return String(localized: "Not connected to server.")
        case .other(let msg):
            return msg
        }
    }
}
