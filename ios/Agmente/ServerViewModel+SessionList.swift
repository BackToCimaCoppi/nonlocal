import Foundation
import ACPClient
import ACP

extension ServerViewModel {
    // MARK: - Session List Management

    /// Check if this server supports session/list capability.
    func sessionListSupportFlag() -> Bool? {
        agentInfo?.capabilities.listSessions
    }

    /// Check if session list can be fetched.
    func canFetchSessionList(force: Bool = false) -> Bool {
        // Default to true - try server first, fall back to cache if it fails
        // The response handler will gracefully handle failures
        sessionListSupportFlag() ?? true
    }

    /// Sort session summaries by timestamp.
    func sortSessionSummaries(_ summaries: [SessionSummary]) -> [SessionSummary] {
        var bestById: [String: SessionSummary] = [:]
        bestById.reserveCapacity(summaries.count)

        for summary in summaries {
            if let existing = bestById[summary.id] {
                switch (existing.updatedAt, summary.updatedAt) {
                case let (existingDate?, newDate?):
                    if newDate > existingDate {
                        bestById[summary.id] = summary
                    }
                case (nil, _?):
                    bestById[summary.id] = summary
                default:
                    break
                }
            } else {
                bestById[summary.id] = summary
            }
        }

        return bestById.values.sorted(by: SessionSummary.compareByUpdatedAtDesc)
    }

    func mergedServerSessionSummaries(
        _ serverSessions: [SessionSummary],
        fetchGeneration: UInt64? = nil
    ) -> [SessionSummary] {
        var existingById: [String: SessionSummary] = [:]
        for existing in sessionSummaries {
            existingById[existing.id] = existing
        }

        var merged: [SessionSummary] = []
        merged.reserveCapacity(serverSessions.count + pendingLocalSessions.count + recentlyCreatedSessionGenerations.count)
        var seenIds: Set<String> = []

        for summary in serverSessions {
            if let deletedGen = recentlyDeletedSessionGenerations[summary.id],
               (fetchGeneration ?? listFetchGeneration) <= deletedGen {
                continue
            }
            seenIds.insert(summary.id)
            var finalUpdatedAt = summary.updatedAt
            if let localPin = localPinnedTimestampsBySessionId[summary.id] {
                if let srvDate = summary.updatedAt, srvDate >= localPin {
                    localPinnedTimestampsBySessionId.removeValue(forKey: summary.id)
                } else if isSessionRunning(summary.id) || isSessionWaitingForUser(summary.id) || isSessionUnread(summary.id) {
                    finalUpdatedAt = localPin
                }
            }
            merged.append(SessionSummary(
                id: summary.id,
                title: summary.title,
                cwd: summary.cwd,
                updatedAt: finalUpdatedAt
            ))
        }

        for pendingId in pendingLocalSessions where !seenIds.contains(pendingId) {
            if let existingPending = existingById[pendingId] {
                seenIds.insert(pendingId)
                merged.append(existingPending)
            }
        }
        // Preserve recently created sessions against older in-flight session/list responses (AC-203).
        for (recentId, createdGen) in recentlyCreatedSessionGenerations where !seenIds.contains(recentId) {
            if let fetchGen = fetchGeneration, fetchGen > createdGen {
                continue
            }
            if let existingRecent = existingById[recentId] {
                seenIds.insert(recentId)
                merged.append(existingRecent)
            }
        }
        return merged
    }

    /// Set session summaries for this server.
    func setSessionSummaries(_ summaries: [SessionSummary]) {
        sessionSummaries = sortSessionSummaries(summaries)
    }

    static func fetchCleanStoredSessions(from storage: SessionStorage, serverId: UUID) -> [StoredSessionInfo] {
        let rawStoredSessions = storage.fetchSessions(forServerId: serverId)
        for probe in rawStoredSessions where ignoredProbeSessionIds.contains(probe.sessionId) {
            storage.deleteSession(sessionId: probe.sessionId, forServerId: serverId)
        }
        return rawStoredSessions.filter { !ignoredProbeSessionIds.contains($0.sessionId) }
    }

