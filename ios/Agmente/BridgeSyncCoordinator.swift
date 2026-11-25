import Foundation
import ACP
import ACPClient

/// Exclusively owns per-server `nonlocal/sync` lifecycle tasks, generations,
/// 4-way event buffering, `nonlocalSeq` deduplication, and protocol-incompatibility gating (SD-1.2 / SD-2.4).
@MainActor
final class BridgeSyncCoordinator {
    struct SlotSyncState {
        var initialSyncTask: Task<Void, Never>?
        var initialSyncGeneration: UInt64 = 0
        var activeSyncServiceObjectId: ObjectIdentifier?
        var syncedServiceObjectId: ObjectIdentifier?
    }

    var syncStateByServer: [UUID: SlotSyncState] = [:]
    var isSyncingByServer: [UUID: Bool] = [:]
    private var suppressPreBaselineSyncUnread: Set<UUID> = []
    private(set) var currentBridgeInstanceId: [UUID: String] = [:]

    var bufferedLiveUpdatesDuringSync: [UUID: [ACP.Value]] = [:]
    var bufferedTurnCompletedDuringSync: [UUID: [NonlocalTurnCompletedNotification]] = [:]
    var bufferedSessionStaleDuringSync: [UUID: [NonlocalSessionStaleNotification]] = [:]
    var bufferedSessionDeletedDuringSync: [UUID: [NonlocalSessionDeletedNotification]] = [:]

    var pendingClientTurnIds: [UUID: [String: String]] = [:]
    var completedClientTurnIds: [UUID: [String: Set<String>]] = [:]
    var completedSyncTurnIds: [UUID: [String: Set<String>]] = [:]
    var appliedTurnProgress: [UUID: [String: (turnId: String, lastSeq: Int)]] = [:]

    // Unidirectional hooks wired by AppViewModel
    var serviceProvider: (UUID) -> ACPService? = { _ in nil }
    var serverViewModelProvider: (UUID) -> ServerViewModel? = { _ in nil }
    var connectionManagerProvider: (UUID) -> ACPClientManager? = { _ in nil }
    var selectedServerIdProvider: () -> UUID? = { nil }
    var onAvailableModesDiscovered: (UUID, [AgentModeOption]) -> Void = { _, _ in }
    var onFailPendingTurn: (String, UUID, String?) -> Void = { _, _, _ in }
    var onApplyImmediateSessionDeletion: (String, UUID) -> Void = { _, _ in }
    var onSyncSucceeded: (UUID, ACPService) -> Void = { _, _ in }
    var onProtocolIncompatible: (UUID, String) -> Void = { _, _ in }
    var onChange: () -> Void = {}

    deinit {
        for state in syncStateByServer.values {
            state.initialSyncTask?.cancel()
        }
    }

    func hasInitialSyncPending(for serverId: UUID?) -> Bool {
        guard let serverId else { return false }
        if syncStateByServer[serverId]?.initialSyncTask != nil { return true }
        return isSyncingByServer[serverId] == true
    }

    func awaitInitialSyncIfNeeded(for serverId: UUID?) async {
        guard let serverId else { return }
        while let task = syncStateByServer[serverId]?.initialSyncTask {
            await task.value
        }
    }

    func reset(for serverId: UUID? = nil) {
        if let serverId {
            syncStateByServer[serverId]?.initialSyncTask?.cancel()
            syncStateByServer[serverId]?.initialSyncTask = nil
            syncStateByServer[serverId]?.activeSyncServiceObjectId = nil
            syncStateByServer[serverId]?.syncedServiceObjectId = nil
            isSyncingByServer.removeValue(forKey: serverId)
            bufferedLiveUpdatesDuringSync.removeValue(forKey: serverId)
            bufferedTurnCompletedDuringSync.removeValue(forKey: serverId)
            bufferedSessionStaleDuringSync.removeValue(forKey: serverId)
            bufferedSessionDeletedDuringSync.removeValue(forKey: serverId)
            serverViewModelProvider(serverId)?.resetNonlocalSyncProtectionState()
            return
        }
        for key in Array(syncStateByServer.keys) {
            syncStateByServer[key]?.initialSyncTask?.cancel()
            syncStateByServer[key]?.initialSyncTask = nil
            syncStateByServer[key]?.activeSyncServiceObjectId = nil
            syncStateByServer[key]?.syncedServiceObjectId = nil
        }
        isSyncingByServer.removeAll()
        bufferedLiveUpdatesDuringSync.removeAll()
        bufferedTurnCompletedDuringSync.removeAll()
        bufferedSessionStaleDuringSync.removeAll()
        bufferedSessionDeletedDuringSync.removeAll()
    }

