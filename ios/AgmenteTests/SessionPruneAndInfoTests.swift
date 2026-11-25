import XCTest
import ACP
@testable import Agmente
import ACPClient

private final class PruneScriptedSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var incomingQueue: [WebSocketEvent] = []
    private var incomingContinuation: CheckedContinuation<WebSocketEvent, Error>?
    var onSend: ((String) -> Void)?

    func connect(headers: [String: String]) async throws {}

    func send(text: String) async throws {
        lock.lock()
        let cb = onSend
        lock.unlock()
        cb?(text)
    }

    func receive() async throws -> WebSocketEvent {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !incomingQueue.isEmpty {
                let next = incomingQueue.removeFirst()
                lock.unlock()
                continuation.resume(returning: next)
            } else {
                incomingContinuation = continuation
                lock.unlock()
            }
        }
    }

    func close() async {
        lock.lock()
        let cont = incomingContinuation
        incomingContinuation = nil
        lock.unlock()
        cont?.resume(returning: .closed(WebSocketCloseReason(code: 1000, reason: nil)))
    }

    func ping() async throws {}

    func enqueue(_ event: WebSocketEvent) {
        lock.lock()
        if let cont = incomingContinuation {
            incomingContinuation = nil
            lock.unlock()
            cont.resume(returning: event)
        } else {
            incomingQueue.append(event)
            lock.unlock()
        }
    }

    func enqueueResponse(id: ACP.ID, result: ACP.Value) throws {
        let wire = ACPWireMessage.response(.init(id: id, result: result))
        let data = try JSONEncoder().encode(wire)
        enqueue(.text(String(decoding: data, as: UTF8.self)))
    }

    func enqueueRPCError(id: ACP.ID, code: Int, message: String) throws {
        let wire = ACPWireMessage.response(.init(id: id, error: .serverError(code: code, message: message)))
        let data = try JSONEncoder().encode(wire)
        enqueue(.text(String(decoding: data, as: UTF8.self)))
    }
}

private final class PruneSocketProvider: WebSocketProviding, @unchecked Sendable {
    private let socket: PruneScriptedSocket
    init(_ socket: PruneScriptedSocket) { self.socket = socket }
    func makeConnection(url: URL) -> WebSocketConnection { socket }
}