    /// Load cached sessions for this server while preserving unpersisted local draft sessions (`pendingLocalSessions`, SD-2.7).
    func loadCachedSessions() {
        if Self.ignoredProbeSessionIds.contains(sessionCache) {
            sessionCache = ""
        }
        let preservedPending = sessionSummaries.filter { pendingLocalSessions.contains($0.id) }
        var loaded: [SessionSummary] = []

        if let storage = storage {
            let storedSessions = Self.fetchCleanStoredSessions(from: storage, serverId: id)
            if !storedSessions.isEmpty {
                loaded = storedSessions.map { $0.toSessionSummary() }
                appendClosure("Loaded \(storedSessions.count) persisted session(s) from storage")
            } else if !sessionCache.isEmpty {
                loaded = [SessionSummary(id: sessionCache, title: nil)]
            }
        } else if !sessionCache.isEmpty {
            loaded = [SessionSummary(id: sessionCache, title: nil)]
        }

        if !preservedPending.isEmpty {
            let loadedIds = Set(loaded.map(\.id))
            for draft in preservedPending where !loadedIds.contains(draft.id) {
                loaded.insert(draft, at: 0)
            }
        }
        sessionSummaries = sortSessionSummaries(loaded)
    }

    /// Persist sessions to storage.
    func persistSessionsToStorage(
        allowPrune: Bool = false,
        fetchGeneration: UInt64? = nil,
        fetchedIds: Set<String>? = nil
    ) {
        let sessions = sessionSummaries.filter { !pendingLocalSessions.contains($0.id) }
        let listSupported = (sessionListSupportFlag() == true)
        guard !sessions.isEmpty || listSupported else { return }

        for session in sessions {
            let storedInfo = StoredSessionInfo(
                sessionId: session.id,
                title: session.title,
                cwd: session.cwd,
                updatedAt: session.updatedAt
            )
            storage?.saveSession(storedInfo, forServerId: id, clearTitleWhenNil: listSupported)
        }

        // For agents that support `session/list`, prune stale cache entries only on complete successful lists
        if listSupported && allowPrune {
            let effectiveFetchedIds = fetchedIds ?? Set(sessions.map(\.id))
            let keep = computePruneKeepSet(
                fetchedIds: effectiveFetchedIds,
                fetchGeneration: fetchGeneration
            )
            pruneUnkeptSessions(keeping: keep)
        }
    }

    func activeProtectedSessionIds() -> Set<String> {
        var protected = inFlightSessionLoads
        for (sid, vm) in sessionViewModels {
            if vm.isStreaming || vm.isActivelyRunning || vm.hasPendingUserAction || vm.activeReplayMode {
                protected.insert(sid)
            }
        }
        return protected
    }

    func computePruneKeepSet(
        fetchedIds: Set<String>,
        fetchGeneration: UInt64?
    ) -> Set<String> {
        var keep = fetchedIds
        keep.formUnion(pendingLocalSessions)
        keep.formUnion(creatingSessionTasks.keys)

        let activeProtected = activeProtectedSessionIds()
        keep.formUnion(activeProtected)

        // Protect recently created sessions against older in-flight session/list responses.
        // Only evict from recentlyCreated once a complete list initiated AFTER creation omits it.
        var remainingRecent: [String: UInt64] = [:]
        for (sid, createdGen) in recentlyCreatedSessionGenerations {
            if fetchedIds.contains(sid) {
                // Already visible on server; no longer needs creation grace protection.
                continue
            }
            if let fetchGen = fetchGeneration, fetchGen > createdGen {
                // A complete list started strictly after session/new omits this session -> allow prune.
                continue
            }
            remainingRecent[sid] = createdGen
            keep.insert(sid)
        }
        recentlyCreatedSessionGenerations = remainingRecent
        if let fetchGen = fetchGeneration {
            recentlyDeletedSessionGenerations = recentlyDeletedSessionGenerations.filter { fetchGen <= $0.value }
        }

        // syncedProtectedSessionIds (e.g. completed S1 from nonlocal/sync):
        // Preserve on empty concurrent list (guards SessionIsolationTests#L1082).
        // Evict when a NON-EMPTY complete list omits it and it is not active/recent.
        if fetchedIds.isEmpty {
            keep.formUnion(syncedProtectedSessionIds)
        } else {
            var remainingSynced: Set<String> = []
            for sid in syncedProtectedSessionIds {
                if fetchedIds.contains(sid) || activeProtected.contains(sid) || remainingRecent[sid] != nil {
                    remainingSynced.insert(sid)
                    keep.insert(sid)
                }
            }
            syncedProtectedSessionIds = remainingSynced
        }

        // Standard third-party ACP without nonlocal/sync: preserve in-memory VMs on empty list.
        if !hasCompletedNonlocalSync && fetchedIds.isEmpty {
            keep.formUnion(sessionViewModels.keys)
        }

        return keep
    }