    func removeAllState(for serverId: UUID) {
        reset(for: serverId)
        syncStateByServer.removeValue(forKey: serverId)
        suppressPreBaselineSyncUnread.remove(serverId)
        currentBridgeInstanceId.removeValue(forKey: serverId)
        pendingClientTurnIds.removeValue(forKey: serverId)
        completedClientTurnIds.removeValue(forKey: serverId)
        completedSyncTurnIds.removeValue(forKey: serverId)
        appliedTurnProgress.removeValue(forKey: serverId)
    }

    func clearSessionState(for serverId: UUID, sessionId: String) {
        pendingClientTurnIds[serverId]?.removeValue(forKey: sessionId)
        completedSyncTurnIds[serverId]?.removeValue(forKey: sessionId)
        completedClientTurnIds[serverId]?.removeValue(forKey: sessionId)
        appliedTurnProgress[serverId]?.removeValue(forKey: sessionId)
    }

    func clearTurnStateOnDisconnect(for serverId: UUID) {
        pendingClientTurnIds.removeValue(forKey: serverId)
        appliedTurnProgress.removeValue(forKey: serverId)
    }

    func clearAppliedTurnProgress(serverId: UUID, sessionId: String, turnId: String? = nil) {
        guard !sessionId.isEmpty else { return }
        if let turnId, appliedTurnProgress[serverId]?[sessionId]?.turnId != turnId {
            return
        }
        appliedTurnProgress[serverId]?.removeValue(forKey: sessionId)
        if appliedTurnProgress[serverId]?.isEmpty == true {
            appliedTurnProgress.removeValue(forKey: serverId)
        }
    }

    func recordSentClientTurnId(serverId: UUID, sessionId: String, clientTurnId: String) {
        clearAppliedTurnProgress(serverId: serverId, sessionId: sessionId)
        pendingClientTurnIds[serverId, default: [:]][sessionId] = clientTurnId
    }

    func clearClientTurnId(serverId: UUID, sessionId: String, clientTurnId: String) {
        if pendingClientTurnIds[serverId]?[sessionId] == clientTurnId {
            pendingClientTurnIds[serverId]?.removeValue(forKey: sessionId)
        }
    }

    func markClientTurnCompleted(serverId: UUID, sessionId: String, clientTurnId: String) {
        clearAppliedTurnProgress(serverId: serverId, sessionId: sessionId)
        completedClientTurnIds[serverId, default: [:]][sessionId, default: []].insert(clientTurnId)
    }

    func markStopReasonCompleted(serverId: UUID, sessionId: String) {
        clearAppliedTurnProgress(serverId: serverId, sessionId: sessionId)
        if let ctid = pendingClientTurnIds[serverId]?.removeValue(forKey: sessionId) {
            completedClientTurnIds[serverId, default: [:]][sessionId, default: []].insert(ctid)
        }
    }