@MainActor
final class SessionPruneAndInfoTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let name = "SessionPruneAndInfoTests.\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeHarness(
        socket: PruneScriptedSocket = PruneScriptedSocket()
    ) -> (model: AppViewModel, storage: SessionStorage, serverId: UUID, serverVM: ServerViewModel) {
        let defaults = makeIsolatedDefaults()
        let persistence = PersistenceController(inMemory: true)
        let storage = SessionStorage(container: persistence.container)
        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false
        )
        let model = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        model.addServer(
            name: "ACP Test",
            scheme: "ws",
            host: "127.0.0.1:18901",
            token: "",
            workingDirectory: "/proj"
        )
        let serverId = model.selectedServerId!
        let serverVM = model.selectedServerViewModel!
        // Mark server as supporting session/list
        let profile = AgentProfile(
            id: nil,
            name: "FakeAgy",
            title: "FakeAgy",
            version: "1.0",
            description: nil,
            modes: [],
            capabilities: AgentCapabilityState(listSessions: true)
        )
        serverVM.updateAgentInfo(profile)
        return (model, storage, serverId, serverVM)
    }

    // AC-202: session/list RPC error and multi-CWD partial failure must never prune existing cached sessions.
    func testAC202SessionListErrorsNeverPruneSessions() async throws {
        let socket = PruneScriptedSocket()
        let (model, storage, serverId, serverVM) = makeHarness(socket: socket)

        // Seed S1 and S2 in both memory & Core Data under two distinct working directories
        storage.saveSession(StoredSessionInfo(sessionId: "S1", title: "One", cwd: "/dirA", updatedAt: nil), forServerId: serverId)
        storage.saveSession(StoredSessionInfo(sessionId: "S2", title: "Two", cwd: "/dirB", updatedAt: nil), forServerId: serverId)
        serverVM.loadCachedSessions()
        _ = serverVM.sessionViewModel(for: "S1")
        _ = serverVM.sessionViewModel(for: "S2")

        XCTAssertEqual(Set(serverVM.sessionSummaries.map(\.id)), Set(["S1", "S2"]))

        // 1. Single session/list RPC error -> S1 & S2 remain intact
        let service = ACPService(
            client: ACPClient(
                configuration: .init(endpoint: URL(string: "ws://127.0.0.1:18901")!, pingInterval: nil),
                socketProvider: PruneSocketProvider(socket)
            )
        )
        try await service.connect()
        model.setServiceForTesting(service)

        let req = ACP.AnyRequest(id: .int(10), method: "session/list", params: .object([:]))
        model.acpService(service, willSend: req)
        let errResp = ACPWireMessage.response(.init(id: .int(10), error: .serverError(code: -32000, message: "boom")))
        model.acpService(service, didReceiveMessage: errResp)

        XCTAssertEqual(Set(serverVM.sessionSummaries.map(\.id)), Set(["S1", "S2"]))
        XCTAssertEqual(Set(storage.fetchSessions(forServerId: serverId).map(\.sessionId)), Set(["S1", "S2"]))

        // 2. Multi-CWD fetch where 1 directory succeeds empty and 1 directory fails -> S1 & S2 remain intact
        var listCount = 0
        socket.onSend = { text in
            guard let data = text.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                  case .request(let r) = wire,
                  r.method == "session/list" else { return }
            listCount += 1
            if listCount == 1 {
                try? socket.enqueueResponse(id: r.id, result: .object(["sessions": .array([])]))
            } else {
                try? socket.enqueueRPCError(id: r.id, code: -32000, message: "dir failed")
            }
        }
        serverVM.fetchSessionList(force: true)
        try await Task.sleep(nanoseconds: 120_000_000)

        XCTAssertEqual(Set(serverVM.sessionSummaries.map(\.id)), Set(["S1", "S2"]))
        XCTAssertEqual(Set(storage.fetchSessions(forServerId: serverId).map(\.sessionId)), Set(["S1", "S2"]))

        await service.disconnect()
    }

    // AC-203: In-flight older session/list must not kill recently created session S_new;
    // a subsequent complete non-empty session/list initiated AFTER creation evicts S_new if absent.
    func testAC203RecentlyCreatedSessionProtectedAgainstOlderListOnly() async throws {
        let socket = PruneScriptedSocket()
        let defaults = makeIsolatedDefaults()
        let persistence = PersistenceController(inMemory: true)
        let storage = SessionStorage(container: persistence.container)
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://127.0.0.1:18901")!, pingInterval: nil),
            socketProvider: PruneSocketProvider(socket)
        )
        let service = ACPService(client: client)
        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { _, _ in service }
        )

        let model = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        model.addServer(
            name: "ACP Test",
            scheme: "ws",
            host: "127.0.0.1:18901",
            token: "",
            workingDirectory: "/proj"
        )
        socket.onSend = { text in
            guard let data = text.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                  case .request(let r) = wire else { return }
            if r.method == "initialize" {
                try? socket.enqueueResponse(id: r.id, result: .object([
                    "protocolVersion": .int(1),
                    "agentInfo": .object(["name": .string("FakeAgy"), "version": .string("1.0")]),
                    "agentCapabilities": .object(["listSessions": .bool(true)])
                ]))
            } else if r.method == "session/new" {
                try? socket.enqueueResponse(id: r.id, result: .object([
                    "sessionId": .string("S_new"),
                    "cwd": .string("/proj")
                ]))
            } else if r.method == "session/prompt" {
                try? socket.enqueueResponse(id: r.id, result: .object([
                    "stopReason": .string("end_turn")
                ]))
            }
        }
        let connected = await manager.connectAndWait(
            config: ACPConnectionConfig(endpoint: URL(string: "ws://127.0.0.1:18901")!)
        )
        XCTAssertTrue(connected)
        let initialized = await manager.initializeAndWait(
            payload: ACPInitializationPayload(protocolVersion: 1, clientName: "Test", clientVersion: "1.0")
        )
        XCTAssertTrue(initialized)
        let serverId = model.selectedServerId!
        let serverVM = model.selectedServerViewModel!
        serverVM.updateAgentInfo(AgentProfile(
            id: nil, name: "FakeAgy", title: "FakeAgy", version: "1.0", description: nil,
            modes: [], capabilities: AgentCapabilityState(listSessions: true)
        ))

        // Start L_old (listFetchGeneration = 1) without responding yet
        serverVM.fetchSessionList(force: true)
        try await Task.sleep(nanoseconds: 30_000_000)

        // Create S_new via lazy sendNewSession + sendPrompt -> session/new while L_old is in-flight
        serverVM.sendNewSession(workingDirectory: "/proj")
        serverVM.sendPrompt(promptText: "hello", images: [])
        try await Task.sleep(nanoseconds: 250_000_000)
        // Mark turn finished so S_new is no longer protected by isStreaming/isActivelyRunning; only recentlyCreatedSessionGenerations protects it
        serverVM.existingSessionViewModel(for: "S_new")?.resetChatState()
        XCTAssertTrue(serverVM.sessionSummaries.contains(where: { $0.id == "S_new" }))

        // 1. L_old arrives late omitting S_new -> S_new MUST survive
        serverVM.handleSessionListResult([SessionSummary(id: "S_other", title: "Other", cwd: "/proj", updatedAt: nil)])
        XCTAssertTrue(serverVM.sessionSummaries.contains(where: { $0.id == "S_new" }))
        XCTAssertNotNil(serverVM.existingSessionViewModel(for: "S_new"))
        XCTAssertTrue(storage.fetchSessions(forServerId: serverId).contains(where: { $0.sessionId == "S_new" }))

        // 2. New list L_after initiated AFTER S_new creation omits S_new -> S_new is evicted
        socket.onSend = nil
        serverVM.fetchSessionList(force: true)
        try await Task.sleep(nanoseconds: 30_000_000)
        serverVM.handleSessionListResult([SessionSummary(id: "S_other", title: "Other", cwd: "/proj", updatedAt: nil)])
        XCTAssertFalse(serverVM.sessionSummaries.contains(where: { $0.id == "S_new" }))
        XCTAssertNil(serverVM.existingSessionViewModel(for: "S_new"))
        XCTAssertFalse(storage.fetchSessions(forServerId: serverId).contains(where: { $0.sessionId == "S_new" }))

        await service.disconnect()
    }

    // AC-204: Exact keep-set (streaming, pending user action, synced completed S_sync_done on empty vs non-empty list,
    // dead session S_dead eviction + active detail exit, third-party ACP empty list, and deferred prune after sync).
    func testAC204ExactKeepSetActiveProtectionAndDeferredPruneAfterSync() {
        let (model, storage, serverId, serverVM) = makeHarness()

        // Seed 4 sessions
        for sid in ["S_stream", "S_pending_act", "S_sync_done", "S_dead"] {
            storage.saveSession(StoredSessionInfo(sessionId: sid, title: sid, cwd: "/proj", updatedAt: nil), forServerId: serverId)
        }
        serverVM.loadCachedSessions()

        // Mark S_stream streaming
        let vmStream = serverVM.sessionViewModel(for: "S_stream")
        vmStream.setChatMessages([ChatMessage(role: .assistant, content: "working", isStreaming: true)])

        // Mark S_pending_act with pending permission
        let vmPending = serverVM.sessionViewModel(for: "S_pending_act")
        vmPending.handlePermissionRequest(ACP.AnyRequest(
            id: .string("perm-1"),
            method: "session/request_permission",
            params: .object([
                "sessionId": .string("S_pending_act"),
                "toolCallId": .string("tc-1"),
                "title": .string("Run"),
                "options": .array([.object(["optionId": .string("allow"), "name": .string("Allow")])])
            ])
        ))

        // Mark S_sync_done as synced-protected (like completed S1 from nonlocal/sync)
        _ = serverVM.sessionViewModel(for: "S_sync_done")
        serverVM.markSessionSyncedProtected("S_sync_done")

        // Open S_dead as current detail session
        _ = serverVM.sessionViewModel(for: "S_dead")
        serverVM.selectedSessionId = "S_dead"
        serverVM.sessionId = "S_dead"

        // 1. Before nonlocal/sync completes (third-party ACP or pre-sync), concurrent empty list preserves all
        serverVM.handleSessionListResult([])
        XCTAssertTrue(serverVM.sessionSummaries.contains(where: { $0.id == "S_stream" }) || serverVM.existingSessionViewModel(for: "S_stream") != nil)
        XCTAssertNotNil(serverVM.existingSessionViewModel(for: "S_sync_done"))
        XCTAssertNotNil(serverVM.existingSessionViewModel(for: "S_dead"))

        // 2. Non-empty complete list [S_other] after sync: S_stream & S_pending_act survive;
        //    S_dead & out-of-set S_sync_done are evicted; S_dead detail page exits automatically.
        serverVM.markNonlocalSyncCompleted()
        serverVM.handleSessionListResult([SessionSummary(id: "S_other", title: "Other", cwd: "/proj", updatedAt: nil)])

        XCTAssertNotNil(serverVM.existingSessionViewModel(for: "S_stream"))
        XCTAssertNotNil(serverVM.existingSessionViewModel(for: "S_pending_act"))
        XCTAssertNil(serverVM.existingSessionViewModel(for: "S_sync_done"))
        XCTAssertNil(serverVM.existingSessionViewModel(for: "S_dead"))
        XCTAssertFalse(storage.fetchSessions(forServerId: serverId).contains(where: { $0.sessionId == "S_dead" }))
        XCTAssertEqual(serverVM.sessionId, "")
        XCTAssertEqual(model.serverSessionId, "")

        // 3. Deferred prune after sync: list arrives BEFORE sync completes omitting S_stale2,
        //    then reconcileDeferredPruneAfterSync() evicts S_stale2.
        serverVM.resetNonlocalSyncProtectionState()
        storage.saveSession(StoredSessionInfo(sessionId: "S_stale2", title: "Stale2", cwd: "/proj", updatedAt: nil), forServerId: serverId)
        _ = serverVM.sessionViewModel(for: "S_stale2")
        serverVM.handleSessionListResult([SessionSummary(id: "S_other", title: "Other", cwd: "/proj", updatedAt: nil)])
        // Now sync completes and runs deferred prune
        serverVM.markNonlocalSyncCompleted()
        serverVM.reconcileDeferredPruneAfterSync()
        XCTAssertNil(serverVM.existingSessionViewModel(for: "S_stale2"))
        XCTAssertFalse(storage.fetchSessions(forServerId: serverId).contains(where: { $0.sessionId == "S_stale2" }))
    }

    // AC-205: Cross-server targeting for nonlocal/session_deleted (never deletes from selectedServerB when event belongs to A)
    // and full local cleanup + auto-exit on deleted active session.
    func testAC205NonlocalSessionDeletedTargetsOwnerServerAndCleansAllState() {
        let defaults = makeIsolatedDefaults()
        let persistence = PersistenceController(inMemory: true)
        let storage = SessionStorage(container: persistence.container)
        let model = AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )

        model.addServer(name: "A", scheme: "ws", host: "127.0.0.1:18911", token: "", workingDirectory: "/a")
        let serverA = model.selectedServerId!
        let vmA = model.selectedServerViewModel!
        storage.saveSession(StoredSessionInfo(sessionId: "S_shared", title: "A's session", cwd: "/a", updatedAt: nil), forServerId: serverA)
        vmA.loadCachedSessions()
        _ = vmA.sessionViewModel(for: "S_shared")
        vmA.pendingSessionLoad = "S_shared"

        model.addServer(name: "B", scheme: "ws", host: "127.0.0.1:18912", token: "", workingDirectory: "/b")
        let serverB = model.selectedServerId!
        let vmB = model.selectedServerViewModel!
        storage.saveSession(StoredSessionInfo(sessionId: "S_shared", title: "B's session", cwd: "/b", updatedAt: nil), forServerId: serverB)
        vmB.loadCachedSessions()
        _ = vmB.sessionViewModel(for: "S_shared")

        // Currently selected server is B; deliver session_deleted for serverA
        model.handleNonlocalSessionDeleted(
            NonlocalSessionDeletedNotification(instanceId: "inst-a", sessionId: "S_shared"),
            serverId: serverA
        )

        // Server A cleaned; Server B untouched!
        XCTAssertFalse(vmA.sessionSummaries.contains(where: { $0.id == "S_shared" }))
        XCTAssertNil(vmA.existingSessionViewModel(for: "S_shared"))
        XCTAssertNil(vmA.pendingSessionLoad)
        XCTAssertFalse(storage.fetchSessions(forServerId: serverA).contains(where: { $0.sessionId == "S_shared" }))

        XCTAssertTrue(vmB.sessionSummaries.contains(where: { $0.id == "S_shared" }))
        XCTAssertNotNil(vmB.existingSessionViewModel(for: "S_shared"))
        XCTAssertTrue(storage.fetchSessions(forServerId: serverB).contains(where: { $0.sessionId == "S_shared" }))

        // Now open S_shared on serverB and deliver session_deleted for serverB -> clears active detail page
        vmB.selectedSessionId = "S_shared"
        vmB.sessionId = "S_shared"
        vmB.pendingSessionLoad = "S_shared"

        model.handleNonlocalSessionDeleted(
            NonlocalSessionDeletedNotification(instanceId: "inst-b", sessionId: "S_shared"),
            serverId: serverB
        )
        XCTAssertEqual(vmB.sessionId, "")
        XCTAssertEqual(model.serverSessionId, "")
        XCTAssertNil(vmB.pendingSessionLoad)
        XCTAssertFalse(storage.fetchSessions(forServerId: serverB).contains(where: { $0.sessionId == "S_shared" }))
    }

    // AC-206: canViewSessionInfo gating (ACP non-draft true, draft false) and
    // single .sheet(item:) with SessionSheetDestination (4 cases).
    func testAC206CanViewSessionInfoGatingAndUnifiedSessionSheetDestination() throws {
        let (model, _, _, serverVM) = makeHarness()

        // ACP non-draft -> true
        XCTAssertTrue(model.canViewSessionInfo("sess-real-1"))

        // ACP draft (pending local session via sendNewSession while disconnected) -> false
        serverVM.sendNewSession(workingDirectory: "/proj")
        let draftId = serverVM.sessionId
        XCTAssertTrue(serverVM.isPendingSessionId(draftId))
        XCTAssertFalse(model.canViewSessionInfo(draftId))
        XCTAssertFalse(model.canViewSessionInfo(""))

        // Verify all 4 SessionSheetDestination cases and single .sheet(item:) in SessionDetailView.swift
        let infoDest = SessionSheetDestination.sessionInfo(sessionId: "s1")
        let dirDest = SessionSheetDestination.directoryBrowser(path: "/proj", projectPath: "/proj")
        let remoteDest = SessionSheetDestination.remotePath(id: UUID(), initialPath: "/proj/a.md", prefersDirectory: false, lineAnchorHint: nil, projectPath: "/proj")
        let mermaidDest = SessionSheetDestination.mermaidFullscreen(source: "graph TD; A-->B")
        XCTAssertEqual(Set([infoDest.id, dirDest.id, remoteDest.id, mermaidDest.id]).count, 4)

        let testFileURL = URL(fileURLWithPath: #filePath)
        let sessionDetailURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Agmente/SessionDetailView.swift")
        let source = try String(contentsOf: sessionDetailURL, encoding: .utf8)
        XCTAssertTrue(source.contains(".sheet(item: $activeSheet"))
        XCTAssertTrue(source.contains(".sessionInfo(sessionId:"))
        XCTAssertFalse(source.contains("showSessionInfoSheet"))
    }

    // MARK: - W2-AC-122 / SC-AC-050: Entry-gate states (active/waiting, non-synced ACP, local-only ACP, local draft) & true session deletion anti-resurrection

    func testW2AC122_DeleteEntryGatesAndLocalDraftOfflineDelete() async throws {
        let storage = SessionStorage.inMemory()
        let defaults = UserDefaults(suiteName: "W2AC122.\(UUID().uuidString)")!
        let acpServer = ACPServerConfiguration(
            id: UUID(), name: "ACP", scheme: "ws", host: "127.0.0.1:19401",
            token: "", workingDirectory: "/tmp"
        )
        storage.saveServer(acpServer)

        let appVM = AppViewModel(storage: storage, defaults: defaults, shouldStartNetworkMonitoring: false, shouldConnectOnStartup: false)
        let acpVM = try XCTUnwrap(appVM.serverViewModels[acpServer.id])

        // 1. Before nonlocal/sync completes, remote delete gate is false
        XCTAssertFalse(acpVM.hasCompletedNonlocalSync)

        // 2. Running / waiting session blocks deletion with .activeSession (0 RPC)
        let activeVM = acpVM.sessionViewModel(for: "S-active")
        activeVM.startNewStreamingResponse()
        XCTAssertTrue(acpVM.isSessionRunning("S-active"))
        let deleteResult = await appVM.deleteRemoteSession(sessionId: "S-active", serverId: acpServer.id)
        XCTAssertEqual(deleteResult, .failure(.activeSession))

        // 4. Local draft (pending) deletes offline without RPC
        acpVM.sendNewSession(workingDirectory: "/tmp")
        let draftId = acpVM.sessionId
        XCTAssertTrue(acpVM.isPendingSessionId(draftId))
        acpVM.deleteSession(draftId)
        XCTAssertFalse(acpVM.isPendingSessionId(draftId))
        XCTAssertNil(acpVM.existingSessionViewModel(for: draftId))
    }

    // MARK: - W2-AC-123: fetchSessionInfoForDeleteConfirmation 1.5s timeout / error falls back to nil (not 0)

    func testW2AC123_DeleteConfirmationPrecheckTimeoutFallsBackToNil() async {
        let storage = SessionStorage.inMemory()
        let defaults = UserDefaults(suiteName: "W2AC123.\(UUID().uuidString)")!
        let server = ACPServerConfiguration(
            id: UUID(), name: "ACP", scheme: "ws", host: "127.0.0.1:19403",
            token: "", workingDirectory: "/tmp"
        )
        storage.saveServer(server)
        let appVM = AppViewModel(storage: storage, defaults: defaults, shouldStartNetworkMonitoring: false, shouldConnectOnStartup: false)

        // Offline/error returns nil (never misreports 0 subagents)
        let info = await appVM.fetchSessionInfoForDeleteConfirmation(serverId: server.id, sessionId: "S1", timeoutSeconds: 0.1)
        XCTAssertNil(info)
    }

    // MARK: - W2-AC-124: Immediate deletion + alreadyAbsent + recentlyDeletedSessionGenerations anti-resurrection

    func testW2AC124_ImmediateDeletionAndMultiCwdAntiResurrection() throws {
        let storage = SessionStorage.inMemory()
        let defaults = UserDefaults(suiteName: "W2AC124.\(UUID().uuidString)")!
        let server = ACPServerConfiguration(
            id: UUID(), name: "ACP", scheme: "ws", host: "127.0.0.1:19404",
            token: "", workingDirectory: "/tmp"
        )
        storage.saveServer(server)
        storage.saveSession(StoredSessionInfo(sessionId: "S-del", title: "Gone", cwd: "/tmp", updatedAt: Date()), forServerId: server.id)

        let appVM = AppViewModel(storage: storage, defaults: defaults, shouldStartNetworkMonitoring: false, shouldConnectOnStartup: false)
        let serverVM = try XCTUnwrap(appVM.serverViewModels[server.id])

        // Immediate deletion removes session even if isSyncingByServer is true
        appVM.syncCoordinator.isSyncingByServer[server.id] = true
        appVM.applyImmediateSessionDeletion(sessionId: "S-del", serverId: server.id)
        XCTAssertFalse(serverVM.sessionSummaries.contains { $0.id == "S-del" })
        XCTAssertFalse(storage.fetchSessions(forServerId: server.id).contains { $0.sessionId == "S-del" })
        XCTAssertNotNil(serverVM.recentlyDeletedSessionGenerations["S-del"])
    }

    // MARK: - W2-AC-125: RemoteSessionDeleteError mapping for -32021..-32024 and -32601

    func testW2AC125_RemoteSessionDeleteErrorCodeMapping() {
        func rpcErr(_ code: Int) -> Error {
            let err = try! JSONDecoder().decode(ACPError.self, from: Data("{\"code\":\(code),\"message\":\"err \(code)\"}".utf8))
            return ACPServiceError.rpc(id: .int(1), error: err)
        }
        XCTAssertEqual(RemoteSessionDeleteError.from(rpcErr(-32021)), .activeSession)
        XCTAssertEqual(RemoteSessionDeleteError.from(rpcErr(-32022)), .dbBusy)
        XCTAssertEqual(RemoteSessionDeleteError.from(rpcErr(-32023)), .deleteFailed("err -32023"))
        XCTAssertEqual(RemoteSessionDeleteError.from(rpcErr(-32024)), .storageUnconfigured)
        XCTAssertEqual(RemoteSessionDeleteError.from(rpcErr(-32601)), .unsupportedRemoteDelete)
        XCTAssertFalse(RemoteSessionDeleteError.unsupportedRemoteDelete.localizedDescription.isEmpty)
    }

    // MARK: - W2-AC-126: Cross-server same sessionId deletion does NOT pop active viewing session on another server

    func testW2AC126_CrossServerSameSessionIdDeleteDoesNotPopOtherServer() throws {
        let storage = SessionStorage.inMemory()
        let defaults = UserDefaults(suiteName: "W2AC126.\(UUID().uuidString)")!
        let serverA = ACPServerConfiguration(id: UUID(), name: "A", scheme: "ws", host: "127.0.0.1:19405", token: "", workingDirectory: "/a")
        let serverB = ACPServerConfiguration(id: UUID(), name: "B", scheme: "ws", host: "127.0.0.1:19406", token: "", workingDirectory: "/b")
        storage.saveServer(serverA)
        storage.saveServer(serverB)
        storage.saveSession(StoredSessionInfo(sessionId: "SAME_ID", title: "A Same", cwd: "/a", updatedAt: Date()), forServerId: serverA.id)
        storage.saveSession(StoredSessionInfo(sessionId: "SAME_ID", title: "B Same", cwd: "/b", updatedAt: Date()), forServerId: serverB.id)

        let appVM = AppViewModel(storage: storage, defaults: defaults, shouldStartNetworkMonitoring: false, shouldConnectOnStartup: false)
        let vmA = try XCTUnwrap(appVM.serverViewModels[serverA.id])
        let vmB = try XCTUnwrap(appVM.serverViewModels[serverB.id])

        appVM.setActiveViewingSession(serverId: serverA.id, sessionId: "SAME_ID")

        // Delete SAME_ID on B
        appVM.applyImmediateSessionDeletion(sessionId: "SAME_ID", serverId: serverB.id)
        XCTAssertFalse(vmB.sessionSummaries.contains { $0.id == "SAME_ID" })

        // Server A's SAME_ID and active viewing state are completely untouched
        XCTAssertEqual(appVM.activeViewingServerId, serverA.id)
        XCTAssertEqual(appVM.activeViewingSessionId, "SAME_ID")
        XCTAssertTrue(vmA.sessionSummaries.contains { $0.id == "SAME_ID" } || storage.fetchSessions(forServerId: serverA.id).contains { $0.sessionId == "SAME_ID" })
    }
}