    func pruneUnkeptSessions(keeping keep: Set<String>) {
        let removedSummaryIds = sessionSummaries.map(\.id).filter { !keep.contains($0) }
        let removedVMIds = sessionViewModels.keys.filter { !keep.contains($0) }
        let allRemoved = Set(removedSummaryIds).union(removedVMIds)

        if !removedSummaryIds.isEmpty {
            let filtered = sessionSummaries.filter { keep.contains($0.id) }
            setSessionSummaries(filtered)
        }

        var activePrunedId: String?
        for sid in allRemoved {
            removeSessionViewModel(for: sid)
            cacheDelegate?.clearCache(for: id, sessionId: sid)
            sessionConfigOptionsCache.removeValue(forKey: sid)
            sessionModesCache.removeValue(forKey: sid)
            sessionCommandsCache.removeValue(forKey: sid)
            if lastLoadedSession == sid {
                lastLoadedSession = nil
            }
            if pendingSessionLoad == sid {
                pendingSessionLoad = nil
            }
            inFlightSessionLoads.remove(sid)
            pendingReloadSessions.remove(sid)
            openSessionRequestTokens.removeValue(forKey: sid)
            connectionManager.clearSessionMaterialized(sid)
            localPinnedTimestampsBySessionId.removeValue(forKey: sid)
            sessionsAwaitingServerTimestamp.remove(sid)
            manuallyCancelledSessionIds.remove(sid)
            lastKnownServerUpdatedAt.removeValue(forKey: sid)
            if sessionCache == sid {
                sessionCache = ""
            }
            if self.sessionId == sid {
                self.sessionId = ""
                self.selectedSessionId = nil
                activePrunedId = sid
            }
        }

        _ = storage?.pruneSessions(forServerId: id, keeping: keep)
        unreadTracker.pruneSessions(keeping: keep)

        if let activePrunedId {
            onActiveSessionPruned?(activePrunedId)
        }
    }

    func markSessionSyncedProtected(_ sessionId: String) {
        guard !sessionId.isEmpty else { return }
        syncedProtectedSessionIds.insert(sessionId)
    }

    func markNonlocalSyncCompleted() {
        hasCompletedNonlocalSync = true
    }

    func resetNonlocalSyncProtectionState() {
        hasCompletedNonlocalSync = false
        deferredCompleteSessionList = nil
    }

    func reconcileDeferredPruneAfterSync() {
        guard let deferred = deferredCompleteSessionList else { return }
        deferredCompleteSessionList = nil
        guard sessionListSupportFlag() == true else { return }
        let fetchedIds = Set(deferred.sessions.map(\.id))
        let keep = computePruneKeepSet(
            fetchedIds: fetchedIds,
            fetchGeneration: deferred.generation
        )
        pruneUnkeptSessions(keeping: keep)
    }

