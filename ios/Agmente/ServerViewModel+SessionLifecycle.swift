import Foundation
import ACPClient
import ACP

extension ServerViewModel {
    // MARK: - Connection Management

    // TODO: Move connection methods from AppViewModel
    // - connect()
    // - disconnect()
    // - initializeAndWait()
    // - Message handling

    // MARK: - Session Management

    /// Set the active session and load its state.
    func setActiveSession(_ id: String, cwd: String? = nil, modes: ACPModesInfo? = nil) {
        guard !id.isEmpty else { return }
        let isNew = sessionId != id
        sessionId = id
        selectedSessionId = id
        let viewModel = sessionViewModel(for: id)

        // Load chat state through session's view model
        if isNew {
            if hasInMemorySessionState(for: id) {
                viewModel.setSessionContext(serverId: self.id, sessionId: id)
            } else {
                viewModel.loadChatState(
                    serverId: self.id,
                    sessionId: id,
                    canLoadFromStorage: true
                )
                if let cachedConfigOptions = sessionConfigOptionsCache[id], !cachedConfigOptions.isEmpty {
                    viewModel.applySessionConfigOptions(cachedConfigOptions, serverId: self.id, sessionId: id)
                }
            }
        } else {
            // Just update context for existing session
            viewModel.setSessionContext(serverId: self.id, sessionId: id)
            if viewModel.sessionConfigOptions.isEmpty,
               let cachedConfigOptions = sessionConfigOptionsCache[id],
               !cachedConfigOptions.isEmpty {
                viewModel.applySessionConfigOptions(cachedConfigOptions, serverId: self.id, sessionId: id)
            }
        }

        // Restore or update mode state
        if let modes = modes {
            if !modes.availableModes.isEmpty {
                availableModes = modes.availableModes
                defaultModeId = modes.currentModeId
                sessionModesCache[id] = modes
            }
            viewModel.setAvailableModes(modes.availableModes, currentModeId: modes.currentModeId)
            viewModel.cacheCurrentMode(serverId: self.id, sessionId: id)
        } else {
            let cachedSessionModes = sessionModesCache[id]
            let fallbackModes = !viewModel.availableModes.isEmpty
                ? viewModel.availableModes
                : (cachedSessionModes?.availableModes.isEmpty == false ? cachedSessionModes!.availableModes : availableModes)
            if !fallbackModes.isEmpty, availableModes.isEmpty {
                availableModes = fallbackModes
            }

            if let cachedMode = viewModel.cachedMode(for: self.id, sessionId: id) {
                viewModel.setCurrentModeId(cachedMode)
                if !fallbackModes.isEmpty {
                    viewModel.setAvailableModes(fallbackModes, currentModeId: cachedMode)
                }
            } else if let cachedSessionModes, !cachedSessionModes.availableModes.isEmpty {
                viewModel.setAvailableModes(
                    fallbackModes,
                    currentModeId: viewModel.currentModeId ?? cachedSessionModes.currentModeId
                )
                viewModel.cacheCurrentMode(serverId: self.id, sessionId: id)
            } else if let defaultMode = defaultModeId, viewModel.currentModeId == nil {
                viewModel.setCurrentModeId(defaultMode)
                if !fallbackModes.isEmpty {
                    viewModel.setAvailableModes(fallbackModes, currentModeId: defaultMode)
                }
            } else if viewModel.availableModes.isEmpty, !fallbackModes.isEmpty {
                viewModel.setAvailableModes(fallbackModes, currentModeId: viewModel.currentModeId)
            }
        }

        viewModel.restoreAvailableCommands(for: self.id, sessionId: id, isNew: isNew)
        if viewModel.availableCommands.isEmpty,
           let cachedCommands = sessionCommandsCache[id],
           !cachedCommands.isEmpty {
            viewModel.handleAvailableCommandsUpdate(cachedCommands, serverId: self.id, sessionId: id)
        }

        if pendingLocalSessions.contains(id) {
            pendingSessionLoad = nil
        } else if canLoadSession() && connectionState != .connected {
            pendingSessionLoad = id
        } else {
            pendingSessionLoad = nil
        }

        let newCwdAdded = rememberSession(id, cwd: cwd)
        viewModel.saveChatState(persistToStorage: false)
        if isNew {
            appendClosure("Session ID: \(id)")
        }
        refetchSessionsIfNeeded(newCwdAdded: newCwdAdded)
    }

    /// Set the default mode ID from initialize response, to be applied to new sessions.
    func setDefaultModeId(_ modeId: String?) {
        defaultModeId = modeId
    }

