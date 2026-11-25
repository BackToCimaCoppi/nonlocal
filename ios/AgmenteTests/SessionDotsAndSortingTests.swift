import XCTest
import CoreData
import ACP
@testable import Agmente
import ACPClient

@MainActor
final class SessionDotsAndSortingTests: XCTestCase {

    // MARK: - Minimal Test Doubles & Helpers

    private final class ScriptedSocket: WebSocketConnection, @unchecked Sendable {
        enum SocketError: Error { case closed }

        private let lock = NSLock()
        private var continuation: AsyncStream<Result<WebSocketEvent, Error>>.Continuation?
        private let stream: AsyncStream<Result<WebSocketEvent, Error>>
        private var recordedTexts: [String] = []

        var sentJSONObjects: [[String: Any]] {
            lock.lock()
            let copy = recordedTexts
            lock.unlock()
            return copy.compactMap { text in
                guard let data = text.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    return nil
                }
                return obj
            }
        }

        init() {
            var contRef: AsyncStream<Result<WebSocketEvent, Error>>.Continuation?
            self.stream = AsyncStream { continuation in
                contRef = continuation
            }
            self.continuation = contRef
        }

        func connect(headers: [String: String]) async throws {}

        func send(text: String) async throws {
            lock.lock()
            recordedTexts.append(text)
            lock.unlock()
        }

        func receive() async throws -> WebSocketEvent {
            for await item in stream {
                return try item.get()
            }
            throw SocketError.closed
        }

        func close() async {
            continuation?.finish()
        }

        func ping() async throws {}

        func enqueue(_ message: ACPWireMessage) throws {
            let data = try JSONEncoder().encode(message)
            let text = String(decoding: data, as: UTF8.self)
            continuation?.yield(.success(.text(text)))
        }

        func enqueueResponse(id: Any, result: ACP.Value) throws {
            let rpcId: ACP.ID = (id as? Int).map(ACP.ID.number) ?? .string(String(describing: id))
            try enqueue(.response(.init(id: rpcId, result: result)))
        }