    @discardableResult
    func beginInitialSyncIfNeeded(for serverId: UUID) -> Task<Void, Never>? {
        guard let service = serviceProvider(serverId) else { return nil }
        let serviceObjId = ObjectIdentifier(service)
        var state = syncStateByServer[serverId] ?? SlotSyncState()

        if state.activeSyncServiceObjectId == serviceObjId, let existing = state.initialSyncTask {
            return existing
        }
        if state.syncedServiceObjectId == serviceObjId && state.initialSyncTask == nil {
            return nil
        }

        state.initialSyncTask?.cancel()
        state.initialSyncGeneration &+= 1
        let gen = state.initialSyncGeneration
        state.activeSyncServiceObjectId = serviceObjId
        isSyncingByServer[serverId] = true
        if let serverVM = serverViewModelProvider(serverId),
           !serverVM.hasInitializedUnreadBaseline {
            suppressPreBaselineSyncUnread.insert(serverId)
        }
        bufferedLiveUpdatesDuringSync[serverId] = []
        bufferedTurnCompletedDuringSync[serverId] = []
        bufferedSessionStaleDuringSync[serverId] = []
        bufferedSessionDeletedDuringSync[serverId] = []
        syncStateByServer[serverId] = state

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performInitialSync(
                for: serverId,
                service: service,
                serviceObjId: serviceObjId,
                generation: gen
            )
        }
        syncStateByServer[serverId]?.initialSyncTask = task
        return task
    }

    private func performInitialSync(
        for serverId: UUID,
        service: ACPService,
        serviceObjId: ObjectIdentifier,
        generation: UInt64
    ) async {
        var succeeded = false
        defer {
            if syncStateByServer[serverId]?.initialSyncGeneration == generation {
                isSyncingByServer[serverId] = false
                syncStateByServer[serverId]?.initialSyncTask = nil
                syncStateByServer[serverId]?.activeSyncServiceObjectId = nil
                if succeeded {
                    syncStateByServer[serverId]?.syncedServiceObjectId = serviceObjId
                }
                bufferedLiveUpdatesDuringSync.removeValue(forKey: serverId)
                bufferedTurnCompletedDuringSync.removeValue(forKey: serverId)
                bufferedSessionStaleDuringSync.removeValue(forKey: serverId)
                bufferedSessionDeletedDuringSync.removeValue(forKey: serverId)
            }
        }

        do {
            let result = try await service.syncNonlocalSessions()
            guard !Task.isCancelled,
                  syncStateByServer[serverId]?.initialSyncGeneration == generation,
                  serviceProvider(serverId) === service else {
                return
            }

            // Strict gate (SD-1.2 / SD-2.4 / SC-AC-026): parseSyncResult == nil (empty {} or empty/whitespace instanceId)
            // MUST drop all 4 buffers, NEVER call markNonlocalSyncCompleted(), release 0 business RPCs, and lock slot!
            guard let syncResult = result else {
                dropBuffersAndLockIncompatible(
                    serverId: serverId,
                    reason: "Invalid nonlocal/sync response (missing instanceId)."
                )
                return
            }

            // Step 1: Reconcile authoritative snapshot
            let nonActiveSyncedTurns = reconcileSyncResult(syncResult, serverId: serverId)
            // Step 2: Close buffering gate
            isSyncingByServer[serverId] = false
            // Step 3: Replay 4 buffers in strictly fixed order
            let pendingUpdates = bufferedLiveUpdatesDuringSync.removeValue(forKey: serverId) ?? []
            let pendingCompletions = bufferedTurnCompletedDuringSync.removeValue(forKey: serverId) ?? []
            let pendingStale = bufferedSessionStaleDuringSync.removeValue(forKey: serverId) ?? []
            let pendingDeleted = bufferedSessionDeletedDuringSync.removeValue(forKey: serverId) ?? []

            for params in pendingUpdates {
                processLiveChatUpdate(params, serverId: serverId)
            }
            for completion in pendingCompletions {
                handleTurnCompleted(completion, serverId: serverId)
            }
            for staleNotice in pendingStale {
                handleSessionStale(staleNotice, serverId: serverId)
            }
            for deletedNotice in pendingDeleted {
                handleSessionDeleted(deletedNotice, serverId: serverId)
            }

            // Step 4: Finalize sync, unblock prune, and release business RPCs
            for finished in nonActiveSyncedTurns {
                clearAppliedTurnProgress(serverId: serverId, sessionId: finished.sessionId, turnId: finished.turnId)
            }
            succeeded = true
            if let serverVM = serverViewModelProvider(serverId) {
                serverVM.markNonlocalSyncCompleted()
                serverVM.reconcileDeferredPruneAfterSync()
            }
            onSyncSucceeded(serverId, service)
            onChange()
        } catch {
            guard !Task.isCancelled,
                  syncStateByServer[serverId]?.initialSyncGeneration == generation,
                  serviceProvider(serverId) === service else {
                return
            }
            if case ACPServiceError.rpc(_, let rpcError) = error {
                if BridgeServerValidator.isProtocolIncompatibilityRPCError(rpcError, allowAlreadyInitialized: false) {
                    dropBuffersAndLockIncompatible(
                        serverId: serverId,
                        reason: "Incompatible server (\(rpcError.code): \(rpcError.message))."
                    )
                    return
                }
                // Bridge transient error (-32000 / -32603 / etc.): do NOT lock as incompatible!
                reconcileFailedSyncTurns(
                    for: serverId,
                    errorMessage: "Sync unavailable (\(rpcError.message))."
                )
            } else {
                let isDisconnect: Bool = {
                    if case ACPServiceError.disconnected = error { return true }
                    if case ACPClientError.disconnected = error { return true }
                    if error is CancellationError { return true }
                    return false
                }()
                if !isDisconnect {
                    reconcileFailedSyncTurns(
                        for: serverId,
                        errorMessage: "Failed to sync session state: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func dropBuffersAndLockIncompatible(serverId: UUID, reason: String) {
        isSyncingByServer[serverId] = false
        bufferedLiveUpdatesDuringSync.removeValue(forKey: serverId)
        bufferedTurnCompletedDuringSync.removeValue(forKey: serverId)
        bufferedSessionStaleDuringSync.removeValue(forKey: serverId)
        bufferedSessionDeletedDuringSync.removeValue(forKey: serverId)
        onProtocolIncompatible(serverId, reason)
        onChange()
    }

    private func reconcileFailedSyncTurns(for serverId: UUID, errorMessage: String) {
        guard let serverVM = serverViewModelProvider(serverId) else { return }
        var failedIds = Set<String>()
        for (sid, vm) in serverVM.allSessionViewModels() where vm.isStreaming {
            failedIds.insert(sid)
        }
        if let pending = pendingClientTurnIds[serverId] {
            for sid in pending.keys {
                failedIds.insert(sid)
            }
        }
        pendingClientTurnIds.removeValue(forKey: serverId)
        for sid in failedIds {
            onFailPendingTurn(errorMessage, serverId, sid)
        }
    }

    // MARK: - Live / Buffered Event Routing

    func handleChatUpdate(_ params: ACP.Value?, serverId: UUID) {
        if isSyncingByServer[serverId] == true, let params {
            bufferedLiveUpdatesDuringSync[serverId, default: []].append(params)
            return
        }
        processLiveChatUpdate(params, serverId: serverId)
    }

    func processLiveChatUpdate(_ params: ACP.Value?, serverId: UUID) {
        guard let updateSessionId = ACPSessionUpdateHandler.sessionId(from: params),
              !updateSessionId.isEmpty else { return }

        if let incomingSeq = NonlocalSessionSyncParser.parseSeq(from: params),
           let progress = appliedTurnProgress[serverId]?[updateSessionId] {
            if let incomingTurnId = NonlocalSessionSyncParser.parseTurnId(from: params),
               incomingTurnId != progress.turnId {
                clearAppliedTurnProgress(serverId: serverId, sessionId: updateSessionId)
            } else {
                if incomingSeq <= progress.lastSeq {
                    return
                }
                appliedTurnProgress[serverId, default: [:]][updateSessionId] = (turnId: progress.turnId, lastSeq: incomingSeq)
            }
        }

        let targetVM = serverViewModelProvider(serverId)?.sessionViewModel(for: updateSessionId)
        targetVM?.handleSessionUpdateEvents(
            params,
            activeSessionId: updateSessionId,
            serverId: serverId
        )
    }

    func handleTurnCompleted(_ notification: NonlocalTurnCompletedNotification, serverId: UUID) {
        if isSyncingByServer[serverId] == true {
            bufferedTurnCompletedDuringSync[serverId, default: []].append(notification)
            return
        }
        if let activeInstance = currentBridgeInstanceId[serverId],
           notification.instanceId != activeInstance {
            return
        }
        clearAppliedTurnProgress(serverId: serverId, sessionId: notification.sessionId, turnId: notification.turnId)
        if completedSyncTurnIds[serverId]?[notification.sessionId]?.contains(notification.turnId) == true {
            return
        }

        guard let targetVM = serverViewModelProvider(serverId)?.sessionViewModel(for: notification.sessionId) else { return }
        completedSyncTurnIds[serverId, default: [:]][notification.sessionId, default: []].insert(notification.turnId)
        if let ctid = notification.clientTurnId {
            completedClientTurnIds[serverId, default: [:]][notification.sessionId, default: []].insert(ctid)
        }
        pendingClientTurnIds[serverId]?.removeValue(forKey: notification.sessionId)

        switch notification.status {
        case .completed, .active:
            targetVM.handleStopReason(
                notification.stopReason ?? "end_turn",
                serverId: serverId,
                sessionId: notification.sessionId
            )
        case .error:
            targetVM.handleNonlocalTurnError(
                notification.error?.message ?? "Turn failed on bridge",
                serverId: serverId,
                sessionId: notification.sessionId
            )
        }
    }

    func handleSessionStale(_ notification: NonlocalSessionStaleNotification, serverId: UUID) {
        if isSyncingByServer[serverId] == true {
            bufferedSessionStaleDuringSync[serverId, default: []].append(notification)
            return
        }
        if let activeInstance = currentBridgeInstanceId[serverId],
           notification.instanceId != activeInstance {
            return
        }
        guard !ServerViewModel.ignoredProbeSessionIds.contains(notification.sessionId),
              let serverVM = serverViewModelProvider(serverId) else {
            return
        }

        if let updatedAt = notification.updatedAt,
           let parsedDate = NonlocalSessionSnapshot(sessionId: notification.sessionId, lastActivityAt: updatedAt).lastActivityDate {
            serverVM.recordServerUpdatedAt(parsedDate, for: notification.sessionId)
        }

        clearAppliedTurnProgress(serverId: serverId, sessionId: notification.sessionId)
        connectionManagerProvider(serverId)?.clearSessionMaterialized(notification.sessionId)
        if serverVM.activeViewingSessionId == notification.sessionId {
            serverVM.reloadSession(notification.sessionId)
        }
    }

    func handleSessionDeleted(_ notice: NonlocalSessionDeletedNotification, serverId: UUID) {
        guard !notice.sessionId.isEmpty else { return }
        if isSyncingByServer[serverId] == true {
            bufferedSessionDeletedDuringSync[serverId, default: []].append(notice)
            return
        }
        onApplyImmediateSessionDeletion(notice.sessionId, serverId)
    }

    // MARK: - Reconciliation

    private func reconcileSyncResult(
        _ syncResult: NonlocalSyncResult,
        serverId: UUID
    ) -> [(sessionId: String, turnId: String)] {
        let previousInstanceId = currentBridgeInstanceId[serverId]
        let childRestarted = (previousInstanceId != nil && previousInstanceId != syncResult.instanceId)
        currentBridgeInstanceId[serverId] = syncResult.instanceId

        guard let serverVM = serverViewModelProvider(serverId) else {
            if selectedServerIdProvider() == serverId {
                connectionManagerProvider(serverId)?.resetSessionState()
            }
            return []
        }

        let suppressHistoricalUnread = (suppressPreBaselineSyncUnread.remove(serverId) != nil)
            || !serverVM.hasInitializedUnreadBaseline

        if childRestarted {
            serverVM.clearServerUpdatedAtTracking()
            appliedTurnProgress.removeValue(forKey: serverId)
            var staleStreamingIds = Set<String>()
            for (sid, vm) in serverVM.allSessionViewModels() where vm.isStreaming {
                staleStreamingIds.insert(sid)
            }
            if let pending = pendingClientTurnIds[serverId] {
                for sid in pending.keys {
                    staleStreamingIds.insert(sid)
                }
            }
            pendingClientTurnIds.removeValue(forKey: serverId)
            for sid in staleStreamingIds {
                onFailPendingTurn("Agent session restarted on bridge.", serverId, sid)
            }
        }

        var hadInMemorySessionIds = Set<String>()
        for (sid, vm) in serverVM.allSessionViewModels() where vm.hasInMemorySessionData || vm.isStreaming {
            hadInMemorySessionIds.insert(sid)
        }

        let staleSet = Set(syncResult.staleSessionIds)
        var syncedSessionIds = Set<String>()
        var recoveredTurnSessionIds = Set<String>()
        var nonActiveSyncedTurns: [(sessionId: String, turnId: String)] = []

        for snap in syncResult.sessions {
            guard !ServerViewModel.ignoredProbeSessionIds.contains(snap.sessionId) else {
                continue
            }
            syncedSessionIds.insert(snap.sessionId)
            if snap.latestTurn == nil, staleSet.contains(snap.sessionId), let activityDate = snap.lastActivityDate {
                serverVM.recordServerUpdatedAt(activityDate, for: snap.sessionId)
            }

            if !snap.configOptions.isEmpty {
                serverVM.cacheConfigOptions(snap.configOptions, for: snap.sessionId)
            }
            if let modes = snap.modes, !modes.isEmpty {
                serverVM.cacheModes(modes, for: snap.sessionId)
                onAvailableModesDiscovered(serverId, modes.availableModes)
            }
            if !snap.availableCommands.isEmpty {
                serverVM.cacheAvailableCommands(snap.availableCommands, for: snap.sessionId)
            }

            let pendingClientId = pendingClientTurnIds[serverId]?[snap.sessionId]

            if let pendingClientId, snap.latestTurn?.clientTurnId != pendingClientId {
                pendingClientTurnIds[serverId]?.removeValue(forKey: snap.sessionId)
                onFailPendingTurn(
                    "Message was not delivered before disconnect. Please try again.",
                    serverId,
                    snap.sessionId
                )
                continue
            }

            let hasExistingMemory = hadInMemorySessionIds.contains(snap.sessionId)
            guard snap.latestTurn != nil || hasExistingMemory else {
                continue
            }

            serverVM.markSessionSyncedProtected(snap.sessionId)
            _ = serverVM.rememberSession(snap.sessionId, cwd: nil, updateSessionCache: false)

            let existingVM = serverVM.existingSessionViewModel(for: snap.sessionId)
            let vm = serverVM.sessionViewModel(for: snap.sessionId)
            if !hasExistingMemory && (existingVM == nil || vm.chatMessages.isEmpty) {
                vm.loadChatState(serverId: serverId, sessionId: snap.sessionId, canLoadFromStorage: true)
            }

            if let modes = snap.modes, !modes.isEmpty {
                vm.setAvailableModes(modes.availableModes, currentModeId: modes.currentModeId)
                vm.cacheCurrentMode(serverId: serverId, sessionId: snap.sessionId)
            }
            if !snap.configOptions.isEmpty {
                vm.applySessionConfigOptions(snap.configOptions, serverId: serverId, sessionId: snap.sessionId)
            }
            if !snap.availableCommands.isEmpty {
                vm.handleAvailableCommandsUpdate(snap.availableCommands, serverId: serverId, sessionId: snap.sessionId)
            }
            if !vm.availableModes.isEmpty {
                serverVM.updateAvailableModesIfEmpty(vm.availableModes)
                if serverVM.selectedSessionId == snap.sessionId {
                    onAvailableModesDiscovered(serverId, serverVM.availableModes)
                }
            }

            guard let turn = snap.latestTurn else {
                vm.reconcilePendingPermissions(validRequestIds: [])
                clearAppliedTurnProgress(serverId: serverId, sessionId: snap.sessionId)
                continue
            }
            recoveredTurnSessionIds.insert(snap.sessionId)
            vm.reconcilePendingPermissions(validRequestIds: Set(turn.pendingPermissions.map(\.requestId)))

            let alreadyFinalizedSyncTurn = completedSyncTurnIds[serverId]?[snap.sessionId]?.contains(turn.turnId) == true
            let alreadyFinalizedClientTurn = turn.clientTurnId.flatMap {
                completedClientTurnIds[serverId]?[snap.sessionId]?.contains($0)
            } == true
            let prevProgress = appliedTurnProgress[serverId]?[snap.sessionId]
            let knownSeq = (prevProgress?.turnId == turn.turnId) ? prevProgress!.lastSeq : 0

            if turn.status != .active,
               pendingClientId == nil,
               !vm.isStreaming,
               turn.hasUnresolvedToolCalls != true,
               (alreadyFinalizedSyncTurn || alreadyFinalizedClientTurn || isTurnAlreadyFinalized(vm: vm, turn: turn)) {
                completedSyncTurnIds[serverId, default: [:]][snap.sessionId, default: []].insert(turn.turnId)
                if let ctid = turn.clientTurnId {
                    completedClientTurnIds[serverId, default: [:]][snap.sessionId, default: []].insert(ctid)
                }
                appliedTurnProgress[serverId, default: [:]][snap.sessionId] = (
                    turnId: turn.turnId,
                    lastSeq: max(knownSeq, turn.lastSeq)
                )
                nonActiveSyncedTurns.append((sessionId: snap.sessionId, turnId: turn.turnId))
                continue
            }

            let sortedEvents = turn.events.sorted { $0.seq < $1.seq }
            let eventsToApply: [NonlocalBufferedEvent]
            if knownSeq > 0 {
                eventsToApply = sortedEvents.filter { $0.seq > knownSeq }
            } else {
                eventsToApply = deduplicateInitialStreamingEvents(sortedEvents, vm: vm, truncated: turn.truncated)
            }

            for event in eventsToApply {
                vm.handleSessionUpdateEvents(event.params, activeSessionId: snap.sessionId, serverId: serverId)
            }

            appliedTurnProgress[serverId, default: [:]][snap.sessionId] = (
                turnId: turn.turnId,
                lastSeq: max(knownSeq, turn.lastSeq)
            )
            if turn.status != .active {
                nonActiveSyncedTurns.append((sessionId: snap.sessionId, turnId: turn.turnId))
            }

            for perm in turn.pendingPermissions where !vm.ownsPermissionRequest(perm.requestId) {
                vm.handlePermissionRequest(
                    ACP.AnyRequest(id: perm.requestId, method: "session/request_permission", params: perm.params)
                )
            }

            let isCovered = serverVM.isTurnCoveredBySeenWatermark(
                sessionId: snap.sessionId,
                serverActivityDate: snap.lastActivityDate
            )
            let notifyList = !(suppressHistoricalUnread || isCovered)

            switch turn.status {
            case .active:
                if let pendingClientId, turn.clientTurnId == pendingClientId {
                    vm.clearPendingPromptDelivery()
                }
                vm.markExplicitActiveTurn()
                vm.restoreStreamingState(from: vm.chatMessages)
                if let activityDate = snap.lastActivityDate {
                    serverVM.recordServerUpdatedAt(activityDate, for: snap.sessionId)
                }
            case .completed:
                if let pendingClientId, turn.clientTurnId == pendingClientId {
                    vm.clearPendingPromptDelivery()
                }
                pendingClientTurnIds[serverId]?.removeValue(forKey: snap.sessionId)
                completedSyncTurnIds[serverId, default: [:]][snap.sessionId, default: []].insert(turn.turnId)
                if let ctid = turn.clientTurnId {
                    completedClientTurnIds[serverId, default: [:]][snap.sessionId, default: []].insert(ctid)
                }
                vm.handleStopReason(
                    turn.stopReason ?? "end_turn",
                    hasUnresolvedToolCalls: turn.hasUnresolvedToolCalls ?? false,
                    notifyList: notifyList,
                    serverId: serverId,
                    sessionId: snap.sessionId
                )
                if let activityDate = snap.lastActivityDate, !notifyList {
                    serverVM.recordServerUpdatedAt(activityDate, for: snap.sessionId)
                }
            case .error:
                pendingClientTurnIds[serverId]?.removeValue(forKey: snap.sessionId)
                completedSyncTurnIds[serverId, default: [:]][snap.sessionId, default: []].insert(turn.turnId)
                if let ctid = turn.clientTurnId {
                    completedClientTurnIds[serverId, default: [:]][snap.sessionId, default: []].insert(ctid)
                }
                vm.handleNonlocalTurnError(
                    turn.error?.message ?? "Turn failed on bridge",
                    notifyList: notifyList,
                    serverId: serverId,
                    sessionId: snap.sessionId
                )
                if let activityDate = snap.lastActivityDate, !notifyList {
                    serverVM.recordServerUpdatedAt(activityDate, for: snap.sessionId)
                }
            }
        }

        if let slotManager = connectionManagerProvider(serverId) {
            slotManager.resetSessionState()
            let materializedSet = Set(syncResult.materializedSessionIds)
            for (sid, vm) in serverVM.allSessionViewModels() where vm.hasInMemorySessionData || vm.isStreaming {
                if (hadInMemorySessionIds.contains(sid) || recoveredTurnSessionIds.contains(sid)),
                   materializedSet.contains(sid),
                   !staleSet.contains(sid) {
                    slotManager.markSessionMaterialized(sid)
                }
            }
        }
        if let activeViewingId = serverVM.activeViewingSessionId,
           !activeViewingId.isEmpty,
           staleSet.contains(activeViewingId) {
            serverVM.reloadSession(activeViewingId)
        }

        if let remainingPending = pendingClientTurnIds[serverId] {
            for sid in remainingPending.keys where !syncedSessionIds.contains(sid) {
                pendingClientTurnIds[serverId]?.removeValue(forKey: sid)
                onFailPendingTurn(
                    "Message was not delivered before disconnect. Please try again.",
                    serverId,
                    sid
                )
            }
        }
        return nonActiveSyncedTurns
    }

    private func isTurnAlreadyFinalized(vm: ACPSessionViewModel, turn: NonlocalTurnSnapshot) -> Bool {
        guard let lastMsg = vm.chatMessages.last else { return false }
        if lastMsg.role == .user { return false }
        if turn.status == .error && lastMsg.role == .system && lastMsg.isError {
            return true
        }
        guard lastMsg.role == .assistant, !lastMsg.isStreaming else { return false }
        let chunkText = turn.events.compactMap { event -> String? in
            guard let update = event.params.objectValue?["update"]?.objectValue,
                  update["sessionUpdate"]?.stringValue == "agent_message_chunk",
                  let content = update["content"]?.objectValue,
                  content["type"]?.stringValue == "text" else {
                return nil
            }
            return content["text"]?.stringValue
        }.joined()
        if chunkText.isEmpty {
            return !lastMsg.content.isEmpty || !lastMsg.segments.isEmpty
        }
        return lastMsg.content.hasSuffix(chunkText)
            || lastMsg.segments.contains { $0.kind == .message && $0.text == chunkText }
    }

    private func deduplicateInitialStreamingEvents(
        _ sortedEvents: [NonlocalBufferedEvent],
        vm: ACPSessionViewModel,
        truncated: Bool
    ) -> [NonlocalBufferedEvent] {
        guard !truncated,
              vm.isStreaming,
              let streamingId = vm.currentStreamingAssistantMessageId(),
              let msg = vm.chatMessages.first(where: { $0.id == streamingId }) else {
            return sortedEvents
        }
        let existingMessageText = msg.segments
            .filter { $0.kind == .message }
            .map(\.text)
            .joined()
        guard !existingMessageText.isEmpty else { return sortedEvents }

        var accumulated = ""
        var skipCount = 0
        for (idx, event) in sortedEvents.enumerated() {
            guard let update = event.params.objectValue?["update"]?.objectValue,
                  let updateType = update["sessionUpdate"]?.stringValue,
                  updateType == "agent_message_chunk",
                  let chunk = update["content"]?.objectValue?["text"]?.stringValue else {
                break
            }
            accumulated += chunk
            if existingMessageText == accumulated {
                skipCount = idx + 1
                break
            }
            if !existingMessageText.hasPrefix(accumulated) {
                break
            }
        }
        return Array(sortedEvents.dropFirst(skipCount))
    }
}