    func activeAndPendingSessionIds() -> Set<String> {
        var ids = activeProtectedSessionIds()
        ids.formUnion(pendingLocalSessions)
        ids.formUnion(creatingSessionTasks.keys)
        ids.formUnion(recentlyCreatedSessionGenerations.keys)
        ids.formUnion(syncedProtectedSessionIds)
        if !hasCompletedNonlocalSync {
            ids.formUnion(sessionViewModels.keys)
        }
        return ids
    }

    func isPendingSessionId(_ targetSessionId: String) -> Bool {
        pendingLocalSessions.contains(targetSessionId)
    }

    /// Update session timestamp.
    func bumpSessionTimestamp(sessionId: String, cwd: String? = nil, timestamp: Date = Date()) {
        let resolvedCwd = sessionSummaries.first(where: { $0.id == sessionId })?.cwd ?? cwd ?? resolvedWorkingDirectory

        if let index = sessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            let existing = sessionSummaries[index]
            let updated = SessionSummary(id: existing.id, title: existing.title, cwd: existing.cwd ?? resolvedCwd, updatedAt: timestamp)
            sessionSummaries.remove(at: index)
            sessionSummaries.insert(updated, at: 0)
        } else {
            sessionSummaries.insert(SessionSummary(id: sessionId, title: nil, cwd: resolvedCwd, updatedAt: timestamp), at: 0)
        }

        localPinnedTimestampsBySessionId[sessionId] = timestamp
        setSessionSummaries(sessionSummaries)