        func simulateDrop() {
            continuation?.yield(.failure(SocketError.closed))
            continuation?.finish()
        }
    }

    private final class ScriptedSocketProvider: WebSocketProviding, @unchecked Sendable {
        private var sockets: [ScriptedSocket]
        private let lock = NSLock()

        init(_ sockets: [ScriptedSocket]) {
            self.sockets = sockets
        }

        func makeConnection(url: URL) -> WebSocketConnection {
            lock.lock()
            defer { lock.unlock() }
            if !sockets.isEmpty {
                return sockets.removeFirst()
            }
            return ScriptedSocket()
        }
    }

    private struct ACPHarness {
        let defaults: UserDefaults
        let storage: SessionStorage
        let sockets: [ScriptedSocket]
        let manager: ACPClientManager
        let appVM: AppViewModel
        let serverId: UUID
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "SessionDotsAndSortingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeACPHarness(
        storage: SessionStorage = .inMemory(),
        defaults: UserDefaults? = nil,
        sockets: [ScriptedSocket]? = nil,
        addDefaultServer: Bool = true
    ) -> ACPHarness {
        let usedDefaults = defaults ?? makeIsolatedDefaults()
        let usedSockets = sockets ?? [ScriptedSocket()]
        let provider = ScriptedSocketProvider(usedSockets)
        let manager = ACPClientManager(
            defaults: usedDefaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )
        let appVM = AppViewModel(
            storage: storage,
            defaults: usedDefaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        if addDefaultServer && appVM.selectedServerId == nil {
            appVM.addServer(
                name: "Test ACP",
                scheme: "ws",
                host: "127.0.0.1:8765",
                token: "",
                workingDirectory: "/repo"
            )
        }
        return ACPHarness(
            defaults: usedDefaults,
            storage: storage,
            sockets: usedSockets,
            manager: manager,
            appVM: appVM,
            serverId: appVM.selectedServerId ?? UUID()
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 4.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    private func connectACP(
        _ appVM: AppViewModel,
        socket: ScriptedSocket,
        loadSession: Bool = true,
        listSessions: Bool = true
    ) async throws {
        Task { @MainActor in
            if await appVM.connectAndWait() {
                _ = await appVM.initializeAndWait()
            }
        }
        try await waitUntil { socket.sentJSONObjects.contains { ($0["method"] as? String) == "initialize" } }
        let req = socket.sentJSONObjects.first { ($0["method"] as? String) == "initialize" }!
        try socket.enqueueResponse(
            id: req["id"]!,
            result: .object([
                "protocolVersion": .int(1),
                "agentInfo": .object(["name": .string("FakeAgy"), "version": .string("1.0")]),
                "agentCapabilities": .object([
                    "loadSession": .bool(loadSession),
                    "listSessions": .bool(listSessions)
                ])
            ])
        )
        try await waitUntil { appVM.connectionState == .connected }
    }

    private func respondSessionList(
        on socket: ScriptedSocket,
        sessions: [(id: String, title: String, cwd: String?, updatedAt: String?)],
        afterCount existingCount: Int = 0
    ) async throws {
        try await waitUntil {
            socket.sentJSONObjects.filter { ($0["method"] as? String) == "session/list" }.count > existingCount
        }
        let req = socket.sentJSONObjects.filter { ($0["method"] as? String) == "session/list" }.last!
        let array: [ACP.Value] = sessions.map { item in
            var dict: [String: ACP.Value] = [
                "sessionId": .string(item.id),
                "title": .string(item.title)
            ]
            if let cwd = item.cwd { dict["cwd"] = .string(cwd) }
            if let updatedAt = item.updatedAt { dict["updatedAt"] = .string(updatedAt) }
            return .object(dict)
        }
        try socket.enqueueResponse(id: req["id"]!, result: .object(["sessions": .array(array)]))
    }

    private func respondEmptySyncIfRequested(on socket: ScriptedSocket) async throws {
        try await Task.sleep(nanoseconds: 30_000_000)
        if let syncReq = socket.sentJSONObjects.first(where: { ($0["method"] as? String) == NonlocalMethods.sessionSync }) {
            try socket.enqueueResponse(
                id: syncReq["id"]!,
                result: .object([
                    "instanceId": .string("inst-test"),
                    "materializedSessionIds": .array([]),
                    "sessions": .array([])
                ])
            )
        }
    }

    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    // MARK: - AC-1, AC-2, AC-3 / SC-AC-051: Sorting Stability, Promotion & 3-state dot invariants

    func testAC1_AC2_StreamingMetaAndReplayNeverReorderSessions_AC3_PromptAndCompletionOvertake() async throws {
        let h = makeACPHarness()
        let sock = h.sockets[0]
        try await connectACP(h.appVM, socket: sock)
        try await respondEmptySyncIfRequested(on: sock)

        let tNew = Date().addingTimeInterval(-60)
        let tOld = Date().addingTimeInterval(-300)
        try await respondSessionList(on: sock, sessions: [
            (id: "S1", title: "First", cwd: "/repo", updatedAt: iso(tNew)),
            (id: "S2", title: "Second", cwd: "/repo", updatedAt: iso(tOld))
        ])

        let serverVM = h.appVM.selectedServerViewModel!
        try await waitUntil { serverVM.hasInitializedUnreadBaseline && serverVM.sessionSummaries.count == 2 }
        XCTAssertEqual(serverVM.sessionSummaries.map(\.id), ["S1", "S2"])
        let oldS2UpdatedAt = serverVM.sessionSummaries.first { $0.id == "S2" }?.updatedAt

        // AC-1: Streaming chunks & tool calls on S2 do not mutate updatedAt or reorder S2 above S1.
        let s2VM = serverVM.sessionViewModel(for: "S2")
        s2VM.startNewStreamingResponse()
        s2VM.handleSessionUpdateEvents([
            "sessionId": .string("S2"),
            "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("streaming...")])
            ])
        ], activeSessionId: "S2", serverId: h.serverId)
        s2VM.handleSessionUpdateEvents([
            "sessionId": .string("S2"),
            "update": .object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("tc-1"),
                "title": .string("Read"),
                "kind": .string("read"),
                "status": .string("in_progress")
            ])
        ], activeSessionId: "S2", serverId: h.serverId)
        XCTAssertEqual(serverVM.sessionSummaries.map(\.id), ["S1", "S2"])
        XCTAssertEqual(serverVM.sessionSummaries.first { $0.id == "S2" }?.updatedAt, oldS2UpdatedAt)

        // AC-2: sessionInfoDidUpdate & session/load replay never mutate updatedAt.
        s2VM.finishStreamingMessage()
        s2VM.beginHistoryReplay()
        s2VM.handleSessionUpdateEvents([
            "sessionId": .string("S2"),
            "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("replayed")])
            ])
        ], activeSessionId: "S2", serverId: h.serverId)
        s2VM.finishHistoryReplay()
        serverVM.sessionInfoDidUpdate(
            ACPSessionInfo(title: "Second Renamed", hasTitle: true, updatedAt: iso(Date().addingTimeInterval(500)), hasUpdatedAt: true),
            serverId: h.serverId,
            sessionId: "S2"
        )
        XCTAssertEqual(serverVM.sessionSummaries.map(\.id), ["S1", "S2"])
        XCTAssertEqual(serverVM.sessionSummaries.first { $0.id == "S2" }?.title, "Second Renamed")
        XCTAssertEqual(serverVM.sessionSummaries.first { $0.id == "S2" }?.updatedAt, oldS2UpdatedAt)

        // AC-3: sendPrompt promotes S2 to top (answer session/load first); then S1 completion overtakes S2.
        serverVM.setActiveSession("S2", cwd: "/repo", modes: nil)
        serverVM.sendPrompt(promptText: "Run S2", images: [])
        try await waitUntil { sock.sentJSONObjects.contains { ($0["method"] as? String) == "session/load" } }
        let loadReq = sock.sentJSONObjects.first { ($0["method"] as? String) == "session/load" }!
        try sock.enqueueResponse(id: loadReq["id"]!, result: .object(["sessionId": .string("S2")]))
        try await waitUntil { sock.sentJSONObjects.contains { ($0["method"] as? String) == "session/prompt" } }
        XCTAssertEqual(serverVM.sessionSummaries.first?.id, "S2")

        let s1Turn = serverVM.sessionViewModel(for: "S1")
        s1Turn.startNewStreamingResponse()
        s1Turn.appendAssistantText("Done S1", kind: .message)
        // Ensure at least 5ms elapsed so Date() strictly exceeds S2's prompt timestamp
        try await Task.sleep(nanoseconds: 5_000_000)
        s1Turn.handleStopReason("end_turn", serverId: h.serverId, sessionId: "S1")
        XCTAssertEqual(serverVM.sessionSummaries.first?.id, "S1")

        let promptReq = sock.sentJSONObjects.first { ($0["method"] as? String) == "session/prompt" }!
        try sock.enqueueResponse(id: promptReq["id"]!, result: .object(["stopReason": .string("end_turn")]))
        try await waitUntil { h.appVM.sessionRowStatus(for: "S2") == .unread }
    }

    // MARK: - AC-4: Folder Projection, Tie-Breaker & Cap-5

    func testAC4_FolderGroupingMax5TieBreakerAndPromotion() {
        let now = Date()
        let tEqual = now.addingTimeInterval(-100)
        var items = [
            ("/repo/beta", "b-1", "B1", tEqual),
            ("/repo/alpha", "a-1", "A1", tEqual),
            ("/repo/alpha", "a-2", "A2", now.addingTimeInterval(-200)),
            ("/repo/alpha", "a-3", "A3", now.addingTimeInterval(-300)),
            ("/repo/alpha", "a-4", "A4", now.addingTimeInterval(-400)),
            ("/repo/alpha", "a-5", "A5", now.addingTimeInterval(-500)),
            ("/repo/alpha", "a-6", "A6", now.addingTimeInterval(-600))
        ]

        let initial = SessionListProjection.groupByFolder(
            items.map { .init(id: $0.1, title: $0.2, cwd: $0.0, updatedAt: $0.3) },
            defaultCwd: nil
        ) { _ in .read }
        // Same max timestamp -> lexical tie-breaker /repo/alpha before /repo/beta
        XCTAssertEqual(initial.map(\.group.path), ["/repo/alpha", "/repo/beta"])
        XCTAssertEqual(initial[0].sessions.map(\.id), ["a-1", "a-2", "a-3", "a-4", "a-5"])
        XCTAssertTrue(initial[0].hasMore)
        XCTAssertFalse(initial[1].hasMore)

        // When /repo/beta receives a newer update, /repo/beta moves ahead of /repo/alpha.
        items[0].3 = now
        let after = SessionListProjection.groupByFolder(
            items.map { .init(id: $0.1, title: $0.2, cwd: $0.0, updatedAt: $0.3) },
            defaultCwd: nil
        ) { _ in .read }
        XCTAssertEqual(after.map(\.group.path), ["/repo/beta", "/repo/alpha"])
    }

    // MARK: - AC-5, AC-6, AC-7: Multi-Session Dots, Codex Disconnect & All Completion Paths

    func testAC5_AC6_MultiSessionConcurrentRunningAndPriority() async throws {
        let h = makeACPHarness()
        let sock = h.sockets[0]
        try await connectACP(h.appVM, socket: sock, loadSession: false)
        try await respondEmptySyncIfRequested(on: sock)

        let now = Date()
        try await respondSessionList(on: sock, sessions: [
            (id: "A", title: "A", cwd: "/repo", updatedAt: iso(now.addingTimeInterval(-20))),
            (id: "B", title: "B", cwd: "/repo", updatedAt: iso(now.addingTimeInterval(-40))),
            (id: "C", title: "C", cwd: "/repo", updatedAt: iso(now.addingTimeInterval(-60)))
        ])
        let serverVM = h.appVM.selectedServerViewModel!
        try await waitUntil { serverVM.hasInitializedUnreadBaseline }

        // Baseline: all 3 start read (0 unread, 0 running).
        XCTAssertEqual(h.appVM.runningSessionCount, 0)
        XCTAssertEqual(h.appVM.unreadSessionCount, 0)
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "A"), .read)
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "B"), .read)

        // Start running in both A and B concurrently while on list screen (activeViewingSessionId == nil).
        serverVM.sessionViewModel(for: "A").startNewStreamingResponse()
        serverVM.sessionViewModel(for: "B").startNewStreamingResponse()
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "A"), .running)
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "B"), .running)
        XCTAssertEqual(h.appVM.runningSessionCount, 2)
        XCTAssertEqual(h.appVM.unreadSessionCount, 0)

        // A finishes -> unread (green), B stays running (orange).
        serverVM.sessionViewModel(for: "A").handleStopReason("end_turn", serverId: h.serverId, sessionId: "A")
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "A"), .unread)
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "B"), .running)
        XCTAssertEqual(h.appVM.runningSessionCount, 1)
        XCTAssertEqual(h.appVM.unreadSessionCount, 1)

        // Unread A starts a new turn passively -> orange > green (and starting doesn't fake green).
        serverVM.sessionViewModel(for: "A").startNewStreamingResponse()
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "A"), .running)
        XCTAssertEqual(h.appVM.runningSessionCount, 2)
        XCTAssertEqual(h.appVM.unreadSessionCount, 0)

        // Mark B unread then sendPrompt from foreground/session -> sendPrompt clears unread & shows running.
        serverVM.sessionViewModel(for: "B").handleStopReason("end_turn", serverId: h.serverId, sessionId: "B")
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "B"), .unread)
        serverVM.setActiveSession("B", cwd: "/repo", modes: nil)
        serverVM.sendPrompt(promptText: "Follow-up", images: [])
        XCTAssertFalse(serverVM.isSessionUnread("B"))
        try await waitUntil { h.appVM.sessionRowStatus(for: "B") == .running }
    }

    func testAC7_ACPPassiveSettleAndUnresolvedToolTailSettle() async throws {
        let h = makeACPHarness()
        let sock = h.sockets[0]
        try await connectACP(h.appVM, socket: sock)
        try await respondEmptySyncIfRequested(on: sock)
        try await respondSessionList(on: sock, sessions: [
            (id: "P", title: "Passive", cwd: "/repo", updatedAt: iso(Date()))
        ])
        let serverVM = h.appVM.selectedServerViewModel!
        try await waitUntil { serverVM.hasInitializedUnreadBaseline }

        serverVM.passiveSettleDelays = .init(
            usageAfterMessageNs: 20_000_000,
            messageNs: 25_000_000,
            thoughtOrCompletedToolNs: 20_000_000,
            activeToolNs: 40_000_000
        )

        let pVM = serverVM.sessionViewModel(for: "P")
        // 1. Passive streaming chunk without prompt RPC -> running orange, then settles -> unread green
        pVM.handleSessionUpdateEvents([
            "sessionId": .string("P"),
            "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("passive note")])
            ])
        ], activeSessionId: "P", serverId: h.serverId)
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "P"), .running)
        try await waitUntil(timeout: 2.0) { h.appVM.sessionRowStatus(for: "P") == .unread }

        // Open & leave P to mark read
        h.appVM.setActiveViewingSession(serverId: h.serverId, sessionId: "P")
        h.appVM.setActiveViewingSession(serverId: h.serverId, sessionId: nil)
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "P"), .read)

        // 2. handleStopReason with hasUnresolvedToolCalls: true defers unread until tool tail finishes
        pVM.handleSessionUpdateEvents([
            "sessionId": .string("P"),
            "update": .object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("tc-tail"),
                "title": .string("Build"),
                "kind": .string("execute"),
                "status": .string("in_progress")
            ])
        ], activeSessionId: "P", serverId: h.serverId)
        pVM.handleStopReason("end_turn", hasUnresolvedToolCalls: true, notifyList: true, serverId: h.serverId, sessionId: "P")
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "P"), .running)

        pVM.handleSessionUpdateEvents([
            "sessionId": .string("P"),
            "update": .object([
                "sessionUpdate": .string("tool_call_update"),
                "toolCallId": .string("tc-tail"),
                "status": .string("completed")
            ])
        ], activeSessionId: "P", serverId: h.serverId)
        try await waitUntil(timeout: 2.0) { h.appVM.sessionRowStatus(for: "P") == .unread }
    }

    // MARK: - AC-8, AC-9, DEC-9: Cancel Anti-Zombie, Permission Isolation & Foreground Visibility

    func testAC8_AC9_DEC9_CancelAntiZombiePermissionIsolationAndForegroundRule() async throws {
        let h = makeACPHarness()
        let sock = h.sockets[0]
        try await connectACP(h.appVM, socket: sock)
        try await respondEmptySyncIfRequested(on: sock)

        let tOld = Date().addingTimeInterval(-120)
        try await respondSessionList(on: sock, sessions: [
            (id: "S-keep", title: "Top", cwd: "/repo", updatedAt: iso(Date().addingTimeInterval(-30))),
            (id: "S-bg", title: "BG", cwd: "/repo", updatedAt: iso(tOld))
        ])
        let serverVM = h.appVM.selectedServerViewModel!
        try await waitUntil { serverVM.hasInitializedUnreadBaseline }

        // User enters S-bg cleanly in foreground, receives permission -> hidden while foreground,
        // DEC-9: becomes unread green immediately when backing out to list while still pending!
        h.appVM.setActiveViewingSession(serverId: h.serverId, sessionId: "S-bg")
        serverVM.setActiveSession("S-bg", cwd: "/repo", modes: nil)
        let bgVM = serverVM.sessionViewModel(for: "S-bg")
        bgVM.startNewStreamingResponse()
        let permReq = ACP.AnyRequest(
            id: .string("perm-1"),
            method: "session/request_permission",
            params: .object([
                "sessionId": .string("S-bg"),
                "toolCall": .object(["toolCallId": .string("tc-p"), "title": .string("Run command"), "kind": .string("execute")]),
                "options": .array([.object(["optionId": .string("allow"), "name": .string("Allow"), "kind": .string("allow_once")])])
            ])
        )
        bgVM.handlePermissionRequest(permReq)
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "S-bg"), .read, "Foreground session hides dot while visible")

        // Back out to list before answering permission -> DEC-9 green + S-bg promoted above S-keep
        h.appVM.setActiveViewingSession(serverId: h.serverId, sessionId: nil)
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "S-bg"), .unread)
        XCTAssertEqual(serverVM.sessionSummaries.first?.id, "S-bg")

        // Call fetchSessionList explicitly with stale server timestamps; recent local pin preserves S-bg at top
        serverVM.fetchSessionList(force: true)
        try await respondSessionList(on: sock, sessions: [
            (id: "S-keep", title: "Top", cwd: "/repo", updatedAt: iso(Date().addingTimeInterval(-30))),
            (id: "S-bg", title: "BG", cwd: "/repo", updatedAt: iso(tOld))
        ], afterCount: 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(serverVM.sessionSummaries.first?.id, "S-bg")

        // Replying to permission transitions row back to running orange even if user isn't viewing it
        serverVM.sendPermissionResponse(requestId: .string("perm-1"), optionId: "allow")
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "S-bg"), .running)

        // User opens S-bg, cancels -> never lights green, and delayed stopReason: cancelled never resurrects green
        serverVM.noteUserCancelled(sessionId: "S-bg")
        bgVM.abandonStreamingMessage()
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "S-bg"), .read)
        bgVM.handleStopReason("cancelled", serverId: h.serverId, sessionId: "S-bg")
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "S-bg"), .read)

        // Non-cancel turn failure lights green and drops running
        bgVM.startNewStreamingResponse()
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "S-bg"), .running)
        bgVM.handleNonlocalTurnError("Bridge timeout", serverId: h.serverId, sessionId: "S-bg")
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "S-bg"), .unread)
    }

    // MARK: - AC-10, AC-11: Core Data SQLite Rebuild & Client Clock Pollute Prevention

    func testAC10_AC11_PersistenceAcrossSQLiteRebuildWithoutClientClockPollution() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ac11-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let sqliteURL = tmpDir.appendingPathComponent("store.sqlite")
        let defaults = makeIsolatedDefaults()

        // Launch 1: seed baseline & trigger background unread on "S-unread"
        do {
            let persistence = PersistenceController(inMemory: false, storeURL: sqliteURL)
            let storage = SessionStorage(container: persistence.container)
            let h = makeACPHarness(storage: storage, defaults: defaults)
            let sock = h.sockets[0]
            try await connectACP(h.appVM, socket: sock)
            try await respondEmptySyncIfRequested(on: sock)
            try await respondSessionList(on: sock, sessions: [
                (id: "S-unread", title: "Unread", cwd: "/repo", updatedAt: nil)
            ])
            let serverVM = h.appVM.selectedServerViewModel!
            try await waitUntil { serverVM.hasInitializedUnreadBaseline }

            // Mark S-unread unread WITHOUT any server updatedAt
            serverVM.sessionViewModel(for: "S-unread").handleStopReason("end_turn", serverId: h.serverId, sessionId: "S-unread")
            XCTAssertEqual(h.appVM.sessionRowStatus(for: "S-unread"), .unread)

            // No client Date() should pollute lastSeenServerUpdatedAt
            let storedBeforeRead = storage.fetchSessions(forServerId: h.serverId).first { $0.sessionId == "S-unread" }
            XCTAssertEqual(storedBeforeRead?.hasUnread, true)
        }

        // Launch 2: fresh PersistenceController + AppViewModel rebuilds from SQLite -> still unread!
        // Then user taps into S-unread -> marks read + sets absorbNextServerUpdatedAt WITHOUT writing client Date().
        do {
            let persistence = PersistenceController(inMemory: false, storeURL: sqliteURL)
            let storage = SessionStorage(container: persistence.container)
            let h = makeACPHarness(storage: storage, defaults: defaults, addDefaultServer: false)
            XCTAssertEqual(h.appVM.sessionRowStatus(for: "S-unread"), .unread)

            h.appVM.setActiveViewingSession(serverId: h.serverId, sessionId: "S-unread")
            XCTAssertEqual(h.appVM.sessionRowStatus(for: "S-unread"), .read)

            let storedAfterRead = storage.fetchSessions(forServerId: h.serverId).first { $0.sessionId == "S-unread" }
            XCTAssertEqual(storedAfterRead?.hasUnread, false)
            XCTAssertEqual(storedAfterRead?.absorbNextServerUpdatedAt, true)
            XCTAssertEqual(storedAfterRead?.lastSeenServerUpdatedAt, Date.distantPast, "Must retain baseline server watermark instead of client Date()")
        }

        // Launch 3: rebuild again -> read persists!
        do {
            let persistence = PersistenceController(inMemory: false, storeURL: sqliteURL)
            let storage = SessionStorage(container: persistence.container)
            let h = makeACPHarness(storage: storage, defaults: defaults, addDefaultServer: false)
            XCTAssertEqual(h.appVM.sessionRowStatus(for: "S-unread"), .read)
        }
    }

    // MARK: - AC-12: Real v1 -> v2 Core Data Migration + Concurrent nonlocal/sync Zero-Unread Baseline

    func testAC12_CoreDataV1ToV2MigrationAndConcurrentSyncZeroUnreadBaseline() async throws {
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("ac12-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let sqliteURL = tmpDir.appendingPathComponent("migrate.sqlite")
        let serverId = UUID()
        let defaults = makeIsolatedDefaults()
        let oldTime = Date().addingTimeInterval(-3600)

        // Seed raw v1 SQLite database using v1 managed object model
        do {
            let v1Model = try XCTUnwrap(PersistenceController.model(versionName: "Agmente"))
            let v1Persistence = PersistenceController(inMemory: false, storeURL: sqliteURL, managedObjectModel: v1Model)
            let ctx = v1Persistence.container.viewContext

            let serverObj = NSEntityDescription.insertNewObject(forEntityName: "StoredServer", into: ctx)
            serverObj.setValue(serverId, forKey: "id")
            serverObj.setValue("Migrated", forKey: "name")
            serverObj.setValue("ws", forKey: "scheme")
            serverObj.setValue("127.0.0.1:8765", forKey: "host")
            serverObj.setValue("/repo", forKey: "workingDirectory")
            serverObj.setValue("acp", forKey: "serverType")

            for sid in ["M1", "M2"] {
                let sObj = NSEntityDescription.insertNewObject(forEntityName: "StoredSession", into: ctx)
                sObj.setValue(sid, forKey: "sessionId")
                sObj.setValue("Session \(sid)", forKey: "title")
                sObj.setValue("/repo", forKey: "cwd")
                sObj.setValue(oldTime, forKey: "updatedAt")
                sObj.setValue(serverObj, forKey: "server")

                let mObj = NSEntityDescription.insertNewObject(forEntityName: "StoredMessage", into: ctx)
                mObj.setValue(UUID(), forKey: "messageId")
                mObj.setValue("assistant", forKey: "role")
                mObj.setValue("old reply", forKey: "content")
                mObj.setValue(oldTime, forKey: "createdAt")
                mObj.setValue(Int32(0), forKey: "orderIndex")
                mObj.setValue(sObj, forKey: "session")
            }
            try ctx.save()
        }

        // Open using v2 default PersistenceController -> automatic lightweight migration
        let v2Persistence = PersistenceController(inMemory: false, storeURL: sqliteURL)
        let storage = SessionStorage(container: v2Persistence.container)
        XCTAssertFalse(storage.isUnreadBaselineInitialized(forServerId: serverId))
        let migratedSessions = storage.fetchSessions(forServerId: serverId)
        XCTAssertEqual(migratedSessions.count, 2)
        XCTAssertTrue(migratedSessions.allSatisfy { !$0.hasUnread && $0.lastSeenServerUpdatedAt == nil && !$0.absorbNextServerUpdatedAt })
        let migratedMsgs = storage.fetchMessages(forSessionId: "M1", serverId: serverId)
        XCTAssertEqual(migratedMsgs.first?.isError, false)

        // Boot AppViewModel; simulate nonlocal/sync returning offline completed turns BEFORE session/list finishes
        let h = makeACPHarness(storage: storage, defaults: defaults, addDefaultServer: false)
        let sock = h.sockets[0]
        try await connectACP(h.appVM, socket: sock)

        try await waitUntil { sock.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let syncReq = sock.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        let syncTime = Date().addingTimeInterval(-30)
        try sock.enqueueResponse(
            id: syncReq["id"]!,
            result: .object([
                "instanceId": .string("inst-v2"),
                "materializedSessionIds": .array([]),
                "sessions": .array([
                    .object([
                        "sessionId": .string("M1"),
                        "lastActivityAt": .string(iso(syncTime)),
                        "latestTurn": .object([
                            "turnId": .string("t-m1"),
                            "status": .string("completed"),
                            "stopReason": .string("end_turn"),
                            "lastSeq": .int(1),
                            "truncated": .bool(false),
                            "events": .array([
                                .object([
                                    "seq": .int(1),
                                    "params": .object([
                                        "sessionId": .string("M1"),
                                        "update": .object([
                                            "sessionUpdate": .string("agent_message_chunk"),
                                            "content": .object(["type": .string("text"), "text": .string("caught up")])
                                        ])
                                    ])
                                ])
                            ])
                        ])
                    ]),
                    .object([
                        "sessionId": .string("M2"),
                        "lastActivityAt": .string(iso(syncTime)),
                        "latestTurn": .object([
                            "turnId": .string("t-m2"),
                            "status": .string("completed"),
                            "stopReason": .string("end_turn"),
                            "lastSeq": .int(0),
                            "truncated": .bool(false),
                            "events": .array([])
                        ])
                    ])
                ])
            ])
        )

        try await respondSessionList(on: sock, sessions: [
            (id: "M1", title: "Session M1", cwd: "/repo", updatedAt: iso(syncTime)),
            (id: "M2", title: "Session M2", cwd: "/repo", updatedAt: iso(syncTime))
        ])
        let serverVM = h.appVM.selectedServerViewModel!
        try await waitUntil { serverVM.hasInitializedUnreadBaseline }

        // First baseline after v1->v2 migration MUST have 0 green dots (M1, M2 both read)
        XCTAssertEqual(h.appVM.unreadSessionCount, 0)
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "M1"), .read)
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "M2"), .read)
    }

    // MARK: - AC-13: Remote UpdatedAt (>2s vs <=2s Jitter), session/new Absorb, Delete/Prune

    func testAC13_RemoteUpdatedAtDeltaAndNewSessionAbsorbAndPrune() async throws {
        let h = makeACPHarness()
        let sock = h.sockets[0]
        try await connectACP(h.appVM, socket: sock)
        try await respondEmptySyncIfRequested(on: sock)

        let baseTime = Date().addingTimeInterval(-600)
        try await respondSessionList(on: sock, sessions: [
            (id: "R1", title: "Remote", cwd: "/repo", updatedAt: iso(baseTime))
        ])
        let serverVM = h.appVM.selectedServerViewModel!
        try await waitUntil { serverVM.hasInitializedUnreadBaseline }
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "R1"), .read)

        // <= 2.0s precision jitter does NOT trigger false green
        serverVM.fetchSessionList(force: true)
        try await respondSessionList(on: sock, sessions: [
            (id: "R1", title: "Remote", cwd: "/repo", updatedAt: iso(baseTime.addingTimeInterval(1.2)))
        ], afterCount: 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "R1"), .read)

        // > 2.0s newer updatedAt triggers unread green
        serverVM.fetchSessionList(force: true)
        try await respondSessionList(on: sock, sessions: [
            (id: "R1", title: "Remote", cwd: "/repo", updatedAt: iso(baseTime.addingTimeInterval(10.0)))
        ], afterCount: 2)
        try await waitUntil { h.appVM.sessionRowStatus(for: "R1") == .unread }

        // session/new created locally absorbs its initial server updatedAt (never lights false green)
        h.appVM.sendNewSession(workingDirectory: "/repo")
        try await waitUntil { sock.sentJSONObjects.contains { ($0["method"] as? String) == "session/new" } }
        let newReq = sock.sentJSONObjects.first { ($0["method"] as? String) == "session/new" }!
        try sock.enqueueResponse(id: newReq["id"]!, result: .object(["sessionId": .string("NEW-1"), "cwd": .string("/repo")]))
        try await waitUntil { serverVM.selectedSessionId == "NEW-1" }
        // Leave NEW-1 then let server send its first timestamp for NEW-1 -> stays read!
        let new1InitialDate = Date()
        h.appVM.setActiveViewingSession(serverId: h.serverId, sessionId: nil)
        serverVM.fetchSessionList(force: true)
        try await respondSessionList(on: sock, sessions: [
            (id: "R1", title: "Remote", cwd: "/repo", updatedAt: iso(baseTime.addingTimeInterval(10.0))),
            (id: "NEW-1", title: "New Chat", cwd: "/repo", updatedAt: iso(new1InitialDate))
        ], afterCount: 3)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "NEW-1"), .read)

        // nonlocal/session_stale with > 2.0s newer updatedAt triggers unread green on NEW-1
        try sock.enqueue(.notification(.init(
            method: NonlocalMethods.sessionStale,
            params: .object([
                "instanceId": .string("inst-test"),
                "sessionId": .string("NEW-1"),
                "reason": .string("external_activity"),
                "updatedAt": .string(iso(new1InitialDate.addingTimeInterval(12.0)))
            ])
        )))
        try await waitUntil { h.appVM.sessionRowStatus(for: "NEW-1") == .unread }

        // Deleting/pruning R1 clears unread + Core Data StoredSession
        serverVM.deleteSession("R1")
        XCTAssertFalse(serverVM.isSessionUnread("R1"))
        XCTAssertNil(h.storage.fetchSessions(forServerId: h.serverId).first { $0.sessionId == "R1" })
    }

    // MARK: - W2-AC-402: #4a old session green-dot anti-resurrection & non-selected server stale green dot

    func testW2AC402_OldSessionDoesNotResurrectUnreadAndNonSelectedServerStaleMarksUnread() async throws {
        let baseTime = Date(timeIntervalSince1970: 1_760_100_000)
        let h = makeACPHarness()
        let sock = h.sockets[0]
        let serverVM = try XCTUnwrap(h.appVM.selectedServerViewModel)

        // Seed already-read OLD1 with updatedAt = baseTime
        h.storage.saveSession(
            StoredSessionInfo(sessionId: "OLD1", title: "Old Session", cwd: "/repo", updatedAt: baseTime),
            forServerId: h.serverId
        )
        serverVM.loadCachedSessions()

        // Connect & respond to nonlocal/sync where legacy bridge sends lastActivityAt = now on OLD1 with NO turn and NOT stale
        try await connectACP(h.appVM, socket: sock)
        try await waitUntil { sock.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let syncReq = try XCTUnwrap(sock.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync })
        try sock.enqueueResponse(id: syncReq["id"]!, result: .object([
            "instanceId": .string("inst-w2ac402"),
            "materializedSessionIds": .array([.string("OLD1")]),
            "staleSessionIds": .array([]),
            "sessions": .array([
                .object([
                    "sessionId": .string("OLD1"),
                    "lastActivityAt": .string(iso(baseTime.addingTimeInterval(600)))
                ])
            ])
        ]))
        try await respondSessionList(on: sock, sessions: [
            (id: "OLD1", title: "Old Session", cwd: "/repo", updatedAt: iso(baseTime))
        ])
        try await waitUntil { serverVM.hasInitializedUnreadBaseline }

        // OLD1 must NOT resurrect unread green dot or bump updatedAt
        XCTAssertEqual(h.appVM.sessionRowStatus(for: "OLD1"), .read, "Non-stale session without turn must NOT resurrect unread dot")
        XCTAssertEqual(serverVM.sessionSummaries.first(where: { $0.id == "OLD1" })?.updatedAt, baseTime)

        // Real nonlocal/session_stale DOES mark unread and advance updatedAt
        try sock.enqueue(.notification(.init(
            method: NonlocalMethods.sessionStale,
            params: .object([
                "instanceId": .string("inst-w2ac402"),
                "sessionId": .string("OLD1"),
                "reason": .string("external_activity"),
                "updatedAt": .string(iso(baseTime.addingTimeInterval(600)))
            ])
        )))
        try await waitUntil { h.appVM.sessionRowStatus(for: "OLD1") == .unread }
    }
}