    func recordServerUpdatedAt(_ date: Date, for sessionId: String) {
        guard !sessionId.isEmpty else { return }
        if let existing = lastKnownServerUpdatedAt[sessionId], existing >= date {
            // Still pass through unreadTracker in case this arrived during stale notification with newer date vs seen watermark.
        } else {
            lastKnownServerUpdatedAt[sessionId] = date
        }

        let isRunningOrWaiting = isSessionRunning(sessionId) || isSessionWaitingForUser(sessionId)
        if !isRunningOrWaiting {
            sessionsAwaitingServerTimestamp.remove(sessionId)
        }
        if let localPin = localPinnedTimestampsBySessionId[sessionId], date >= localPin {
            localPinnedTimestampsBySessionId.removeValue(forKey: sessionId)
        }
        if let index = sessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            let existing = sessionSummaries[index]
            if existing.updatedAt == nil || date > existing.updatedAt! {
                sessionSummaries[index] = SessionSummary(
                    id: existing.id,
                    title: existing.title,
                    cwd: existing.cwd,
                    updatedAt: date
                )
                setSessionSummaries(sessionSummaries)
            }
        }
        unreadTracker.recordServerUpdatedAt(
            date,
            for: sessionId,
            activeViewingSessionId: activeViewingSessionId,
            isRunning: isRunningOrWaiting,
            serverId: id,
            storage: storage
        )
        objectWillChange.send()
    }

    func clearServerUpdatedAtTracking() {
        lastKnownServerUpdatedAt.removeAll()
    }

    /// Force-reloads an idle materialized session from the server (used for background updates or manual refresh).
    func reloadSession(_ sessionIdToReload: String) {
        guard !sessionIdToReload.isEmpty,
              !pendingLocalSessions.contains(sessionIdToReload),
              canLoadSession(),
              connectionState == .connected,
              isInitialized else {
            return
        }
        if let vm = sessionViewModels[sessionIdToReload], vm.isStreaming {
            return
        }
        connectionManager.clearSessionMaterialized(sessionIdToReload)
        sendLoadSession(sessionIdToReload)
    }

    /// Load a session from the server using session/load.
    func sendLoadSession(_ sessionIdToLoad: String, cwd: String? = nil) {
        guard let service = getServiceClosure() else {
            appendClosure("Not connected")
            return
        }
        guard canLoadSession() else {
            appendClosure("Agent does not support session/load; showing cached messages only")
            pendingSessionLoad = nil
            return
        }
        if inFlightSessionLoads.contains(sessionIdToLoad) {
            pendingReloadSessions.insert(sessionIdToLoad)
            return
        }
        inFlightSessionLoads.insert(sessionIdToLoad)

        // Build the replayed transcript off-screen while preserving any visible messages
        // on screen so background/manual reloads never flash an empty welcome placeholder.
        let targetVM = sessionViewModel(for: sessionIdToLoad)
        if targetVM.chatMessages.isEmpty {
            targetVM.setChatMessages([])
            targetVM.resetStreamingState()
        } else {
            targetVM.prepareForHistoryReload()
        }
        targetVM.beginHistoryReplay()

        // Determine the correct CWD for this session
        let sessionCwd: String
        if let cwd, !cwd.isEmpty {
            sessionCwd = cwd
        } else if let summary = sessionSummaries.first(where: { $0.id == sessionIdToLoad }),
                  let storedCwd = summary.cwd {
            sessionCwd = storedCwd
        } else {
            sessionCwd = resolvedWorkingDirectory
        }
        let payload = ACPSessionLoadPayload(
            sessionId: sessionIdToLoad,
            workingDirectory: sessionCwd
        )

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.inFlightSessionLoads.remove(sessionIdToLoad)
                if self.pendingReloadSessions.remove(sessionIdToLoad) != nil,
                   self.connectionState == .connected,
                   self.isInitialized,
                   self.sessionViewModels[sessionIdToLoad]?.isStreaming != true {
                    self.sendLoadSession(sessionIdToLoad, cwd: cwd)
                }
            }
            do {
                _ = try await service.loadSession(payload)
                // Yield once so queued @MainActor notification/response tasks commit before fallback finalize.
                await Task.yield()
                targetVM.finishHistoryReplay(clearRemainingStreaming: true)
            } catch {
                targetVM.discardHistoryReplay()
                let cachedConfigs = self.sessionConfigOptionsCache[sessionIdToLoad]
                let cachedModes = self.sessionModesCache[sessionIdToLoad]
                let cachedCommands = self.sessionCommandsCache[sessionIdToLoad]
                targetVM.loadChatState(
                    serverId: self.id,
                    sessionId: sessionIdToLoad,
                    canLoadFromStorage: true
                )
                if let cachedConfigs, !cachedConfigs.isEmpty {
                    targetVM.applySessionConfigOptions(cachedConfigs, serverId: self.id, sessionId: sessionIdToLoad)
                }
                if let cachedModes, !cachedModes.availableModes.isEmpty, targetVM.availableModes.isEmpty {
                    targetVM.setAvailableModes(cachedModes.availableModes, currentModeId: targetVM.cachedMode(for: self.id, sessionId: sessionIdToLoad) ?? cachedModes.currentModeId)
                }
                if let cachedCommands, !cachedCommands.isEmpty, targetVM.availableCommands.isEmpty {
                    targetVM.handleAvailableCommandsUpdate(cachedCommands, serverId: self.id, sessionId: sessionIdToLoad)
                }
                self.appendClosure("Failed to load session: \(error)")
            }
        }
        pendingSessionLoad = nil
    }

    /// Open a session - if connected, wait for any in-flight initial bridge sync
    /// before deciding whether `session/load` is necessary.
    func openSession(_ id: String) {
        let resolvedId = resolvedSessionIds[id] ?? id

        let hasCachedMessages = hasCachedMessages(sessionId: resolvedId)
        let hasInMemoryState = hasInMemorySessionState(for: resolvedId)
        let needsStorageCheck = !hasCachedMessages
            && !hasInMemoryState
            && !pendingLocalSessions.contains(id)
            && !pendingLocalSessions.contains(resolvedId)
            && !connectionManager.isSessionMaterialized(resolvedId)
        let hasStoredMessages = needsStorageCheck
            ? !(storage?.fetchMessages(forSessionId: resolvedId, serverId: self.id).isEmpty ?? true)
            : false

        setActiveSession(resolvedId)

        if pendingLocalSessions.contains(id) || pendingLocalSessions.contains(resolvedId) {
            pendingSessionLoad = nil
            lastLoadedSession = resolvedId
            return
        }

        if connectionManager.isSessionMaterialized(resolvedId) {
            pendingSessionLoad = nil
            lastLoadedSession = resolvedId
            return
        }

        let hasLocalMessages = hasCachedMessages || hasStoredMessages || hasInMemoryState

        if hasInitialSyncPendingClosure?() == true, let barrier = initialSyncBarrier {
            nextOpenSessionToken &+= 1
            let token = nextOpenSessionToken
            openSessionRequestTokens[resolvedId] = token
            Task { @MainActor [weak self] in
                await barrier()
                guard let self,
                      self.openSessionRequestTokens[resolvedId] == token else { return }
                let stillLocal = self.hasCachedMessages(sessionId: resolvedId)
                    || self.hasInMemorySessionState(for: resolvedId)
                    || !(self.storage?.fetchMessages(forSessionId: resolvedId, serverId: self.id).isEmpty ?? true)
                self.finishOpenSessionLoad(resolvedId: resolvedId, hasLocalMessages: stillLocal || hasLocalMessages)
            }
            return
        }

        finishOpenSessionLoad(resolvedId: resolvedId, hasLocalMessages: hasLocalMessages)
    }

    private func finishOpenSessionLoad(resolvedId: String, hasLocalMessages: Bool) {
        if connectionManager.isSessionMaterialized(resolvedId) {
            pendingSessionLoad = nil
            lastLoadedSession = resolvedId
            return
        }

        if hasLocalMessages && canLoadSession() {
            lastLoadedSession = resolvedId
            pendingSessionLoad = nil
            if connectionState == .connected, isInitialized {
                sendLoadSession(resolvedId)
            } else {
                pendingSessionLoad = resolvedId
            }
        } else if hasLocalMessages {
            lastLoadedSession = resolvedId
            pendingSessionLoad = nil
        } else if canLoadSession() {
            if connectionState == .connected, isInitialized {
                sendLoadSession(resolvedId)
            } else {
                pendingSessionLoad = resolvedId
            }
        } else {
            pendingSessionLoad = nil
        }
    }

    func hasInMemorySessionState(for sessionId: String) -> Bool {
        guard let viewModel = sessionViewModels[sessionId] else { return false }
        return viewModel.hasInMemorySessionData
    }

    /// Create a new session.
    func sendNewSession(workingDirectory: String? = nil) {
        let sanitizedCwd = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? sanitizeWorkingDirectory(workingDirectory!)
            : nil

        let pendingId = UUID().uuidString
        if let sanitizedCwd {
            pendingLocalSessionCwds[pendingId] = sanitizedCwd
            let newCwdAdded = rememberUsedWorkingDirectory(sanitizedCwd)
            pendingLocalSessionNewCwds[pendingId] = newCwdAdded
        }

        pendingLocalSessions.insert(pendingId)
        setActiveSession(pendingId, cwd: sanitizedCwd)

        // Try to create session immediately if connected and initialized
        if connectionState == .connected,
           let service = getServiceClosure(),
           isInitialized {
            pendingNewSessionPlaceholderId = pendingId

            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                let creationCwd = self.pendingLocalSessionCwds[pendingId] ?? self.resolvedWorkingDirectory
                self.pendingNewSessionCwd = creationCwd
                let newCwdAdded = self.rememberUsedWorkingDirectory(creationCwd)
                // Preserve any earlier working-directory discovery from placeholder edits.
                self.pendingLocalSessionNewCwds[pendingId] = (self.pendingLocalSessionNewCwds[pendingId] == true) || newCwdAdded
                let payload = self.makeSessionCreatePayload(workingDirectory: creationCwd)

                do {
                    let response = try await service.createSession(payload)
                    self.finalizePendingSessionCreation(
                        response: response,
                        placeholderId: pendingId,
                        fallbackCwd: creationCwd
                    )
                    self.appendClosure("Session created with metadata")
                } catch {
                    self.failPendingSessionCreation(
                        placeholderId: pendingId,
                        errorMessage: error.localizedDescription
                    )
                }
                self.creatingSessionTasks.removeValue(forKey: pendingId)
            }
            creatingSessionTasks[pendingId] = task
            appendClosure("Creating new session...")
        } else {
            appendClosure("Prepared new session (will be created on first send)")
        }
    }

    /// Update the working directory for the current pending session before it is materialized.
    func updatePendingSessionWorkingDirectory(_ newValue: String) {
        guard isPendingSession else { return }

        let sanitized = sanitizeWorkingDirectory(newValue)
        pendingLocalSessionCwds[sessionId] = sanitized

        let newCwdAdded = rememberUsedWorkingDirectory(sanitized)
        pendingLocalSessionNewCwds[sessionId] = (pendingLocalSessionNewCwds[sessionId] == true) || newCwdAdded

        if let index = sessionSummaries.firstIndex(where: { $0.id == sessionId }) {
            let existing = sessionSummaries[index]
            sessionSummaries[index] = SessionSummary(
                id: existing.id,
                title: existing.title,
                cwd: sanitized,
                updatedAt: existing.updatedAt
            )
            setSessionSummaries(sessionSummaries)
        }
    }

    /// Delete a session.
    func deleteSession(_ sessionId: String) {
        // Cancel any in-flight session creation task
        creatingSessionTasks[sessionId]?.cancel()
        creatingSessionTasks.removeValue(forKey: sessionId)
        pendingLocalSessions.remove(sessionId)
        pendingLocalSessionCwds.removeValue(forKey: sessionId)
        pendingLocalSessionNewCwds.removeValue(forKey: sessionId)
        resolvedSessionIds.removeValue(forKey: sessionId)
        sessionSummaries.removeAll { $0.id == sessionId }
        setSessionSummaries(sessionSummaries)

        cacheDelegate?.clearCache(for: id, sessionId: sessionId)
        sessionConfigOptionsCache.removeValue(forKey: sessionId)
        sessionModesCache.removeValue(forKey: sessionId)
        sessionCommandsCache.removeValue(forKey: sessionId)
        currentSessionViewModel?.removeCommands(for: id, sessionId: sessionId)

        if sessionCache == sessionId {
            sessionCache = ""
        }

        if lastLoadedSession == sessionId {
            lastLoadedSession = nil
        }
        if pendingSessionLoad == sessionId {
            pendingSessionLoad = nil
        }
        inFlightSessionLoads.remove(sessionId)
        pendingReloadSessions.remove(sessionId)
        openSessionRequestTokens.removeValue(forKey: sessionId)
        connectionManager.clearSessionMaterialized(sessionId)
        recentlyCreatedSessionGenerations.removeValue(forKey: sessionId)
        recentlyDeletedSessionGenerations[sessionId] = listFetchGeneration
        syncedProtectedSessionIds.remove(sessionId)

        if self.sessionId == sessionId {
            self.sessionId = ""
            self.selectedSessionId = nil
            currentSessionViewModel?.resetChatState()
        }

        removeSessionViewModel(for: sessionId)
        unreadTracker.removeSession(sessionId)
        localPinnedTimestampsBySessionId.removeValue(forKey: sessionId)
        sessionsAwaitingServerTimestamp.remove(sessionId)
        manuallyCancelledSessionIds.remove(sessionId)
        lastKnownServerUpdatedAt.removeValue(forKey: sessionId)
        storage?.deleteSession(sessionId: sessionId, forServerId: id)
    }

    @discardableResult
    func renameSession(sessionId targetSessionId: String, title: String) async throws -> String? {
        let trimmedId = targetSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw SessionRenameError.emptySessionId
        }
        guard !pendingLocalSessions.contains(trimmedId) else {
            throw SessionRenameError.pendingSessionNotMaterialized
        }
        guard let service = getServiceClosure(), connectionState == .connected else {
            throw SessionRenameError.notConnected
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let result = try await service.renameSession(sessionId: trimmedId, title: trimmedTitle)
            let normalizedTitle = result.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let effectiveTitle = (normalizedTitle?.isEmpty == false) ? normalizedTitle : nil
            applyAuthoritativeTitleUpdate(effectiveTitle, forSessionId: result.sessionId)
            return effectiveTitle
        } catch let error as ACPServiceError {
            if case .rpc(_, let rpcError) = error, rpcError.code == -32601 {
                throw SessionRenameError.unsupportedRemoteRename
            }
            throw error
        }
    }

    private func applyAuthoritativeTitleUpdate(_ newTitle: String?, forSessionId targetId: String) {
        if let index = sessionSummaries.firstIndex(where: { $0.id == targetId }) {
            let existing = sessionSummaries[index]
            sessionSummaries[index] = SessionSummary(
                id: existing.id,
                title: newTitle,
                cwd: existing.cwd,
                updatedAt: existing.updatedAt
            )
            setSessionSummaries(sessionSummaries)
        }
        storage?.updateSession(
            sessionId: targetId,
            forServerId: id,
            title: newTitle,
            touchUpdatedAt: false,
            clearTitle: (newTitle == nil)
        )
    }

    /// Abort a pending session creation and clean up placeholder UI state.
    private func failPendingSessionCreation(placeholderId: String, errorMessage: String) {
        guard pendingLocalSessions.contains(placeholderId) else { return }

        // Surface the error in the chat area if the placeholder is currently selected.
        if selectedSessionId == placeholderId {
            currentSessionViewModel?.addSystemErrorMessage("Session creation failed: \(errorMessage)")
        }

        appendClosure("Failed to create session: \(errorMessage)")

        // Reset in-flight creation bookkeeping so retries start clean.
        creatingSessionTasks[placeholderId]?.cancel()
        creatingSessionTasks.removeValue(forKey: placeholderId)
        pendingNewSessionCwd = nil
        pendingNewSessionPlaceholderId = nil

        // Remove the placeholder session and any cached state.
        removePlaceholderSession(placeholderId, replacedBy: nil)
    }

    /// Fetch session list from server.
    func fetchSessionList(force: Bool = false) {
        let canFetch = canFetchSessionList(force: force)
        startupLog(
            "ServerViewModel.fetchSessionList serverId=\(id.uuidString) force=\(force) canFetch=\(canFetch) connectionState=\(connectionState) isInitialized=\(isInitialized)"
        )
        guard canFetch else {
            loadCachedSessions()
            return
        }

        if connectionState == .connected, let service = getServiceClosure() {
            sendSessionList(service: service)
        } else {
            loadCachedSessions()
        }
    }

    /// Send single session/list request (SD-1.8 / SC-AC-047).
    private func sendSessionList(service: ACPService) {
        listFetchGeneration &+= 1
        activeListFetchGeneration = listFetchGeneration
        Task { @MainActor in
            do {
                let payload = ACPSessionListPayload(workingDirectory: resolvedWorkingDirectory)
                self.startupLog(
                    "ServerViewModel.sendSessionList serverId=\(self.id.uuidString) cwd=\(payload.workingDirectory ?? "nil")"
                )
                _ = try await service.listSessions(payload)
            } catch {
                appendClosure("Failed to fetch sessions: \(error)")
            }
        }
    }

    private func applyFetchedSessionList(
        _ rawSessions: [SessionSummary],
        allowPrune: Bool = true,
        fetchGeneration: UInt64? = nil
    ) {
        let gen = fetchGeneration ?? activeListFetchGeneration
        let merged = mergedServerSessionSummaries(rawSessions, fetchGeneration: gen)
        setSessionSummaries(merged)
        persistSessionsToStorage(
            allowPrune: allowPrune,
            fetchGeneration: gen,
            fetchedIds: Set(rawSessions.map(\.id))
        )
        if allowPrune && !hasCompletedNonlocalSync {
            deferredCompleteSessionList = (sessions: rawSessions, generation: gen)
        }

        var activeIds = Set<String>()
        for summary in rawSessions {
            let running = isSessionRunning(summary.id)
            let waiting = isSessionWaitingForUser(summary.id)
            if running || waiting {
                activeIds.insert(summary.id)
            } else if summary.updatedAt != nil {
                sessionsAwaitingServerTimestamp.remove(summary.id)
            }
        }

        unreadTracker.reconcileServerList(
            rawSessions,
            activeViewingSessionId: activeViewingSessionId,
            runningSessionIds: activeIds,
            ignoredSessionIds: Self.ignoredProbeSessionIds,
            pendingSessionIds: pendingLocalSessions,
            serverId: id,
            storage: storage
        )
        detectAndReloadStaleMaterializedSessions(from: rawSessions)
        objectWillChange.send()
    }

    func handleSessionListResult(_ sessions: [SessionSummary]) {
        startupLog(
            "ServerViewModel.handleSessionListResult serverId=\(id.uuidString) sessions=\(sessions.count)"
        )
        if sessionListSupportFlag() == true {
            applyFetchedSessionList(sessions, allowPrune: true, fetchGeneration: activeListFetchGeneration)
            appendClosure("Fetched \(sessions.count) session\(sessions.count == 1 ? "" : "s")")
        } else {
            appendClosure("Ignoring unexpected session/list response (server doesn't support list)")
        }
    }

    private func detectAndReloadStaleMaterializedSessions(from summaries: [SessionSummary]) {
        guard sessionListSupportFlag() == true else { return }
        for summary in summaries {
            guard let updatedAt = summary.updatedAt else { continue }
            let sid = summary.id
            guard connectionManager.isSessionMaterialized(sid) else { continue }
            guard let baseline = lastKnownServerUpdatedAt[sid] else {
                lastKnownServerUpdatedAt[sid] = updatedAt
                continue
            }
            if updatedAt.timeIntervalSince(baseline) > 2.0 {
                lastKnownServerUpdatedAt[sid] = updatedAt
                guard sessionViewModels[sid]?.isStreaming != true else { continue }
                connectionManager.clearSessionMaterialized(sid)
                if selectedSessionId == sid {
                    reloadSession(sid)
                }
            } else if updatedAt > baseline {
                lastKnownServerUpdatedAt[sid] = updatedAt
            }
        }
    }

    /// Send a prompt to the current session.
    func sendPrompt(promptText: String, images: [ImageAttachment], commandName: String? = nil) {
        _ = submitPrompt(promptText: promptText, images: images, commandName: commandName)
    }

    /// Performs synchronous pre-flight validation on `@MainActor` before accepting the turn.
    /// - Returns: `true` if the prompt passed synchronous validation and was accepted for delivery; `false` if rejected (caller keeps composer text/images intact).
    @discardableResult
    func submitPrompt(promptText: String, images: [ImageAttachment], commandName: String? = nil) -> Bool {
        guard let service = getServiceClosure(), connectionState == .connected else {
            appendClosure("Not connected")
            return false
        }
        guard !sessionId.isEmpty else {
            appendClosure("Create or load a session first")
            return false
        }

        var prompt = promptText
        if let commandName {
            let prefix = "/\(commandName)"
            let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedPrompt.hasPrefix(prefix) {
                // Already includes the command prefix
            } else if trimmedPrompt.isEmpty {
                prompt = prefix
            } else {
                prompt = "\(prefix) \(prompt)"
            }
        }

        // Don't create an empty turn
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, images.isEmpty {
            appendClosure("Cannot send empty prompt")
            return false
        }

        let initialSessionId = sessionId
        if !pendingLocalSessions.contains(initialSessionId) {
            manuallyCancelledSessionIds.remove(initialSessionId)
            sessionsAwaitingServerTimestamp.insert(initialSessionId)
            unreadTracker.recordPendingServerTimeAbsorption(initialSessionId, forServerId: id, storage: storage)
            bumpSessionTimestamp(sessionId: initialSessionId)
        }

        var targetSessionId = initialSessionId
        var targetVM = sessionViewModel(for: targetSessionId)

        // End any prior streaming assistant message on the originating session
        targetVM.abandonStreamingMessage()

        // Show the user's message immediately and record pending delivery before any async hop
        let chatImages = images.map { ChatImageData(from: $0) }
        let userMsgId = targetVM.addUserMessage(content: prompt, images: chatImages)
        targetVM.recordPendingPromptDelivery(
            userMessageId: userMsgId,
            promptText: prompt,
            images: images,
            clientTurnId: nil
        )
        targetVM.startNewStreamingResponse()

        Task { @MainActor [weak self] in
            guard let self else { return }

            if !isInitialized {
                appendClosure("Initialize needed but not yet moved to ServerViewModel")
                failPendingTurn("Initialize needed", forSessionId: targetSessionId)
                return
            }

            // Handle pending local session creation
            if pendingLocalSessions.contains(targetSessionId) {
                let placeholderId = targetSessionId

                // Await in-flight session creation task if any
                if let creationTask = creatingSessionTasks[placeholderId] {
                    await creationTask.value

                    if let resolvedId = resolvedSessionIds[placeholderId] {
                        if self.sessionId == placeholderId {
                            setActiveSession(resolvedId)
                        }
                        targetSessionId = resolvedId
                        targetVM = sessionViewModel(for: resolvedId)
                        resolvedSessionIds.removeValue(forKey: placeholderId)
                    }
                }

                // If still pending, create it now
                if pendingLocalSessions.contains(targetSessionId) {
                    let creationCwd = pendingLocalSessionCwds[placeholderId] ?? resolvedWorkingDirectory
                    pendingNewSessionCwd = creationCwd
                    pendingNewSessionPlaceholderId = placeholderId
                    let newCwdAdded = rememberUsedWorkingDirectory(creationCwd)
                    // Update the flag - use OR to preserve any previous true value
                    pendingLocalSessionNewCwds[placeholderId] = (pendingLocalSessionNewCwds[placeholderId] == true) || newCwdAdded

                    let payload = makeSessionCreatePayload(workingDirectory: creationCwd)

                    do {
                        let response = try await service.createSession(payload)
                        finalizePendingSessionCreation(
                            response: response,
                            placeholderId: placeholderId,
                            fallbackCwd: creationCwd
                        )

                        if let resolvedId = resolvedSessionIds[placeholderId] {
                            if self.sessionId == placeholderId {
                                setActiveSession(resolvedId)
                            }
                            targetSessionId = resolvedId
                            targetVM = sessionViewModel(for: resolvedId)
                            resolvedSessionIds.removeValue(forKey: placeholderId)
                        }
                    } catch {
                        // T5 SD-4.4: Preserve draft placeholder session & VM so user can tap retry arrow to restore & resend.
                        creatingSessionTasks[placeholderId]?.cancel()
                        creatingSessionTasks.removeValue(forKey: placeholderId)
                        pendingNewSessionCwd = nil
                        pendingNewSessionPlaceholderId = nil
                        appendClosure("Failed to create session: \(error.localizedDescription)")
                        failPendingTurn("Failed to create session: \(error.localizedDescription)", forSessionId: targetSessionId)
                        return
                    }

                    guard !targetSessionId.isEmpty else {
                        appendClosure("Create or load a session first")
                        failPendingTurn("Create or load a session first", forSessionId: targetSessionId)
                        return
                    }
                }
            }

            if pendingLocalSessions.contains(targetSessionId) {
                appendClosure("Session creation still pending; aborting prompt")
                failPendingTurn("Session creation failed", forSessionId: targetSessionId)
                return
            }

            guard !targetSessionId.isEmpty else {
                appendClosure("Create or load a session first")
                failPendingTurn("Create or load a session first", forSessionId: targetSessionId)
                return
            }

            // Await any in-flight nonlocal/sync barrier before deciding whether session/load is needed.
            await initialSyncBarrier?()

            guard let activeService = getServiceClosure() else {
                appendClosure("Not connected")
                failPendingTurn("Not connected", forSessionId: targetSessionId)
                return
            }

            // Handle session re-materialization if needed via session/load
            if canLoadSession(),
               !pendingLocalSessions.contains(targetSessionId),
               !connectionManager.isSessionMaterialized(targetSessionId) {
                let sessionToLoad = targetSessionId
                let loadCwd = sessionSummaries.first(where: { $0.id == sessionToLoad })?.cwd ?? resolvedWorkingDirectory

                let payload = ACPSessionLoadPayload(
                    sessionId: sessionToLoad,
                    workingDirectory: loadCwd
                )

                do {
                    targetVM.beginHistoryReplay(preserveExistingMessages: true)
                    _ = try await activeService.loadSession(payload)
                    await Task.yield()
                    targetVM.finishHistoryReplay(clearRemainingStreaming: false)
                    connectionManager.markSessionMaterialized(sessionToLoad)
                } catch {
                    targetVM.finishHistoryReplay(clearRemainingStreaming: false)
                    appendClosure("Failed to load session before prompt: \(error)")
                    failPendingTurn("Failed to load session: \(error.localizedDescription)", forSessionId: targetSessionId)
                    return
                }
            }

            manuallyCancelledSessionIds.remove(targetSessionId)
            sessionsAwaitingServerTimestamp.insert(targetSessionId)
            unreadTracker.recordPendingServerTimeAbsorption(targetSessionId, forServerId: id, storage: storage)
            bumpSessionTimestamp(sessionId: targetSessionId)
            updateSessionTitleIfNeeded(with: prompt, forSessionId: targetSessionId)

            // Log image attachment info
            if !images.isEmpty {
                appendClosure("Sending \(images.count) image(s): \(images.map { "\($0.mimeType) (\($0.sizeDescription))" }.joined(separator: ", "))")
            }

            // Build prompt content
            let imageInputs = images.map { ACPImageInput(mimeType: $0.mimeType, base64Data: $0.base64Data) }
            let promptCapabilities = agentInfo?.capabilities.promptCapabilities
            let buildResult = ACPPromptBuilder.build(
                text: prompt,
                images: imageInputs,
                capabilities: promptCapabilities
            )

            // Log warnings
            for warning in buildResult.warnings {
                appendClosure("Warning: \(warning)")
            }

            appendClosure("Prompt content blocks: \(buildResult.debugSummary)")

            // Validate prompt
            if let validationError = ACPPromptBuilder.validate(buildResult) {
                appendClosure(validationError)
                failPendingTurn(validationError, forSessionId: targetSessionId)
                return
            }

            let clientTurnId = UUID().uuidString
            guard let payload = buildResult.makePayload(
                sessionId: targetSessionId,
                meta: [NonlocalMethods.clientTurnIdMetaKey: .string(clientTurnId)]
            ) else {
                appendClosure("Cannot send empty prompt")
                failPendingTurn("Cannot send empty prompt", forSessionId: targetSessionId)
                return
            }

            if !targetVM.isStreaming {
                targetVM.startNewStreamingResponse()
            } else {
                targetVM.markExplicitActiveTurn()
            }
            targetVM.setPendingPromptDeliveryClientTurnId(clientTurnId)
            recordSentClientTurnId?(targetSessionId, clientTurnId)

            do {
                _ = try await activeService.sendPrompt(payload)
                targetVM.clearPendingPromptDelivery()
                clearClientTurnId?(targetSessionId, clientTurnId)
                markClientTurnCompleted?(targetSessionId, clientTurnId)
                targetVM.clearExplicitActiveTurn()
            } catch {
                let isDisconnectError: Bool = {
                    if case ACPServiceError.disconnected = error { return true }
                    if case ACPClientError.disconnected = error { return true }
                    return false
                }()
                if isDisconnectError {
                    appendClosure("Prompt connection interrupted; awaiting sync recovery")
                } else {
                    clearClientTurnId?(targetSessionId, clientTurnId)
                    appendClosure("Failed to send prompt: \(error)")
                    let errorMessage = formatPromptError(error)
                    failPendingTurn(errorMessage, forSessionId: targetSessionId)
                }
            }
        }
        return true
    }
    func noteUserCancelled(sessionId targetSessionId: String) {
        guard !targetSessionId.isEmpty else { return }
        existingSessionViewModel(for: targetSessionId)?.clearPendingPromptDelivery()
        manuallyCancelledSessionIds.insert(targetSessionId)
        sessionsAwaitingServerTimestamp.insert(targetSessionId)
        localPinnedTimestampsBySessionId.removeValue(forKey: targetSessionId)
        unreadTracker.recordPendingServerTimeAbsorption(targetSessionId, forServerId: id, storage: storage)
        objectWillChange.send()
    }

    func isTurnCoveredBySeenWatermark(sessionId targetSessionId: String, serverActivityDate: Date?) -> Bool {
        unreadTracker.isCoveredBySeenWatermark(sessionId: targetSessionId, serverActivityDate: serverActivityDate)
    }

    func handleTurnPausedOrEnded(
        sessionId targetSessionId: String,
        reasonCancelled: Bool,
        isError: Bool,
        requiresUserAction: Bool,
        knownServerActivityDate: Date? = nil,
        suppressUnread: Bool = false
    ) {
        guard !targetSessionId.isEmpty, !Self.ignoredProbeSessionIds.contains(targetSessionId) else { return }

        let wasManuallyCancelled = (manuallyCancelledSessionIds.remove(targetSessionId) != nil)
        if reasonCancelled || wasManuallyCancelled {
            sessionsAwaitingServerTimestamp.insert(targetSessionId)
            localPinnedTimestampsBySessionId.removeValue(forKey: targetSessionId)
            unreadTracker.recordPendingServerTimeAbsorption(targetSessionId, forServerId: id, storage: storage)
            objectWillChange.send()
            return
        }

        if suppressUnread {
            if let knownServerActivityDate {
                unreadTracker.markRead(
                    targetSessionId,
                    knownServerUpdatedAt: knownServerActivityDate,
                    absorbNextServerTime: false,
                    forServerId: id,
                    storage: storage
                )
            }
            return
        }

        bumpSessionTimestamp(sessionId: targetSessionId)
        sessionsAwaitingServerTimestamp.insert(targetSessionId)
        unreadTracker.markUnread(
            targetSessionId,
            forServerId: id,
            storage: storage,
            activeViewingSessionId: activeViewingSessionId,
            knownServerUpdatedAt: knownServerActivityDate
        )
        objectWillChange.send()
    }
}