        storage?.updateSession(
            sessionId: sessionId,
            forServerId: id,
            title: nil,
            touchUpdatedAt: true,
            updatedAt: timestamp
        )
    }

    /// Update session title from first prompt for the specified session.
    func updateSessionTitleIfNeeded(with text: String, forSessionId targetSessionId: String? = nil) {
        let effectiveSessionId = targetSessionId ?? sessionId
        guard !effectiveSessionId.isEmpty else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let index = sessionSummaries.firstIndex(where: { $0.id == effectiveSessionId }),
              sessionSummaries[index].title == nil else { return }

        let maxLength = 30
        var title = trimmed
        if title.count > maxLength {
            title = String(title.prefix(maxLength)) + "…"
        }

        let existingSession = sessionSummaries[index]
        sessionSummaries[index] = SessionSummary(id: effectiveSessionId, title: title, cwd: existingSession.cwd, updatedAt: existingSession.updatedAt)
        setSessionSummaries(sessionSummaries)

        let touchLocalTimestamp = (sessionListSupportFlag() == false)
        storage?.updateSession(sessionId: effectiveSessionId, forServerId: id, title: title, touchUpdatedAt: touchLocalTimestamp)
    }

    /// Fail a pending turn with an error message scoped to the originating session.
    func failPendingTurn(_ message: String, forSessionId targetSessionId: String? = nil) {
        let resolvedId = (targetSessionId?.isEmpty == false) ? targetSessionId! : (selectedSessionId ?? sessionId)
        let resolvedVM: ACPSessionViewModel? = {
            if let targetSessionId, !targetSessionId.isEmpty {
                return sessionViewModel(for: targetSessionId)
            }
            return currentSessionViewModel
        }()
        resolvedVM?.abandonStreamingMessage()
        let errorMsgId = resolvedVM?.addSystemErrorMessage(message)
        resolvedVM?.markPendingPromptDeliveryFailed(errorMessageId: errorMsgId)
        if !resolvedId.isEmpty, sessionSummaries.contains(where: { $0.id == resolvedId }) {
            handleTurnPausedOrEnded(sessionId: resolvedId, reasonCancelled: false, isError: true, requiresUserAction: false)
        }
    }

    func sendPermissionResponse(requestId: ACP.ID, optionId: String) {
        if let ownerEntry = sessionViewModels.first(where: { $0.value.ownsPermissionRequest(requestId) }) {
            ownerEntry.value.sendPermissionResponse(requestId: requestId, optionId: optionId)
            sessionsAwaitingServerTimestamp.insert(ownerEntry.key)
            unreadTracker.recordPendingServerTimeAbsorption(ownerEntry.key, forServerId: id, storage: storage)
            objectWillChange.send()
            return
        }
        currentSessionViewModel?.sendPermissionResponse(requestId: requestId, optionId: optionId)
    }

    /// Format prompt error for display.
    func formatPromptError(_ error: Error) -> String {
        if let serviceError = error as? ACPServiceError, let message = serviceError.rpcMessage {
            return message
        }
        return error.localizedDescription
    }

    /// Finalize pending session creation after session/new response.
    func finalizePendingSessionCreation(response: ACP.AnyResponse, placeholderId: String, fallbackCwd: String) {
        // Guard against duplicate finalization
        let isPending = pendingLocalSessions.contains(placeholderId)
        guard isPending else {
            return
        }

        pendingLocalSessionCwds.removeValue(forKey: placeholderId)

        // Parse session/new response
        let parsed = ACPSessionResponseParser.parseSessionNew(
            result: response.resultValue,
            fallbackCwd: pendingNewSessionCwd ?? fallbackCwd
        )

        // Extract session ID from response
        let resolvedId: String
        if let serverSessionId = parsed?.sessionId, !serverSessionId.isEmpty {
            resolvedId = serverSessionId
        } else {
            // Fallback extraction
            let directSessionId = response.resultValue?.objectValue?["sessionId"]?.stringValue
                ?? response.resultValue?.objectValue?["session"]?.stringValue
                ?? response.resultValue?.objectValue?["id"]?.stringValue

            if let directId = directSessionId, !directId.isEmpty {
                resolvedId = directId
            } else {
                resolvedId = placeholderId
            }
        }

        let resolvedCwd = parsed?.cwd ?? fallbackCwd
        let modesInfo = parsed?.modes
        let parsedConfigOptions = parsed?.configOptions ?? []

        // Check if this session introduced a new working directory before removing it from pending
        let newCwdAdded = pendingLocalSessionNewCwds[placeholderId] ?? false

        pendingLocalSessions.remove(placeholderId)
        pendingNewSessionCwd = nil
        pendingNewSessionPlaceholderId = nil

        // Record placeholder → resolved ID mapping
        if resolvedId != placeholderId {
            if resolvedSessionIds[placeholderId] == nil {
                resolvedSessionIds[placeholderId] = resolvedId
            }
        }

        // Migrate caches if ID changed (merges if resolvedId VM already exists)
        if resolvedId != placeholderId {
            migrateSessionRuntimeState(from: placeholderId, to: resolvedId)
        }

        let resolvedVM = sessionViewModel(for: resolvedId)
        if !parsedConfigOptions.isEmpty {
            cacheConfigOptions(parsedConfigOptions, for: resolvedId)
            resolvedVM.applySessionConfigOptions(parsedConfigOptions, serverId: id, sessionId: resolvedId)
        }

        // A successful session/new yields a live session that can accept prompts immediately.
        connectionManager.markSessionMaterialized(resolvedId)
        recentlyCreatedSessionGenerations[resolvedId] = listFetchGeneration

        let shouldActivateForeground = (selectedSessionId == nil
            || selectedSessionId?.isEmpty == true
            || selectedSessionId == placeholderId
            || selectedSessionId == resolvedId)

        if shouldActivateForeground {
            lastLoadedSession = resolvedId
            setActiveSession(resolvedId, cwd: resolvedCwd, modes: modesInfo)
            resolvedVM.saveChatState()
        } else {
            resolvedVM.setSessionContext(serverId: id, sessionId: resolvedId)
            if let modes = modesInfo {
                cacheModes(modes, for: resolvedId)
                resolvedVM.setAvailableModes(modes.availableModes, currentModeId: modes.currentModeId)
                resolvedVM.cacheCurrentMode(serverId: id, sessionId: resolvedId)
            }
            _ = rememberSession(resolvedId, cwd: resolvedCwd, updateSessionCache: false)
            resolvedVM.saveChatState()
        }

        if resolvedId != placeholderId {
            unreadTracker.migrateSession(from: placeholderId, to: resolvedId, serverId: id, storage: storage)
            if activeViewingSessionId == placeholderId {
                activeViewingSessionId = resolvedId
            }
            if sessionsAwaitingServerTimestamp.remove(placeholderId) != nil {
                sessionsAwaitingServerTimestamp.insert(resolvedId)
            }
            if let pin = localPinnedTimestampsBySessionId.removeValue(forKey: placeholderId) {
                localPinnedTimestampsBySessionId[resolvedId] = pin
            }
            if manuallyCancelledSessionIds.remove(placeholderId) != nil {
                manuallyCancelledSessionIds.insert(resolvedId)
            }
            removePlaceholderSession(placeholderId, replacedBy: resolvedId)
        }
        sessionsAwaitingServerTimestamp.insert(resolvedId)
        unreadTracker.recordPendingServerTimeAbsorption(resolvedId, forServerId: id, storage: storage)

        // Trigger session refetch if a new working directory was added during creation
        refetchSessionsIfNeeded(newCwdAdded: newCwdAdded)
    }

    /// Remove placeholder session after resolution.
    func removePlaceholderSession(_ placeholderId: String, replacedBy resolvedId: String?) {
        let wasActivePlaceholder = (sessionId == placeholderId) || (selectedSessionId == placeholderId)

        if let resolvedId, resolvedId != placeholderId {
            // Delete placeholder session from storage if it exists (edge case protection)
            storage?.deleteSession(sessionId: placeholderId, forServerId: id)
        }

        pendingLocalSessions.remove(placeholderId)
        pendingLocalSessionCwds.removeValue(forKey: placeholderId)
        pendingLocalSessionNewCwds.removeValue(forKey: placeholderId)

        if sessionCache == placeholderId {
            sessionCache = resolvedId ?? ""
        }
        if pendingSessionLoad == placeholderId {
            pendingSessionLoad = nil
        }

        if wasActivePlaceholder, resolvedId == nil {
            sessionId = ""
            selectedSessionId = nil
        }

        sessionSummaries.removeAll { $0.id == placeholderId }
        setSessionSummaries(sessionSummaries)

        cacheDelegate?.clearCache(for: id, sessionId: placeholderId)
        currentSessionViewModel?.removeCommands(for: id, sessionId: placeholderId)
        removeSessionViewModel(for: placeholderId)
    }

    private func migrateSessionRuntimeState(from placeholderId: String, to resolvedId: String) {
        guard placeholderId != resolvedId else { return }

        cacheDelegate?.migrateCache(serverId: id, from: placeholderId, to: resolvedId)
        migrateSessionStorageState(from: placeholderId, to: resolvedId)
        migrateSessionViewModel(from: placeholderId, to: resolvedId)

        if let viewModel = sessionViewModels[resolvedId] {
            viewModel.migrateSessionCommandsCache(for: id, from: placeholderId, to: resolvedId)
            viewModel.migrateSessionModeCache(for: id, from: placeholderId, to: resolvedId)
        }
    }

    func migrateSessionStorageState(from placeholderId: String, to resolvedId: String) {
        guard let storage else { return }

        if let placeholderSession = storage.fetchSessions(forServerId: id).first(where: { $0.sessionId == placeholderId }) {
            storage.saveSession(
                StoredSessionInfo(
                    sessionId: resolvedId,
                    title: placeholderSession.title,
                    cwd: placeholderSession.cwd,
                    updatedAt: placeholderSession.updatedAt
                ),
                forServerId: id
            )
        } else {
            storage.saveSession(
                StoredSessionInfo(sessionId: resolvedId, title: nil, cwd: nil, updatedAt: nil),
                forServerId: id
            )
        }

        let messages = storage.fetchMessages(forSessionId: placeholderId, serverId: id)
        if !messages.isEmpty {
            storage.saveMessages(messages, forSessionId: resolvedId, serverId: id)
        }
    }
}
