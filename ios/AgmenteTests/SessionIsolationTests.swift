import XCTest
import ACP
@testable import Agmente
import ACPClient

/// Phase 1 & 2 tests for per-session SessionViewModel isolation.
/// These tests verify that the bug described in issue #16 is fixed:
/// tool confirmations stay with their session when switching sessions.
///
/// Phase 2 changes: SessionViewModels are now managed by ServerViewModel,
/// so tests verify behavior through currentSessionViewModel rather than
/// accessing internal dictionaries directly.
@MainActor
final class SessionIsolationTests: XCTestCase {

    // MARK: - Test Infrastructure

    private var model: AppViewModel!
    private var testServerId: UUID!

    override func setUp() {
        super.setUp()
        // Create a test instance without auto-connect
        model = AppViewModel(
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )

        // Phase 2: Add a test server so currentSessionViewModel works
        model.addServer(
            name: "Test Server",
            scheme: "ws",
            host: "localhost:9999",
            token: "",
            workingDirectory: "/tmp"
        )
        // The addServer method selects the server and sets selectedServerId
        testServerId = model.selectedServerId!
    }

    override func tearDown() {
        model = nil
        testServerId = nil
        super.tearDown()
    }

    // MARK: - Phase 1 & 2: Session Isolation Tests

    /// Test that tool confirmation requests stay with their session when switching sessions.
    /// This is the core bug that Phase 1 fixes.
    func testToolConfirmation_StaysWithSession() {
        // Given: Two sessions
        let sessionIdA = "session-a"
        let sessionIdB = "session-b"

        // Create view models for both sessions by switching to them
        model.selectedServerViewModel?.selectedSessionId = sessionIdA
        let viewModelA = model.selectedServerViewModel?.currentSessionViewModel
        XCTAssertNotNil(viewModelA, "ViewModelA should be created")

        model.selectedServerViewModel?.selectedSessionId = sessionIdB
        let viewModelB = model.selectedServerViewModel?.currentSessionViewModel
        XCTAssertNotNil(viewModelB, "ViewModelB should be created")

        // Verify they are different instances
        XCTAssertFalse(viewModelA === viewModelB, "Each session should have its own ViewModel instance")

        // When: Add a pending permission request to session A
        model.selectedServerViewModel?.selectedSessionId = sessionIdA
        // Simulate permission request (would normally come from handlePermissionRequest)
        let mockRequest = ACP.AnyRequest(
            id: .string("req-1"),
            method: "acp/permission/request",
            params: .object([
                "sessionId": .string(sessionIdA),
                "toolCallId": .string("tool-1"),
                "title": .string("Read file"),
                "kind": .string("read"),
                "options": .array([
                    .object([
                        "id": .string("allow"),
                        "name": .string("Allow")
                    ])
                ])
            ])
        )
        viewModelA?.handlePermissionRequest(mockRequest)

        // Then: Switch to session B
        model.selectedServerViewModel?.selectedSessionId = sessionIdB

        // Verify: Session B's view model should be different from A
        let currentViewModelB = model.selectedServerViewModel?.currentSessionViewModel
        XCTAssertNotNil(currentViewModelB, "Session B's view model should exist")
        XCTAssertFalse(viewModelA === currentViewModelB, "View models should remain distinct")

        // Switch back to session A
        model.selectedServerViewModel?.selectedSessionId = sessionIdA

        // Verify: Session A's view model is restored (same instance)
        let currentViewModelA = model.selectedServerViewModel?.currentSessionViewModel
        XCTAssertTrue(viewModelA === currentViewModelA, "Session A should return the same view model instance")
    }

    /// Test that chat messages are preserved when switching sessions.
    func testSessionSwitch_PreservesMessages() {
        let sessionIdA = "session-a"
        let sessionIdB = "session-b"

        // Session A: Add messages
        model.selectedServerViewModel?.selectedSessionId = sessionIdA
        if let viewModelA = model.selectedServerViewModel?.currentSessionViewModel {
            viewModelA.setSessionContext(serverId: testServerId, sessionId: sessionIdA)
            viewModelA.addUserMessage(content: "Message in session A", images: [])
        }

        // Verify session A has 1 message
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.count, 1)
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.first?.content, "Message in session A")

        // Session B: Add different message
        model.selectedServerViewModel?.selectedSessionId = sessionIdB
        if let viewModelB = model.selectedServerViewModel?.currentSessionViewModel {
            viewModelB.setSessionContext(serverId: testServerId, sessionId: sessionIdB)
            viewModelB.addUserMessage(content: "Message in session B", images: [])
        }

        // Verify session B has 1 message
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.count, 1)
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.first?.content, "Message in session B")

        // Switch back to session A
        model.selectedServerViewModel?.selectedSessionId = sessionIdA

        // Verify session A still has its original message
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.count, 1)
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.first?.content, "Message in session A")
    }

    /// Test that placeholder session IDs are properly migrated to resolved IDs.
    /// Note: In Phase 2, migration is handled internally by ServerViewModel.
    /// This test verifies the behavior through currentSessionViewModel.
    func testPlaceholderMigration_PreservesViewModel() {
        let placeholderId = "placeholder-123"

        // Create a session with placeholder ID
        model.selectedServerViewModel?.selectedSessionId = placeholderId
        if let viewModel = model.selectedServerViewModel?.currentSessionViewModel {
            viewModel.setSessionContext(serverId: testServerId, sessionId: placeholderId)
            viewModel.addUserMessage(content: "Message in placeholder", images: [])
        }

        // Capture the view model reference
        let originalViewModel = model.selectedServerViewModel?.currentSessionViewModel
        XCTAssertNotNil(originalViewModel)

        // Verify messages are present
        XCTAssertEqual(originalViewModel?.chatMessages.count, 1)
        XCTAssertEqual(originalViewModel?.chatMessages.first?.content, "Message in placeholder")

        // Switch away and back
        model.selectedServerViewModel?.selectedSessionId = "other-session"
        model.selectedServerViewModel?.selectedSessionId = placeholderId

        // Verify the same view model is returned (instance preserved)
        let restoredViewModel = model.selectedServerViewModel?.currentSessionViewModel
        XCTAssertTrue(originalViewModel === restoredViewModel, "Should be the same view model instance")

        // Verify messages are preserved
        XCTAssertEqual(restoredViewModel?.chatMessages.count, 1)
        XCTAssertEqual(restoredViewModel?.chatMessages.first?.content, "Message in placeholder")
    }

    /// Test that deleting a session cleans up its view model.
    func testDeleteSession_CleansUpViewModel() {
        let sessionId = "session-to-delete"

        // Create a session view model
        model.selectedServerViewModel?.selectedSessionId = sessionId
        let viewModel = model.selectedServerViewModel?.currentSessionViewModel
        XCTAssertNotNil(viewModel, "View model should be created")

        // Add a message to the session to verify it exists
        viewModel?.setSessionContext(serverId: testServerId, sessionId: sessionId)
        viewModel?.addUserMessage(content: "Test message", images: [])
        XCTAssertEqual(viewModel?.chatMessages.count, 1)

        // Delete the session
        model.deleteSession(sessionId)

        // After deleting the selected session, selecting it again should give a fresh view model
        // (The old view model instance should be cleaned up)
        model.selectedServerViewModel?.selectedSessionId = sessionId
        let newViewModel = model.selectedServerViewModel?.currentSessionViewModel

        // New view model should have no messages (fresh instance)
        XCTAssertEqual(newViewModel?.chatMessages.count ?? 0, 0, "New view model should be fresh with no messages")
    }

    /// Test that current mode is isolated per session.
    func testCurrentMode_IsolatedPerSession() {
        let sessionIdA = "session-a"
        let sessionIdB = "session-b"

        // Session A: Set mode to "code"
        model.selectedServerViewModel?.selectedSessionId = sessionIdA
        model.selectedServerViewModel?.currentSessionViewModel?.setSessionContext(serverId: testServerId, sessionId: sessionIdA)
        model.selectedServerViewModel?.currentSessionViewModel?.setCurrentModeId("code")
        model.selectedServerViewModel?.currentSessionViewModel?.cacheCurrentMode(serverId: testServerId, sessionId: sessionIdA)

        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.currentModeId, "code")

        // Session B: Set mode to "ask"
        model.selectedServerViewModel?.selectedSessionId = sessionIdB
        model.selectedServerViewModel?.currentSessionViewModel?.setSessionContext(serverId: testServerId, sessionId: sessionIdB)
        model.selectedServerViewModel?.currentSessionViewModel?.setCurrentModeId("ask")
        model.selectedServerViewModel?.currentSessionViewModel?.cacheCurrentMode(serverId: testServerId, sessionId: sessionIdB)

        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.currentModeId, "ask")

        // Switch back to session A
        model.selectedServerViewModel?.selectedSessionId = sessionIdA

        // Verify session A still has "code" mode
        XCTAssertEqual(model.selectedServerViewModel?.currentSessionViewModel?.currentModeId, "code")
    }

    /// Test that streaming state is isolated per session.
    func testStreamingState_IsolatedPerSession() {
        let sessionIdA = "session-a"
        let sessionIdB = "session-b"

        // Session A: Start streaming
        model.selectedServerViewModel?.selectedSessionId = sessionIdA
        model.selectedServerViewModel?.currentSessionViewModel?.setSessionContext(serverId: testServerId, sessionId: sessionIdA)
        model.selectedServerViewModel?.currentSessionViewModel?.startNewStreamingResponse()

        XCTAssertTrue(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.last?.isStreaming ?? false)

        // Session B: Add non-streaming message
        model.selectedServerViewModel?.selectedSessionId = sessionIdB
        model.selectedServerViewModel?.currentSessionViewModel?.setSessionContext(serverId: testServerId, sessionId: sessionIdB)
        model.selectedServerViewModel?.currentSessionViewModel?.addUserMessage(content: "Complete message", images: [])

        XCTAssertFalse(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.last?.isStreaming ?? true)

        // Switch back to session A
        model.selectedServerViewModel?.selectedSessionId = sessionIdA

        // Verify session A still has streaming message
        XCTAssertTrue(model.selectedServerViewModel?.currentSessionViewModel?.chatMessages.last?.isStreaming ?? false)
    }

    /// Test that composer draft text is isolated per session (and therefore per window/session VM).
    func testPromptText_IsolatedPerSession() {
        let sessionIdA = "session-a"
        let sessionIdB = "session-b"

        model.selectedServerViewModel?.selectedSessionId = sessionIdA
        model.selectedServerViewModel?.currentSessionViewModel?.promptText = "draft for A"

        model.selectedServerViewModel?.selectedSessionId = sessionIdB
        model.selectedServerViewModel?.currentSessionViewModel?.promptText = "draft for B"

        model.selectedServerViewModel?.selectedSessionId = sessionIdA
        XCTAssertEqual(
            model.selectedServerViewModel?.currentSessionViewModel?.promptText,
            "draft for A"
        )

        model.selectedServerViewModel?.selectedSessionId = sessionIdB
        XCTAssertEqual(
            model.selectedServerViewModel?.currentSessionViewModel?.promptText,
            "draft for B"
        )
    }

    /// Test that view models are lazily created.
    func testViewModelCreation_IsLazy() {
        let sessionId = "lazy-session"

        // With test server selected but no session, currentSessionViewModel returns nil
        // because there's no selectedSessionId yet (we set one in setUp but let's test with a new one)
        model.selectedServerViewModel?.selectedSessionId = nil
        XCTAssertNil(model.selectedServerViewModel?.currentSessionViewModel, "No view model without selected session")

        // Access currentSessionViewModel (should create it)
        model.selectedServerViewModel?.selectedSessionId = sessionId
        let viewModel = model.selectedServerViewModel?.currentSessionViewModel

        XCTAssertNotNil(viewModel, "View model should be created on first access")
    }

    /// Test that multiple sessions can coexist with their own state.
    func testMultipleSessions_CoexistWithIsolatedState() {
        let sessions = ["session-1", "session-2", "session-3"]
        var viewModels: [String: ACPSessionViewModel] = [:]

        // Create and populate multiple sessions
        for (index, sessionId) in sessions.enumerated() {
            model.selectedServerViewModel?.selectedSessionId = sessionId
            if let viewModel = model.selectedServerViewModel?.currentSessionViewModel {
                viewModel.setSessionContext(serverId: testServerId, sessionId: sessionId)
                viewModel.addUserMessage(content: "Message \(index + 1)", images: [])
                viewModel.setCurrentModeId("mode-\(index + 1)")
                viewModels[sessionId] = viewModel
            }
        }

        // Verify all sessions were created
        XCTAssertEqual(viewModels.count, 3)

        // Verify each session has its own state by switching to each
        for (index, sessionId) in sessions.enumerated() {
            model.selectedServerViewModel?.selectedSessionId = sessionId
            let viewModel = model.selectedServerViewModel?.currentSessionViewModel
            XCTAssertNotNil(viewModel)
            XCTAssertEqual(viewModel?.chatMessages.count, 1)
            XCTAssertEqual(viewModel?.chatMessages.first?.content, "Message \(index + 1)")
            XCTAssertEqual(viewModel?.currentModeId, "mode-\(index + 1)")

            // Verify it's the same instance we created earlier
            XCTAssertTrue(viewModel === viewModels[sessionId], "Should return the same view model instance")
        }
    }

    /// Test that isStreaming computed property works correctly with per-session view models.
    func testIsStreaming_ReflectsCurrentSession() {
        let streamingSessionId = "streaming-session"
        let idleSessionId = "idle-session"

        // Streaming session: Add streaming message
        model.selectedServerViewModel?.selectedSessionId = streamingSessionId
        model.selectedServerViewModel?.currentSessionViewModel?.setSessionContext(serverId: testServerId, sessionId: streamingSessionId)
        model.selectedServerViewModel?.currentSessionViewModel?.startNewStreamingResponse()

        XCTAssertTrue(model.selectedServerViewModel?.isStreaming ?? false, "Should be streaming when current session has streaming message")

        // Idle session: Add complete message
        model.selectedServerViewModel?.selectedSessionId = idleSessionId
        model.selectedServerViewModel?.currentSessionViewModel?.setSessionContext(serverId: testServerId, sessionId: idleSessionId)
        model.selectedServerViewModel?.currentSessionViewModel?.addUserMessage(content: "Complete", images: [])

        XCTAssertFalse(model.selectedServerViewModel?.isStreaming ?? false, "Should not be streaming when current session has no streaming messages")

        // Switch back to streaming session
        model.selectedServerViewModel?.selectedSessionId = streamingSessionId

        XCTAssertTrue(model.selectedServerViewModel?.isStreaming ?? false, "Should be streaming again when switching back to streaming session")
    }

    // MARK: - P0-AC-4 / P0-AC-5 / P0-AC-6 Nonlocal Sync & Multi-Session Isolation

    private final class ScriptedWebSocketConnection: WebSocketConnection, @unchecked Sendable {
        enum ConnectionError: Error {
            case closed
        }

        private let lock = NSLock()
        private var continuation: AsyncStream<Result<WebSocketEvent, Error>>.Continuation?
        private let stream: AsyncStream<Result<WebSocketEvent, Error>>
        private var recordedTexts: [String] = []
        var failSendError: Error?

        var sentTexts: [String] {
            lock.lock()
            defer { lock.unlock() }
            return recordedTexts
        }

        var sentJSONObjects: [[String: Any]] {
            sentTexts.compactMap { text in
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
            if let failSendError {
                throw failSendError
            }
            lock.lock()
            recordedTexts.append(text)
            lock.unlock()
        }

        func receive() async throws -> WebSocketEvent {
            for await item in stream {
                return try item.get()
            }
            throw ConnectionError.closed
        }

        func close() async {
            continuation?.yield(.resolvedClose)
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

        func enqueueError(id: Any, code: Int, message: String) throws {
            let rpcId: ACP.ID = (id as? Int).map(ACP.ID.number) ?? .string(String(describing: id))
            try enqueue(.response(.init(id: rpcId, error: ACPError.from(code: code, message: message))))
        }

        func simulateDrop() {
            continuation?.yield(.failure(ConnectionError.closed))
            continuation?.finish()
        }
    }

    private final class ScriptedSocketProvider: WebSocketProviding, @unchecked Sendable {
        private let nextConnectionProvider: () -> ScriptedWebSocketConnection

        init(connections: [ScriptedWebSocketConnection]) {
            var remaining = connections
            self.nextConnectionProvider = {
                if !remaining.isEmpty {
                    return remaining.removeFirst()
                }
                return ScriptedWebSocketConnection()
            }
        }

        func makeConnection(url: URL) -> WebSocketConnection {
            nextConnectionProvider()
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        XCTFail("Timed out waiting for condition after \(timeout)s", file: file, line: line)
    }

    private func makeHydrogenConfigOptions(
        modelValue: String = "gemini-4-hydrogen",
        thoughtValue: String = "xhigh"
    ) -> [ACP.Value] {
        [
            .object([
                "id": .string("model"),
                "name": .string("Model"),
                "type": .string("select"),
                "currentValue": .string(modelValue),
                "options": .array([
                    .object(["value": .string("gemini-4-argon"), "name": .string("Gemini 4 Argon")]),
                    .object(["value": .string("gemini-4-hydrogen"), "name": .string("Gemini 4 Hydrogen")])
                ])
            ]),
            .object([
                "id": .string("thought_level"),
                "name": .string("Thought Level"),
                "type": .string("select"),
                "currentValue": .string(thoughtValue),
                "options": .array([
                    .object(["value": .string("medium"), "name": .string("Medium")]),
                    .object(["value": .string("xhigh"), "name": .string("Extra High")])
                ])
            ])
        ]
    }

    private func beginConnectAndInitialize(_ appVM: AppViewModel) {
        Task { @MainActor in
            let connected = await appVM.connectAndWait()
            if connected {
                _ = await appVM.initializeAndWait()
            }
        }
    }

    private func respondInitialize(
        on conn: ScriptedWebSocketConnection,
        loadSession: Bool = true
    ) async throws {
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == "initialize" } }
        let req = conn.sentJSONObjects.first { ($0["method"] as? String) == "initialize" }!
        try conn.enqueueResponse(
            id: req["id"]!,
            result: .object([
                "protocolVersion": .int(1),
                "agentInfo": .object(["name": .string("FakeAgy"), "version": .string("1.5.9")]),
                "agentCapabilities": .object(["loadSession": .bool(loadSession)])
            ])
        )
    }

    func testP0AC4_And_P0AC5_MultiSessionIsolation_ConfigPreservation_And_CoreDataIsolation() async throws {
        let suiteName = "P0AC4_5.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let storage = SessionStorage.inMemory()
        let conn = ScriptedWebSocketConnection()
        let provider = ScriptedSocketProvider(connections: [conn])
        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )

        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        appVM.addServer(
            name: "Isolated ACP",
            scheme: "ws",
            host: "127.0.0.1:18080",
            token: "tok",
            workingDirectory: "/tmp"
        )
        let serverId = try XCTUnwrap(appVM.selectedServerId)
        let serverVM = try XCTUnwrap(appVM.selectedServerViewModel)

        // Seed session B history in in-memory Core Data BEFORE connecting (P0-AC-5 baseline)
        storage.saveSession(StoredSessionInfo(sessionId: "sess-b", title: "Session B", cwd: "/tmp", updatedAt: Date()), forServerId: serverId)
        storage.saveMessages(
            [StoredMessageInfo(messageId: UUID(), role: "assistant", content: "Existing B message", createdAt: Date(), segmentsData: nil)],
            forSessionId: "sess-b",
            serverId: serverId
        )

        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: conn)
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let syncReq = conn.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try conn.enqueueResponse(id: syncReq["id"]!, result: .object([
            "instanceId": .string("inst-ac4-1"),
            "materializedSessionIds": .array([.string("sess-b")]),
            "sessions": .array([.object(["sessionId": .string("sess-b")])])
        ]))
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == "session/list" } }
        let listReq = conn.sentJSONObjects.first { ($0["method"] as? String) == "session/list" }!
        try conn.enqueueResponse(id: listReq["id"]!, result: .object([
            "sessions": .array([.object(["sessionId": .string("sess-b"), "title": .string("Session B"), "cwd": .string("/tmp")])])
        ]))

        // (1) Create empty session A -> Hydrogen configOptions applied; switch A -> B -> A preserves A's configOptions
        appVM.sendNewSession(workingDirectory: "/tmp")
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == "session/new" } }
        let newReqA = conn.sentJSONObjects.first { ($0["method"] as? String) == "session/new" }!
        try conn.enqueueResponse(
            id: newReqA["id"]!,
            result: .object([
                "sessionId": .string("sess-a"),
                "cwd": .string("/tmp"),
                "configOptions": .array(makeHydrogenConfigOptions())
            ])
        )
        try await waitUntil {
            serverVM.selectedSessionId == "sess-a"
                && (serverVM.existingSessionViewModel(for: "sess-a")?.visibleConfigOptions().count ?? 0) == 2
        }

        // Open B (re-loads Existing B message via session/load since historical B had no active turn/memory) then switch back to empty A
        appVM.openSession("sess-b")
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == "session/load" } }
        let loadBReq = conn.sentJSONObjects.first { ($0["method"] as? String) == "session/load" }!
        try conn.enqueue(.notification(.init(method: "session/update", params: .object([
            "sessionId": .string("sess-b"),
            "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("Existing B message")])])
        ]))))
        try conn.enqueueResponse(id: loadBReq["id"]!, result: .object([:]))
        try await waitUntil {
            serverVM.selectedSessionId == "sess-b"
                && serverVM.currentSessionViewModel?.chatMessages.map(\.content) == ["Existing B message"]
                && !(serverVM.currentSessionViewModel?.isStreaming ?? true)
        }
        appVM.openSession("sess-a")
        try await waitUntil { serverVM.selectedSessionId == "sess-a" }

        let vmA = try XCTUnwrap(serverVM.existingSessionViewModel(for: "sess-a"))
        XCTAssertEqual(vmA.visibleConfigOptions().map(\.id), ["model", "thought_level"])
        XCTAssertEqual(vmA.visibleConfigOptions().first(where: { $0.id == "model" })?.currentValue.stringValue, "gemini-4-hydrogen")
        XCTAssertEqual(vmA.visibleConfigOptions().first(where: { $0.id == "thought_level" })?.currentValue.stringValue, "xhigh")

        // (2) Send prompt in A, immediately switch foreground to B while A streams, requests permission, replies, and completes
        serverVM.sendPrompt(promptText: "Question for A", images: [])
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == "session/prompt" } }
        appVM.openSession("sess-b")
        XCTAssertEqual(serverVM.selectedSessionId, "sess-b")

        let promptReqA = conn.sentJSONObjects.first { ($0["method"] as? String) == "session/prompt" }!
        XCTAssertEqual((promptReqA["params"] as? [String: Any])?["sessionId"] as? String, "sess-a")

        for chunk in ["AnswerPart1_", "AnswerPart2_"] {
            try conn.enqueue(.notification(.init(method: "session/update", params: .object([
                "sessionId": .string("sess-a"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string(chunk)])
                ])
            ]))))
        }
        try conn.enqueue(.request(.init(
            id: .string("perm-bg-a"),
            method: "session/request_permission",
            params: .object([
                "sessionId": .string("sess-a"),
                "toolCall": .object(["toolCallId": .string("tc-bg-a"), "title": .string("shell"), "kind": .string("execute")]),
                "options": .array([.object(["optionId": .string("allow_once"), "name": .string("Allow"), "kind": .string("allow_once")])])
            ])
        )))

        try await waitUntil { vmA.ownsPermissionRequest(.string("perm-bg-a")) }
        XCTAssertEqual(serverVM.selectedSessionId, "sess-b", "Foreground must remain on B during background stream & permission")

        // Send permission response for A while viewing B
        appVM.sendPermissionResponse(requestId: ACP.ID.string("perm-bg-a"), optionId: "allow_once")
        try await waitUntil { conn.sentJSONObjects.contains { ($0["id"] as? String) == "perm-bg-a" } }

        try conn.enqueue(.notification(.init(method: "session/update", params: .object([
            "sessionId": .string("sess-a"),
            "update": .object([
                "sessionUpdate": .string("agent_message_chunk"),
                "content": .object(["type": .string("text"), "text": .string("AnswerPart3_")])
            ])
        ]))))
        try conn.enqueueResponse(id: promptReqA["id"]!, result: .object(["stopReason": .string("end_turn")]))

        try await waitUntil { !vmA.isStreaming && (vmA.chatMessages.last?.content.contains("AnswerPart3_") ?? false) }

        let vmB = try XCTUnwrap(serverVM.existingSessionViewModel(for: "sess-b"))
        XCTAssertEqual(serverVM.selectedSessionId, "sess-b")
        XCTAssertEqual(vmB.chatMessages.map(\.content), ["Existing B message"])
        XCTAssertFalse(vmB.isStreaming)
        XCTAssertEqual(serverVM.sessionSummaries.first(where: { $0.id == "sess-b" })?.title, "Session B")
        XCTAssertFalse(vmA.ownsPermissionRequest(.string("perm-bg-a")))

        // P0-AC-5: Verify Core Data persistence is strictly scoped to each sessionId and strips ACP process steps
        let persistedA = storage.fetchMessages(forSessionId: "sess-a", serverId: serverId)
        let persistedB = storage.fetchMessages(forSessionId: "sess-b", serverId: serverId)
        XCTAssertEqual(
            persistedA.map(\.content),
            ["Question for A", "AnswerPart1_AnswerPart2_AnswerPart3_"]
        )
        XCTAssertEqual(persistedB.map(\.content), ["Existing B message"])

        // (3) Background prompt RPC error targets A only; background session/new does NOT steal focus from B
        appVM.openSession("sess-a")
        serverVM.sendPrompt(promptText: "Trigger error on A", images: [])
        try await waitUntil { conn.sentJSONObjects.filter { ($0["method"] as? String) == "session/prompt" }.count == 2 }
        appVM.openSession("sess-b")
        let errPromptReq = conn.sentJSONObjects.filter { ($0["method"] as? String) == "session/prompt" }.last!
        try conn.enqueueError(id: errPromptReq["id"]!, code: -32603, message: "Backend boom")
        try await waitUntil { !vmA.isStreaming && vmA.chatMessages.contains(where: { $0.isError && $0.content.contains("Backend boom") }) }
        XCTAssertEqual(serverVM.selectedSessionId, "sess-b")
        XCTAssertEqual(vmB.chatMessages.map(\.content), ["Existing B message"])

        // Background session/new placeholder resolution does NOT steal foreground focus from B and preserves configOptions
        appVM.sendNewSession(workingDirectory: "/tmp")
        try await waitUntil { conn.sentJSONObjects.filter { ($0["method"] as? String) == "session/new" }.count == 2 }
        appVM.openSession("sess-b")
        let newReqC = conn.sentJSONObjects.filter { ($0["method"] as? String) == "session/new" }.last!
        try conn.enqueueResponse(
            id: newReqC["id"]!,
            result: .object([
                "sessionId": .string("sess-c"),
                "cwd": .string("/tmp"),
                "configOptions": .array(makeHydrogenConfigOptions())
            ])
        )
        try await waitUntil { (serverVM.existingSessionViewModel(for: "sess-c")?.visibleConfigOptions().count ?? 0) == 2 }
        XCTAssertEqual(serverVM.selectedSessionId, "sess-b", "Background session/new must not steal focus")
        XCTAssertEqual(serverVM.existingSessionViewModel(for: "sess-c")?.visibleConfigOptions().map(\.id), ["model", "thought_level"])
    }

    // SC-AC-041 / SC-AC-053: BridgeSyncCoordinator 4-step replay order, nonlocalSeq dedupe, instanceId restart & single-track connectionManagerFactory migration.
    func testP0AC6_FullBarrier_RepeatedDisconnectDedupe_ColdLaunch_UnreachedClientTurnId_AndFallbacks() async throws {
        // Part 1: Repeated reconnects + concurrent openSession + overlapping seq:2 + seq:3 -> exact "甲乙丙丁" with 0 session/load
        let suiteName = "P0AC6_1.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let storage = SessionStorage.inMemory()
        let c1 = ScriptedWebSocketConnection()
        let c2 = ScriptedWebSocketConnection()
        let c3 = ScriptedWebSocketConnection()
        let c4 = ScriptedWebSocketConnection()
        let c5 = ScriptedWebSocketConnection()
        let c6 = ScriptedWebSocketConnection()
        let c6b = ScriptedWebSocketConnection()
        let c7 = ScriptedWebSocketConnection()
        let c8 = ScriptedWebSocketConnection()
        let provider = ScriptedSocketProvider(connections: [c1, c2, c3, c4, c5, c6, c6b, c7, c8])
        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )
        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        appVM.addServer(name: "SyncACP", scheme: "ws", host: "127.0.0.1:18081", token: "tok", workingDirectory: "/tmp")
        let serverVM = try XCTUnwrap(appVM.selectedServerViewModel)

        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: c1)
        try await waitUntil { c1.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let s1Req = c1.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try c1.enqueueResponse(id: s1Req["id"]!, result: .object(["instanceId": .string("inst-1"), "materializedSessionIds": .array([]), "sessions": .array([])]))
        try await waitUntil { c1.sentJSONObjects.contains { ($0["method"] as? String) == "session/list" } }
        let l1Req = c1.sentJSONObjects.first { ($0["method"] as? String) == "session/list" }!
        try c1.enqueueResponse(id: l1Req["id"]!, result: .object(["sessions": .array([])]))

        appVM.sendNewSession(workingDirectory: "/tmp")
        try await waitUntil { c1.sentJSONObjects.contains { ($0["method"] as? String) == "session/new" } }
        let newReq = c1.sentJSONObjects.first { ($0["method"] as? String) == "session/new" }!
        try c1.enqueueResponse(id: newReq["id"]!, result: .object([
            "sessionId": .string("S1"),
            "cwd": .string("/tmp"),
            "configOptions": .array(makeHydrogenConfigOptions())
        ]))
        try await waitUntil { serverVM.selectedSessionId == "S1" }

        serverVM.sendPrompt(promptText: "q1", images: [])
        try await waitUntil { c1.sentJSONObjects.contains { ($0["method"] as? String) == "session/prompt" } }
        let promptObj = c1.sentJSONObjects.first { ($0["method"] as? String) == "session/prompt" }!
        let clientTurnId1 = try XCTUnwrap(((promptObj["params"] as? [String: Any])?["_meta"] as? [String: Any])?[NonlocalMethods.clientTurnIdMetaKey] as? String)
        XCTAssertFalse(clientTurnId1.isEmpty)

        try c1.enqueue(.notification(.init(method: "session/update", params: .object([
            "sessionId": .string("S1"),
            "_meta": .object([NonlocalMethods.seqMetaKey: .int(1)]),
            "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("甲")])])
        ]))))
        let vmS1 = try XCTUnwrap(serverVM.existingSessionViewModel(for: "S1"))
        try await waitUntil { vmS1.chatMessages.last?.content == "甲" }

        // First disconnect + reconnect with concurrent openSession("S1") during initialSyncTask
        c1.simulateDrop()
        try await waitUntil { appVM.connectionState != .connected }
        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: c2)
        try await waitUntil { c2.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }

        // Concurrent openSession("S1") & ensureSessionForActiveServer() BEFORE nonlocal/sync returns MUST wait on initialSyncTask barrier and NOT fire session/load
        appVM.openSession("S1")
        appVM.ensureSessionForActiveServer()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(c2.sentJSONObjects.contains { ($0["method"] as? String) == "session/load" })

        let sync2Req = c2.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try c2.enqueueResponse(id: sync2Req["id"]!, result: .object([
            "instanceId": .string("inst-1"),
            "materializedSessionIds": .array([.string("S1")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("S1"),
                    "configOptions": .array(makeHydrogenConfigOptions()),
                    "latestTurn": .object([
                        "turnId": .string("turn-1"),
                        "clientTurnId": .string(clientTurnId1),
                        "status": .string("active"),
                        "lastSeq": .int(2),
                        "truncated": .bool(false),
                        "events": .array([
                            .object(["seq": .int(1), "method": .string("session/update"), "params": .object(["sessionId": .string("S1"), "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("甲")])])])]),
                            .object(["seq": .int(2), "method": .string("session/update"), "params": .object(["sessionId": .string("S1"), "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("乙")])])])])
                        ]),
                        "pendingPermissions": .array([])
                    ])
                ])
            ])
        ]))
        // Overlapping duplicate seq:2 AND new live seq:3 ("丙") injected immediately adjacent
        try c2.enqueue(.notification(.init(method: "session/update", params: .object([
            "sessionId": .string("S1"),
            "_meta": .object([NonlocalMethods.seqMetaKey: .int(2)]),
            "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("乙")])])
        ]))))
        try c2.enqueue(.notification(.init(method: "session/update", params: .object([
            "sessionId": .string("S1"),
            "_meta": .object([NonlocalMethods.seqMetaKey: .int(3)]),
            "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("丙")])])
        ]))))
        try await waitUntil { vmS1.chatMessages.last?.content == "甲乙丙" }

        // Second disconnect + reconnect completes with "丁"
        c2.simulateDrop()
        try await waitUntil { appVM.connectionState != .connected }
        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: c3)
        try await waitUntil { c3.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let sync3Req = c3.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try c3.enqueueResponse(id: sync3Req["id"]!, result: .object([
            "instanceId": .string("inst-1"),
            "materializedSessionIds": .array([.string("S1")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("S1"),
                    "configOptions": .array(makeHydrogenConfigOptions()),
                    "latestTurn": .object([
                        "turnId": .string("turn-1"),
                        "clientTurnId": .string(clientTurnId1),
                        "status": .string("completed"),
                        "lastSeq": .int(4),
                        "truncated": .bool(false),
                        "stopReason": .string("end_turn"),
                        "events": .array([
                            .object(["seq": .int(4), "method": .string("session/update"), "params": .object(["sessionId": .string("S1"), "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("丁")])])])])
                        ]),
                        "pendingPermissions": .array([])
                    ])
                ])
            ])
        ]))
        try await waitUntil { !vmS1.isStreaming && vmS1.chatMessages.last?.content == "甲乙丙丁" }
        XCTAssertEqual((c1.sentJSONObjects + c2.sentJSONObjects + c3.sentJSONObjects).filter { ($0["method"] as? String) == "session/load" }.count, 0)

        // Idle reconnect on already-completed turn MUST NOT append duplicate bubbles
        let messageCountBeforeIdleReconnect = vmS1.chatMessages.count
        c3.simulateDrop()
        try await waitUntil { appVM.connectionState != .connected }
        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: c4)
        try await waitUntil { c4.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let sync4Req = c4.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try c4.enqueueResponse(id: sync4Req["id"]!, result: .object([
            "instanceId": .string("inst-1"),
            "materializedSessionIds": .array([.string("S1")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("S1"),
                    "latestTurn": .object([
                        "turnId": .string("turn-1"),
                        "clientTurnId": .string(clientTurnId1),
                        "status": .string("completed"),
                        "lastSeq": .int(4),
                        "truncated": .bool(false),
                        "stopReason": .string("end_turn"),
                        "events": .array([
                            .object(["seq": .int(4), "method": .string("session/update"), "params": .object(["sessionId": .string("S1"), "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("丁")])])])])
                        ]),
                        "pendingPermissions": .array([])
                    ])
                ])
            ])
        ]))
        try await waitUntil { c4.sentJSONObjects.contains { ($0["method"] as? String) == "session/list" } }
        XCTAssertEqual(vmS1.chatMessages.count, messageCountBeforeIdleReconnect)
        XCTAssertFalse(vmS1.isStreaming)

        // Unreached clientTurnId fails deterministically without adopting previous turn or auto-retrying
        serverVM.sendPrompt(promptText: "never reached bridge", images: [])
        try await waitUntil { c4.sentJSONObjects.contains { ($0["method"] as? String) == "session/prompt" } }
        c4.simulateDrop()
        try await waitUntil { appVM.connectionState != .connected }
        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: c5)
        try await waitUntil { c5.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let sync5Req = c5.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        // Bridge still only knows old clientTurnId1
        try c5.enqueueResponse(id: sync5Req["id"]!, result: .object([
            "instanceId": .string("inst-1"),
            "materializedSessionIds": .array([.string("S1")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("S1"),
                    "latestTurn": .object([
                        "turnId": .string("turn-1"),
                        "clientTurnId": .string(clientTurnId1),
                        "status": .string("completed"),
                        "lastSeq": .int(4),
                        "truncated": .bool(false),
                        "stopReason": .string("end_turn"),
                        "events": .array([]),
                        "pendingPermissions": .array([])
                    ])
                ])
            ])
        ]))
        try await waitUntil { !vmS1.isStreaming && (vmS1.chatMessages.last?.isError ?? false) }
        XCTAssertFalse(c5.sentJSONObjects.contains { ($0["method"] as? String) == "session/prompt" }, "Must not auto-resend unreached prompt")

        // Deterministic streaming termination via nonlocal/turn_completed(error) and -32601 fallback
        serverVM.sendPrompt(promptText: "active then crash", images: [])
        try await waitUntil { c5.sentJSONObjects.contains { ($0["method"] as? String) == "session/prompt" } && vmS1.isStreaming }
        try c5.enqueue(.notification(.init(method: NonlocalMethods.turnCompleted, params: .object([
            "instanceId": .string("inst-1"),
            "sessionId": .string("S1"),
            "turnId": .string("turn-crash"),
            "status": .string("error"),
            "error": .object(["code": .int(-32000), "message": .string("Child crashed")])
        ]))))
        try await waitUntil { !vmS1.isStreaming && (vmS1.chatMessages.last?.content.contains("Child crashed") ?? false) }

        serverVM.sendPrompt(promptText: "active then -32601", images: [])
        try await waitUntil { c5.sentJSONObjects.filter { ($0["method"] as? String) == "session/prompt" }.count == 2 && vmS1.isStreaming }
        c5.simulateDrop()
        try await waitUntil { appVM.connectionState != .connected }
        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: c6)
        try await waitUntil { c6.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let sync6Req = c6.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try c6.enqueueError(id: sync6Req["id"]!, code: -32601, message: "Method not found")
        try await waitUntil { !vmS1.isStreaming && appVM.isProtocolIncompatible(for: serverVM.id) && appVM.connectionState == .disconnected }

        // Manually reconnect to a compatible bridge (c6b) to unlock and test child restart (instanceId change)
        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: c6b)
        try await waitUntil { c6b.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let sync6bReq = c6b.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try c6b.enqueueResponse(id: sync6bReq["id"]!, result: .object([
            "instanceId": .string("inst-1"),
            "materializedSessionIds": .array([]),
            "sessions": .array([])
        ]))
        try await waitUntil { !appVM.hasInitialSyncPending(for: serverVM.id) }

        // Child restart (instanceId change) must deterministically terminate stale streaming state
        serverVM.sendPrompt(promptText: "active before restart", images: [])
        try await waitUntil { c6b.sentJSONObjects.contains { ($0["method"] as? String) == "session/load" } }
        let c6LoadReq = c6b.sentJSONObjects.first { ($0["method"] as? String) == "session/load" }!
        try c6b.enqueueResponse(id: c6LoadReq["id"]!, result: .object([:]))
        try await waitUntil { c6b.sentJSONObjects.contains { ($0["method"] as? String) == "session/prompt" } && vmS1.isStreaming }
        c6b.simulateDrop()
        try await waitUntil { appVM.connectionState != .connected }
        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: c7)
        try await waitUntil { c7.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let sync7Req = c7.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try c7.enqueueResponse(id: sync7Req["id"]!, result: .object([
            "instanceId": .string("inst-2"),
            "materializedSessionIds": .array([]),
            "sessions": .array([])
        ]))
        try await waitUntil {
            !vmS1.isStreaming &&
            vmS1.chatMessages.contains { $0.isError && $0.content.contains("Agent session restarted on bridge.") }
        }

        // Concurrent sendPrompt preflight MUST also wait on initialSyncTask barrier before deciding session/load
        c7.simulateDrop()
        try await waitUntil { appVM.connectionState != .connected }
        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: c8)
        try await waitUntil { c8.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        serverVM.sendPrompt(promptText: "barrier-prompt", images: [])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(c8.sentJSONObjects.contains { ($0["method"] as? String) == "session/load" })
        XCTAssertFalse(c8.sentJSONObjects.contains { ($0["method"] as? String) == "session/prompt" })
        let sync8Req = c8.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try c8.enqueueResponse(id: sync8Req["id"]!, result: .object([
            "instanceId": .string("inst-2"),
            "materializedSessionIds": .array([.string("S1")]),
            "sessions": .array([])
        ]))
        try await waitUntil { c8.sentJSONObjects.contains { ($0["method"] as? String) == "session/prompt" } }
        XCTAssertFalse(c8.sentJSONObjects.contains { ($0["method"] as? String) == "session/load" })

        // Explicit disconnect and deleteServer converge streaming state deterministically
        XCTAssertTrue(vmS1.isStreaming)
        appVM.disconnect()
        XCTAssertFalse(vmS1.isStreaming, "Explicit disconnect must converge active streaming state")
        try await waitUntil { appVM.connectionState == .disconnected }
        appVM.deleteServer(serverVM.id)
        XCTAssertNil(appVM.selectedServerId)

        // Part 2: Cold launch (isInitialAppLaunch == true) with active S1 & unmaterialized historical S2 (even if in bridge materializedSessionIds)
        let coldSuite = "P0AC6_Cold.\(UUID().uuidString)"
        let coldDefaults = UserDefaults(suiteName: coldSuite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: coldSuite) }
        let coldStorage = SessionStorage.inMemory()
        let coldServer = ACPServerConfiguration(
            id: UUID(), name: "ColdACP", scheme: "ws", host: "127.0.0.1:18082",
            token: "tok", workingDirectory: "/tmp"
        )
        coldStorage.saveServer(coldServer)
        coldStorage.saveSession(StoredSessionInfo(sessionId: "S1", title: "Active S1", cwd: "/tmp", updatedAt: Date()), forServerId: coldServer.id)
        coldStorage.saveSession(StoredSessionInfo(sessionId: "S2", title: "Old S2", cwd: "/tmp", updatedAt: Date().addingTimeInterval(-100)), forServerId: coldServer.id)
        coldStorage.saveMessages([StoredMessageInfo(messageId: UUID(), role: "user", content: "cold q", createdAt: Date(), segmentsData: nil)], forSessionId: "S1", serverId: coldServer.id)

        let coldConn = ScriptedWebSocketConnection()
        let coldProvider = ScriptedSocketProvider(connections: [coldConn])
        let coldManager = ACPClientManager(
            defaults: coldDefaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: coldProvider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )
        let coldApp = AppViewModel(
            storage: coldStorage,
            defaults: coldDefaults,
            connectionManagerFactory: { _ in coldManager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: true
        )
        XCTAssertTrue(coldApp.isInitialAppLaunch)
        try await respondInitialize(on: coldConn, loadSession: true)
        try await waitUntil { coldConn.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }

        // fs/read_text_file before any foreground sessionViewModel exists must still respond via service (-32001)
        try coldConn.enqueue(.request(.init(id: .number(77), method: "fs/read_text_file", params: .object(["path": .string("/tmp/no-session")]))))
        try await waitUntil {
            coldConn.sentJSONObjects.contains { ($0["id"] as? Int) == 77 && (($0["error"] as? [String: Any])?["code"] as? Int) == -32001 }
        }

        let coldSyncReq = coldConn.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try coldConn.enqueueResponse(id: coldSyncReq["id"]!, result: .object([
            "instanceId": .string("inst-cold"),
            "materializedSessionIds": .array([.string("S1"), .string("S2")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("S1"),
                    "configOptions": .array(makeHydrogenConfigOptions()),
                    "latestTurn": .object([
                        "turnId": .string("turn-cold"),
                        "status": .string("completed"),
                        "lastSeq": .int(1),
                        "truncated": .bool(false),
                        "stopReason": .string("end_turn"),
                        "events": .array([
                            .object(["seq": .int(1), "method": .string("session/update"), "params": .object(["sessionId": .string("S1"), "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("RecoveredOnColdLaunch")])])])])
                        ]),
                        "pendingPermissions": .array([])
                    ])
                ]),
                .object([
                    "sessionId": .string("S2"),
                    "configOptions": .array(makeHydrogenConfigOptions())
                ])
            ])
        ]))
        try await waitUntil {
            coldApp.selectedServerViewModel?
                .existingSessionViewModel(for: "S1")?
                .chatMessages
                .contains { $0.content == "RecoveredOnColdLaunch" } ?? false
        }
        coldApp.openSession("S1")

        let coldS1VM = try XCTUnwrap(coldApp.selectedServerViewModel?.existingSessionViewModel(for: "S1"))
        XCTAssertEqual(coldS1VM.visibleConfigOptions().map(\.id), ["model", "thought_level"])
        XCTAssertEqual(coldS1VM.chatMessages.map(\.content), ["cold q", "RecoveredOnColdLaunch"], "Cold launch sync must preserve existing Core Data history before RecoveredOnColdLaunch")
        XCTAssertEqual(coldStorage.fetchMessages(forSessionId: "S1", serverId: coldServer.id).map(\.content), ["cold q", "RecoveredOnColdLaunch"])
        XCTAssertEqual(
            coldConn.sentJSONObjects.filter { ($0["method"] as? String) == "session/load" }.count,
            0,
            "Active materialized S1 must issue 0 session/load on cold launch"
        )

        // Concurrent empty session/list pruneSessions MUST protect synced/in-memory S1
        try await waitUntil { coldConn.sentJSONObjects.contains { ($0["method"] as? String) == "session/list" } }
        let coldListReq = try XCTUnwrap(coldConn.sentJSONObjects.first { ($0["method"] as? String) == "session/list" })
        try coldConn.enqueueResponse(id: coldListReq["id"]!, result: .object(["sessions": .array([])]))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(
            coldStorage.fetchSessions(forServerId: coldServer.id).contains { $0.sessionId == "S1" },
            "pruneSessions must preserve in-memory/synced S1"
        )

        // Opening historical non-active S2 (even if listed in bridge materializedSessionIds) must still issue 1 session/load
        coldApp.openSession("S2")
        try await waitUntil { coldConn.sentJSONObjects.contains { ($0["method"] as? String) == "session/load" } }
        let loadRequests = coldConn.sentJSONObjects.filter { ($0["method"] as? String) == "session/load" }
        XCTAssertEqual(loadRequests.count, 1)
        XCTAssertEqual((loadRequests.first?["params"] as? [String: Any])?["sessionId"] as? String, "S2")
    }

    func testSyncAndStorageIgnoreCapabilityProbeAndPhantomIdleSessions() async throws {
        let suite = "P0ProbeGuard.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let server = ACPServerConfiguration(
            id: UUID(), name: "ProbeGuard", scheme: "ws", host: "127.0.0.1:18083",
            token: "tok", workingDirectory: "/tmp"
        )
        storage.saveServer(server)
        // Seed a stale capability-probe row (as left behind by an earlier unpatched run) plus a real session.
        storage.saveSession(StoredSessionInfo(sessionId: "capability-probe", title: "你好", cwd: "/tmp", updatedAt: Date()), forServerId: server.id)
        storage.saveSession(StoredSessionInfo(sessionId: "S-real", title: "Real Session", cwd: "/tmp", updatedAt: Date().addingTimeInterval(-60)), forServerId: server.id)

        let conn = ScriptedWebSocketConnection()
        let provider = ScriptedSocketProvider(connections: [conn])
        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )
        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: true
        )

        let serverVM = try XCTUnwrap(appVM.selectedServerViewModel)
        XCTAssertFalse(serverVM.sessionSummaries.contains { $0.id == "capability-probe" }, "loadCachedSessions must filter & purge capability-probe")
        XCTAssertFalse(storage.fetchSessions(forServerId: server.id).contains { $0.sessionId == "capability-probe" })
        XCTAssertFalse(serverVM.rememberSession("capability-probe", cwd: "/tmp", updateSessionCache: false))

        try await respondInitialize(on: conn, loadSession: true)
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let syncReq = try XCTUnwrap(conn.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync })

        try conn.enqueueResponse(id: syncReq["id"]!, result: .object([
            "instanceId": .string("inst-probe"),
            "materializedSessionIds": .array([.string("capability-probe"), .string("S-idle-phantom")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("capability-probe"),
                    "configOptions": .array(makeHydrogenConfigOptions()),
                    "latestTurn": .object([
                        "turnId": .string("turn-probe"),
                        "status": .string("completed"),
                        "lastSeq": .int(1),
                        "truncated": .bool(false),
                        "events": .array([]),
                        "pendingPermissions": .array([])
                    ])
                ]),
                .object([
                    "sessionId": .string("S-idle-phantom"),
                    "configOptions": .array(makeHydrogenConfigOptions())
                ])
            ])
        ]))

        try await waitUntil { appVM.connectionState == .connected }
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertFalse(serverVM.sessionSummaries.contains { $0.id == "capability-probe" })
        XCTAssertFalse(serverVM.sessionSummaries.contains { $0.id == "S-idle-phantom" }, "Un-hydrated idle sync sessions must not be inserted as phantom summaries")
        XCTAssertFalse(storage.fetchSessions(forServerId: server.id).contains { $0.sessionId == "capability-probe" })
        XCTAssertFalse(storage.fetchSessions(forServerId: server.id).contains { $0.sessionId == "S-idle-phantom" })
        XCTAssertFalse(manager.isSessionMaterialized("capability-probe"))
        XCTAssertFalse(manager.isSessionMaterialized("S-idle-phantom"))
    }

    func testBackgroundContinuationStaleReloadAndListUpdatedAtDetection() async throws {
        let suite = "P0StaleReload.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let server = ACPServerConfiguration(
            id: UUID(), name: "StaleACP", scheme: "ws", host: "127.0.0.1:18084",
            token: "tok", workingDirectory: "/tmp"
        )
        storage.saveServer(server)

        let c1 = ScriptedWebSocketConnection()
        let c2 = ScriptedWebSocketConnection()
        let provider = ScriptedSocketProvider(connections: [c1, c2])
        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )
        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: true
        )
        let serverVM = try XCTUnwrap(appVM.selectedServerViewModel)

        try await respondInitialize(on: c1, loadSession: true)
        try await waitUntil { c1.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let s1Req = try XCTUnwrap(c1.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync })
        try c1.enqueueResponse(id: s1Req["id"]!, result: .object([
            "instanceId": .string("inst-bg-1"),
            "materializedSessionIds": .array([.string("S-bg"), .string("S-normal")]),
            "staleSessionIds": .array([]),
            "sessions": .array([
                .object([
                    "sessionId": .string("S-bg"),
                    "lastActivityAt": .string("2026-11-16T13:09:41.785Z"),
                    "latestTurn": .object([
                        "turnId": .string("turn-bg"),
                        "status": .string("completed"),
                        "lastSeq": .int(1),
                        "truncated": .bool(false),
                        "events": .array([
                            .object(["seq": .int(1), "method": .string("session/update"), "params": .object(["sessionId": .string("S-bg"), "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("稍候片刻")])])])])
                        ]),
                        "pendingPermissions": .array([])
                    ])
                ]),
                .object([
                    "sessionId": .string("S-normal"),
                    "lastActivityAt": .string("2026-11-16T13:11:20.786Z"),
                    "latestTurn": .object([
                        "turnId": .string("turn-norm"),
                        "status": .string("completed"),
                        "lastSeq": .int(1),
                        "truncated": .bool(false),
                        "events": .array([
                            .object(["seq": .int(1), "method": .string("session/update"), "params": .object(["sessionId": .string("S-normal"), "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("Normal OK")])])])])
                        ]),
                        "pendingPermissions": .array([])
                    ])
                ])
            ])
        ]))
        try await waitUntil { manager.isSessionMaterialized("S-bg") && manager.isSessionMaterialized("S-normal") }

        // Put user actively inside S-bg showing "稍候片刻"
        appVM.openSession("S-bg")
        let vmBg = try XCTUnwrap(serverVM.existingSessionViewModel(for: "S-bg"))
        XCTAssertEqual(vmBg.chatMessages.last?.content, "稍候片刻")

        // 1. session/list where S-normal updatedAt is same second (13:11:20Z <= baseline 13:11:20.786Z)
        //    and S-bg updatedAt advanced +72s (13:10:53Z > 13:09:41.785Z + 2s): only active S-bg must reload
        try await waitUntil { c1.sentJSONObjects.contains { ($0["method"] as? String) == "session/list" } }
        let listReq1 = try XCTUnwrap(c1.sentJSONObjects.first { ($0["method"] as? String) == "session/list" })
        try c1.enqueueResponse(id: listReq1["id"]!, result: .object([
            "sessions": .array([
                .object(["sessionId": .string("S-bg"), "title": .string("China"), "cwd": .string("/tmp"), "updatedAt": .string("2026-11-16T13:10:53Z")]),
                .object(["sessionId": .string("S-normal"), "title": .string("World"), "cwd": .string("/tmp"), "updatedAt": .string("2026-11-16T13:11:20Z")])
            ])
        ]))

        try await waitUntil { c1.sentJSONObjects.contains { ($0["method"] as? String) == "session/load" } }
        let load1Req = try XCTUnwrap(c1.sentJSONObjects.first { ($0["method"] as? String) == "session/load" })
        XCTAssertEqual((load1Req["params"] as? [String: Any])?["sessionId"] as? String, "S-bg")
        try c1.enqueue(.notification(.init(method: "session/update", params: .object([
            "sessionId": .string("S-bg"),
            "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("ALL_34_CITIES_REPORT")])])
        ]))))
        try c1.enqueueResponse(id: load1Req["id"]!, result: .object(["sessionId": .string("S-bg")]))
        try await waitUntil { vmBg.chatMessages.last?.content == "ALL_34_CITIES_REPORT" }
        XCTAssertTrue(manager.isSessionMaterialized("S-normal"))

        // 2. Live nonlocal/session_stale for background session clears materialized without disturbing active session,
        //    then reloads when user switches to it; and if active session is stale, reloads immediately.
        appVM.openSession("S-normal")
        XCTAssertEqual(serverVM.selectedSessionId, "S-normal")
        try c1.enqueue(.notification(.init(method: NonlocalMethods.sessionStale, params: .object([
            "instanceId": .string("inst-bg-1"),
            "sessionId": .string("S-bg"),
            "updatedAt": .string("2026-11-16T13:12:00Z"),
            "reason": .string("background_updated")
        ]))))
        try await waitUntil { !manager.isSessionMaterialized("S-bg") }
        XCTAssertEqual(c1.sentJSONObjects.filter { ($0["method"] as? String) == "session/load" }.count, 1, "Background stale notice must not reload unrelated active session")

        // Sending nonlocal/session_stale for currently active S-bg immediately issues session/load
        appVM.openSession("S-bg")
        try await waitUntil { c1.sentJSONObjects.filter { ($0["method"] as? String) == "session/load" }.count == 2 }
        let load2Req = c1.sentJSONObjects.filter { ($0["method"] as? String) == "session/load" }[1]
        try c1.enqueueResponse(id: load2Req["id"]!, result: .object(["sessionId": .string("S-bg")]))
        try await waitUntil { manager.isSessionMaterialized("S-bg") }

        // 3. Disconnect & reconnect while viewing S-bg when nonlocal/sync returns staleSessionIds: ["S-bg"]
        c1.simulateDrop()
        try await waitUntil { appVM.connectionState != .connected }
        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: c2, loadSession: true)
        try await waitUntil { c2.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let s2Req = try XCTUnwrap(c2.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync })
        try c2.enqueueResponse(id: s2Req["id"]!, result: .object([
            "instanceId": .string("inst-bg-1"),
            "materializedSessionIds": .array([.string("S-normal")]),
            "staleSessionIds": .array([.string("S-bg")]),
            "sessions": .array([
                .object(["sessionId": .string("S-bg"), "lastActivityAt": .string("2026-11-16T13:13:00Z")]),
                .object(["sessionId": .string("S-normal"), "lastActivityAt": .string("2026-11-16T13:11:20.786Z")])
            ])
        ]))
        try await waitUntil { c2.sentJSONObjects.contains { ($0["method"] as? String) == "session/load" } }
        let reconnectLoad = try XCTUnwrap(c2.sentJSONObjects.first { ($0["method"] as? String) == "session/load" })
        XCTAssertEqual((reconnectLoad["params"] as? [String: Any])?["sessionId"] as? String, "S-bg")
        try c2.enqueueResponse(id: reconnectLoad["id"]!, result: .object(["sessionId": .string("S-bg")]))
        try await waitUntil { manager.isSessionMaterialized("S-bg") }
        XCTAssertTrue(manager.isSessionMaterialized("S-normal"))
    }

    func testSessionLoad_LargeHistoryBurstCompletesWithoutBlockingAndBoundsWireLogs() async throws {
        let suite = "HugeReplay.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let server = ACPServerConfiguration(
            id: UUID(), name: "HugeACP", scheme: "ws", host: "127.0.0.1:18085",
            token: "tok", workingDirectory: "/tmp"
        )
        storage.saveServer(server)

        let conn = ScriptedWebSocketConnection()
        let provider = ScriptedSocketProvider(connections: [conn])
        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )
        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: true
        )
        let serverVM = try XCTUnwrap(appVM.selectedServerViewModel)

        try await respondInitialize(on: conn, loadSession: true)
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let syncReq = try XCTUnwrap(conn.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync })
        try conn.enqueueResponse(id: syncReq["id"]!, result: .object([
            "instanceId": .string("inst-huge"),
            "materializedSessionIds": .array([]),
            "sessions": .array([])
        ]))

        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == "session/list" } }
        let listReq = try XCTUnwrap(conn.sentJSONObjects.first { ($0["method"] as? String) == "session/list" })
        try conn.enqueueResponse(id: listReq["id"]!, result: .object([
            "sessions": .array([
                .object(["sessionId": .string("S-huge"), "title": .string("Project Review and Analysis"), "cwd": .string("/tmp/proj")])
            ])
        ]))
        try await waitUntil { serverVM.sessionSummaries.contains { $0.id == "S-huge" } }

        appVM.openSession("S-huge")
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == "session/load" } }
        let loadReq = try XCTUnwrap(conn.sentJSONObjects.first { ($0["method"] as? String) == "session/load" })

        let start = CFAbsoluteTimeGetCurrent()
        for turn in 0..<20 {
            try conn.enqueue(.notification(.init(method: "session/update", params: .object([
                "sessionId": .string("S-huge"),
                "update": .object([
                    "sessionUpdate": .string("user_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("Turn \(turn) question")])
                ])
            ]))))
            for _ in 0..<10 {
                try conn.enqueue(.notification(.init(method: "session/update", params: .object([
                    "sessionId": .string("S-huge"),
                    "update": .object([
                        "sessionUpdate": .string("agent_thought_chunk"),
                        "content": .object(["type": .string("text"), "text": .string("thought chunk ")])
                    ])
                ]))))
            }
            for t in 0..<35 {
                let status = (turn == 19 && t == 34) ? "in_progress" : "completed"
                try conn.enqueue(.notification(.init(method: "session/update", params: .object([
                    "sessionId": .string("S-huge"),
                    "update": .object([
                        "sessionUpdate": .string("tool_call"),
                        "toolCallId": .string("huge-tc-\(turn)-\(t)"),
                        "title": .string("Inspect file \(t)"),
                        "kind": .string("read"),
                        "status": .string(status)
                    ])
                ]))))
            }
            for c in 0..<5 {
                try conn.enqueue(.notification(.init(method: "session/update", params: .object([
                    "sessionId": .string("S-huge"),
                    "update": .object([
                        "sessionUpdate": .string("agent_message_chunk"),
                        "content": .object(["type": .string("text"), "text": .string("Response \(turn)-\(c) ")])
                    ])
                ]))))
            }
        }
        try conn.enqueueResponse(id: loadReq["id"]!, result: .object(["sessionId": .string("S-huge")]))

        let hugeVM = try XCTUnwrap(serverVM.existingSessionViewModel(for: "S-huge"))
        try await waitUntil(timeout: 5.0) {
            hugeVM.chatMessages.count == 40 && !hugeVM.isStreaming
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 5.0, "Full 1000+ notification session/load pipeline took \(elapsed)s")
        XCTAssertFalse(serverVM.isStreaming)
        XCTAssertNil(hugeVM.liveActivityStatus)
        XCTAssertTrue(
            hugeVM.chatMessages.flatMap(\.segments).allSatisfy { $0.kind == .message },
            "ACP replay must retain only conversational message segments"
        )
        XCTAssertFalse(hugeVM.chatMessages.contains { $0.content.contains("Tool call:") })

        let persisted = storage.fetchMessages(forSessionId: "S-huge", serverId: server.id)
        XCTAssertEqual(persisted.count, 40)
        XCTAssertFalse(persisted.contains { $0.content.contains("Tool call:") })
        XCTAssertLessThanOrEqual(appVM.updates.count, 300)
        XCTAssertFalse(appVM.updates.contains { $0.message.hasPrefix("← session/update: {") })
    }

    func testMultiTurnAfterReconnectSyncDoesNotDropSubsequentShorterTurns() async throws {
        let suite = "P0MultiTurnSeq.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let server = ACPServerConfiguration(
            id: UUID(), name: "MultiTurnACP", scheme: "ws", host: "127.0.0.1:18086",
            token: "tok", workingDirectory: "/tmp"
        )
        storage.saveServer(server)

        let c1 = ScriptedWebSocketConnection()
        let c2 = ScriptedWebSocketConnection()
        let c3 = ScriptedWebSocketConnection()
        let provider = ScriptedSocketProvider(connections: [c1, c2, c3])
        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )
        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        appVM.addServer(name: "MultiTurnACP", scheme: "ws", host: "127.0.0.1:18086", token: "tok", workingDirectory: "/tmp")
        let serverVM = try XCTUnwrap(appVM.selectedServerViewModel)

        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: c1)
        try await waitUntil { c1.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let s1Req = c1.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try c1.enqueueResponse(id: s1Req["id"]!, result: .object(["instanceId": .string("inst-mt"), "materializedSessionIds": .array([]), "sessions": .array([])]))

        appVM.sendNewSession(workingDirectory: "/tmp")
        try await waitUntil { c1.sentJSONObjects.contains { ($0["method"] as? String) == "session/new" } }
        let newReq = c1.sentJSONObjects.first { ($0["method"] as? String) == "session/new" }!
        try c1.enqueueResponse(id: newReq["id"]!, result: .object(["sessionId": .string("S-mt"), "cwd": .string("/tmp")]))
        try await waitUntil { serverVM.selectedSessionId == "S-mt" }

        // Turn 1 disconnects before completion, then recovers via c2 nonlocal/sync + high seq live chunks
        serverVM.sendPrompt(promptText: "turn1 q", images: [])
        try await waitUntil { c1.sentJSONObjects.contains { ($0["method"] as? String) == "session/prompt" } }
        let p1 = c1.sentJSONObjects.first { ($0["method"] as? String) == "session/prompt" }!
        let ctid1 = try XCTUnwrap(((p1["params"] as? [String: Any])?["_meta"] as? [String: Any])?[NonlocalMethods.clientTurnIdMetaKey] as? String)

        c1.simulateDrop()
        try await waitUntil { appVM.connectionState != .connected }

        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: c2)
        try await waitUntil { c2.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let s2Req = c2.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try c2.enqueueResponse(id: s2Req["id"]!, result: .object([
            "instanceId": .string("inst-mt"),
            "materializedSessionIds": .array([.string("S-mt")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("S-mt"),
                    "latestTurn": .object([
                        "turnId": .string("turn-1"),
                        "clientTurnId": .string(ctid1),
                        "status": .string("active"),
                        "lastSeq": .int(1),
                        "truncated": .bool(false),
                        "events": .array([
                            .object(["seq": .int(1), "method": .string("session/update"), "params": .object(["sessionId": .string("S-mt"), "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("T1A")])])])])
                        ]),
                        "pendingPermissions": .array([])
                    ])
                ])
            ])
        ]))
        // Climb Turn 1 high-water mark to seq=5 on c2 before completing via nonlocal/turn_completed
        for seqIdx in 2...5 {
            try c2.enqueue(.notification(.init(method: "session/update", params: .object([
                "sessionId": .string("S-mt"),
                "_meta": .object([
                    NonlocalMethods.seqMetaKey: .int(seqIdx),
                    NonlocalMethods.turnIdMetaKey: .string("turn-1")
                ]),
                "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("-\(seqIdx)")])])
            ]))))
        }
        try c2.enqueue(.notification(.init(method: NonlocalMethods.turnCompleted, params: .object([
            "instanceId": .string("inst-mt"),
            "sessionId": .string("S-mt"),
            "turnId": .string("turn-1"),
            "clientTurnId": .string(ctid1),
            "status": .string("completed"),
            "stopReason": .string("end_turn")
        ]))))

        let vm = try XCTUnwrap(serverVM.existingSessionViewModel(for: "S-mt"))
        try await waitUntil { !vm.isStreaming && vm.chatMessages.last?.content == "T1A-2-3-4-5" }

        // Turn 2 on SAME connection with fewer events (seq 1..2 <= Turn 1's lastSeq=5), EVEN WITHOUT nonlocalTurnId (legacy bridge fallback)
        serverVM.sendPrompt(promptText: "turn2 q", images: [])
        try await waitUntil { c2.sentJSONObjects.contains { ($0["method"] as? String) == "session/prompt" } }
        let p2 = c2.sentJSONObjects.first { ($0["method"] as? String) == "session/prompt" }!
        try c2.enqueue(.notification(.init(method: "session/update", params: .object([
            "sessionId": .string("S-mt"),
            "_meta": .object([NonlocalMethods.seqMetaKey: .int(1)]),
            "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("T2_PART1 ")])])
        ]))))
        try c2.enqueue(.notification(.init(method: "session/update", params: .object([
            "sessionId": .string("S-mt"),
            "_meta": .object([NonlocalMethods.seqMetaKey: .int(2)]),
            "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("T2_PART2")])])
        ]))))
        try c2.enqueueResponse(id: p2["id"]!, result: .object(["stopReason": .string("end_turn")]))

        try await waitUntil { !vm.isStreaming && vm.chatMessages.last?.content == "T2_PART1 T2_PART2" }

        // Reconnect AFTER a completed high-seq turn (seq=10), then Turn 3 with seq=1 + nonlocalTurnId must NOT be dropped
        c2.simulateDrop()
        try await waitUntil { appVM.connectionState != .connected }
        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: c3)
        try await waitUntil { c3.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let s3Req = c3.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try c3.enqueueResponse(id: s3Req["id"]!, result: .object([
            "instanceId": .string("inst-mt"),
            "materializedSessionIds": .array([.string("S-mt")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("S-mt"),
                    "latestTurn": .object([
                        "turnId": .string("turn-2-synced"),
                        "status": .string("completed"),
                        "lastSeq": .int(10),
                        "truncated": .bool(false),
                        "stopReason": .string("end_turn"),
                        "events": .array([
                            .object(["seq": .int(10), "method": .string("session/update"), "params": .object(["sessionId": .string("S-mt"), "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("T2_PART2")])])])])
                        ]),
                        "pendingPermissions": .array([])
                    ])
                ])
            ])
        ]))
        try await waitUntil { c3.sentJSONObjects.contains { ($0["method"] as? String) == "session/list" } && manager.isSessionMaterialized("S-mt") }
        try await Task.sleep(nanoseconds: 50_000_000)

        serverVM.sendPrompt(promptText: "turn3 q", images: [])
        try await waitUntil { c3.sentJSONObjects.contains { ($0["method"] as? String) == "session/prompt" } }
        let p3 = c3.sentJSONObjects.first { ($0["method"] as? String) == "session/prompt" }!
        try c3.enqueue(.notification(.init(method: "session/update", params: .object([
            "sessionId": .string("S-mt"),
            "_meta": .object([
                NonlocalMethods.seqMetaKey: .int(1),
                NonlocalMethods.turnIdMetaKey: .string("turn-3")
            ]),
            "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("T3_OK")])])
        ]))))
        try c3.enqueueResponse(id: p3["id"]!, result: .object(["stopReason": .string("end_turn")]))

        try await waitUntil { !vm.isStreaming && vm.chatMessages.last?.content == "T3_OK" }
    }

    func testCCAC8_SessionStorageTitleClearing_DualCacheSync_RenameRPC_32601_AndPreviewIsolation() async throws {
        // Part 1: SessionStorage explicit clear vs bumpSessionTimestamp preserve
        let unitStorage = SessionStorage.inMemory()
        let unitServerId = UUID()
        unitStorage.saveServer(ACPServerConfiguration(
            id: unitServerId, name: "UnitACP", scheme: "ws", host: "127.0.0.1:18090",
            token: "", workingDirectory: "/tmp"
        ))
        let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)
        unitStorage.saveSession(StoredSessionInfo(sessionId: "s-stor", title: "Old", cwd: "/tmp", updatedAt: fixedDate), forServerId: unitServerId)
        unitStorage.saveSession(StoredSessionInfo(sessionId: "s-stor", title: nil, cwd: "/tmp", updatedAt: nil), forServerId: unitServerId)
        XCTAssertEqual(unitStorage.fetchSessions(forServerId: unitServerId).first?.title, "Old")

        unitStorage.saveSession(StoredSessionInfo(sessionId: "s-stor", title: nil, cwd: "/tmp", updatedAt: nil), forServerId: unitServerId, clearTitleWhenNil: true)
        XCTAssertNil(unitStorage.fetchSessions(forServerId: unitServerId).first?.title)

        unitStorage.updateSession(sessionId: "s-stor", forServerId: unitServerId, title: "Custom", touchUpdatedAt: false)
        unitStorage.updateSession(sessionId: "s-stor", forServerId: unitServerId, title: nil, touchUpdatedAt: false)
        XCTAssertEqual(unitStorage.fetchSessions(forServerId: unitServerId).first?.title, "Custom")
        unitStorage.updateSession(sessionId: "s-stor", forServerId: unitServerId, title: nil, touchUpdatedAt: false, clearTitle: true)
        XCTAssertNil(unitStorage.fetchSessions(forServerId: unitServerId).first?.title)

        // Part 2: End-to-end ACP AppViewModel + ServerViewModel + SessionStorage + ScriptedWebSocket
        let suite = "CCAC8.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let server = ACPServerConfiguration(
            id: UUID(), name: "RenameACP", scheme: "ws", host: "127.0.0.1:18091",
            token: "tok", workingDirectory: "/tmp"
        )
        storage.saveServer(server)
        storage.saveSession(StoredSessionInfo(sessionId: "s-1", title: "Legacy Stale Title", cwd: "/tmp", updatedAt: fixedDate), forServerId: server.id)

        let conn = ScriptedWebSocketConnection()
        let provider = ScriptedSocketProvider(connections: [conn])
        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )
        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        appVM.selectServer(server.id)
        let serverVM = try XCTUnwrap(appVM.selectedServerViewModel)

        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: conn)
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let syncReq = conn.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try conn.enqueueResponse(id: syncReq["id"]!, result: .object([
            "instanceId": .string("inst-ccac8"),
            "materializedSessionIds": .array([.string("s-1")]),
            "sessions": .array([.object(["sessionId": .string("s-1")])])
        ]))

        // Wait for DEC-8 list response returning explicit title: null -> clears legacy Core Data title
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == "session/list" } }
        let listReq = conn.sentJSONObjects.first { ($0["method"] as? String) == "session/list" }!
        try conn.enqueueResponse(id: listReq["id"]!, result: .object([
            "sessions": .array([
                .object([
                    "sessionId": .string("s-1"),
                    "cwd": .string("/tmp"),
                    "title": .null,
                    "updatedAt": .string("2025-01-01T00:00:00Z")
                ])
            ])
        ]))
        try await waitUntil { serverVM.sessionSummaries.first(where: { $0.id == "s-1" })?.title == nil }
        let baselineUpdatedAt = try XCTUnwrap(serverVM.sessionSummaries.first(where: { $0.id == "s-1" })?.updatedAt)
        XCTAssertNil(serverVM.sessionSummaries.first(where: { $0.id == "s-1" })?.title)
        XCTAssertNil(storage.fetchSessions(forServerId: server.id).first(where: { $0.sessionId == "s-1" })?.title)

        // Ensure placeholder session is NOT eligible for remote rename
        serverVM.sendNewSession(workingDirectory: "/tmp")
        let pendingId = serverVM.sessionId
        XCTAssertFalse(appVM.canRenameSession(pendingId))
        serverVM.deleteSession(pendingId)

        serverVM.openSession("s-1")
        XCTAssertTrue(appVM.canRenameSession("s-1"))

        // session_info_update updates serverSummaries + Core Data without changing updatedAt
        let s1VM = serverVM.sessionViewModel(for: "s-1")
        s1VM.addUserMessage(content: "Hello", images: [])
        s1VM.handleSessionUpdateEvents([
            "sessionId": .string("s-1"),
            "update": .object([
                "sessionUpdate": .string("session_info_update"),
                "title": .string("中文短标题")
            ])
        ], activeSessionId: "s-1", serverId: server.id)

        XCTAssertEqual(serverVM.sessionSummaries.first(where: { $0.id == "s-1" })?.title, "中文短标题")
        XCTAssertEqual(appVM.serverViewModels[server.id]?.sessionSummaries.first(where: { $0.id == "s-1" })?.title, "中文短标题")
        XCTAssertEqual(storage.fetchSessions(forServerId: server.id).first(where: { $0.sessionId == "s-1" })?.title, "中文短标题")
        XCTAssertEqual(serverVM.sessionSummaries.first(where: { $0.id == "s-1" })?.updatedAt, baselineUpdatedAt)

        // Manual rename -> set custom title
        let renameTask = Task { @MainActor in
            try await appVM.renameSession(sessionId: "s-1", title: "专属会话名")
        }
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.renameSession } }
        let renameReq1 = conn.sentJSONObjects.last { ($0["method"] as? String) == NonlocalMethods.renameSession }!
        try conn.enqueueResponse(id: renameReq1["id"]!, result: .object([
            "sessionId": .string("s-1"),
            "title": .string("专属会话名")
        ]))
        let renamedTitle = try await renameTask.value
        XCTAssertEqual(renamedTitle, "专属会话名")
        XCTAssertEqual(serverVM.sessionSummaries.first(where: { $0.id == "s-1" })?.title, "专属会话名")
        XCTAssertEqual(appVM.serverViewModels[server.id]?.sessionSummaries.first(where: { $0.id == "s-1" })?.title, "专属会话名")
        XCTAssertEqual(storage.fetchSessions(forServerId: server.id).first(where: { $0.sessionId == "s-1" })?.title, "专属会话名")
        XCTAssertEqual(serverVM.sessionSummaries.first(where: { $0.id == "s-1" })?.updatedAt, baselineUpdatedAt)

        appVM.persistChatToStorage(serverId: server.id, sessionId: "s-1")
        XCTAssertEqual(storage.fetchSessions(forServerId: server.id).first(where: { $0.sessionId == "s-1" })?.title, "专属会话名")

        // Empty rename -> clears title back to nil across all three stores, and persistChatToStorage keeps nil
        let clearTask = Task { @MainActor in
            try await appVM.renameSession(sessionId: "s-1", title: "   ")
        }
        try await waitUntil {
            conn.sentJSONObjects.filter { ($0["method"] as? String) == NonlocalMethods.renameSession }.count == 2
        }
        let renameReq2 = conn.sentJSONObjects.last { ($0["method"] as? String) == NonlocalMethods.renameSession }!
        try conn.enqueueResponse(id: renameReq2["id"]!, result: .object([
            "sessionId": .string("s-1"),
            "title": .null
        ]))
        let clearedTitle = try await clearTask.value
        XCTAssertNil(clearedTitle)
        XCTAssertNil(serverVM.sessionSummaries.first(where: { $0.id == "s-1" })?.title)
        XCTAssertNil(appVM.serverViewModels[server.id]?.sessionSummaries.first(where: { $0.id == "s-1" })?.title)
        XCTAssertNil(storage.fetchSessions(forServerId: server.id).first(where: { $0.sessionId == "s-1" })?.title)
        appVM.persistChatToStorage(serverId: server.id, sessionId: "s-1")
        XCTAssertNil(storage.fetchSessions(forServerId: server.id).first(where: { $0.sessionId == "s-1" })?.title)

        // Standard third-party ACP -32601 rejection leaves existing title unchanged (DEC-11)
        s1VM.handleSessionUpdateEvents([
            "sessionId": .string("s-1"),
            "update": .object(["sessionUpdate": .string("session_info_update"), "title": .string("保持原标题")])
        ], activeSessionId: "s-1", serverId: server.id)

        let failTask = Task { @MainActor () -> Error? in
            do {
                _ = try await appVM.renameSession(sessionId: "s-1", title: "不该覆盖")
                return nil
            } catch {
                return error
            }
        }
        try await waitUntil {
            conn.sentJSONObjects.filter { ($0["method"] as? String) == NonlocalMethods.renameSession }.count == 3
        }
        let renameReq3 = conn.sentJSONObjects.last { ($0["method"] as? String) == NonlocalMethods.renameSession }!
        try conn.enqueueError(id: renameReq3["id"]!, code: -32601, message: "Method not found")
        let renameError = await failTask.value
        XCTAssertEqual(renameError as? SessionRenameError, .unsupportedRemoteRename)
        XCTAssertEqual(serverVM.sessionSummaries.first(where: { $0.id == "s-1" })?.title, "保持原标题")
        XCTAssertEqual(appVM.serverViewModels[server.id]?.sessionSummaries.first(where: { $0.id == "s-1" })?.title, "保持原标题")
        XCTAssertEqual(storage.fetchSessions(forServerId: server.id).first(where: { $0.sessionId == "s-1" })?.title, "保持原标题")

        // getLastMessagePreview ignores .toolCall / "Tool call:" for ACP
        let acpToolOnlyMsg = ChatMessage(
            role: .assistant,
            content: "Tool call: [read] foo.swift (completed)\nClean preview text",
            isStreaming: false,
            segments: [
                AssistantSegment(kind: .toolCall, text: "foo.swift", toolCall: ToolCallDisplay(toolCallId: "t1", title: "Read: foo.swift", kind: "read", status: "completed")),
                AssistantSegment(kind: .message, text: "Clean preview text")
            ]
        )
        appVM.saveMessages([acpToolOnlyMsg], for: server.id, sessionId: "s-prev")
        XCTAssertEqual(appVM.getLastMessagePreview(for: server.id, sessionId: "s-prev"), "Clean preview text")
    }

    func testCCAC6_AppViewModelOfflineLoadPurgesProcessArtifactOnlyCoreDataRows() {
        let suite = "CCAC6.DirtyOnly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let server = ACPServerConfiguration(
            id: UUID(), name: "DirtyACP", scheme: "ws", host: "127.0.0.1:18099",
            token: "tok", workingDirectory: "/tmp"
        )
        storage.saveServer(server)
        let dirtySessionId = "dirty-only-sess"
        storage.saveSession(
            StoredSessionInfo(sessionId: dirtySessionId, title: "Old Title", cwd: "/tmp", updatedAt: Date()),
            forServerId: server.id
        )

        let dirtySegmentMsg = ChatMessage(
            role: .assistant,
            content: "Thought\nTool call: [read] README.md (completed)",
            isStreaming: false,
            segments: [
                AssistantSegment(kind: .thought, text: "Thought"),
                AssistantSegment(kind: .plan, text: "1. Plan step"),
                AssistantSegment(kind: .toolCall, text: "README.md", toolCall: ToolCallDisplay(toolCallId: "tc-dirty", title: "README.md", kind: "read", status: "completed")),
            ]
        )
        let dirtyPlainLineMsg = ChatMessage(
            role: .assistant,
            content: "Tool call: [execute] git status (completed)",
            isStreaming: false
        )
        storage.saveMessages([dirtySegmentMsg.toStoredInfo(), dirtyPlainLineMsg.toStoredInfo()], forSessionId: dirtySessionId, serverId: server.id)
        XCTAssertEqual(storage.fetchMessages(forSessionId: dirtySessionId, serverId: server.id).count, 2)

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        appVM.selectServer(server.id)
        let serverVM = appVM.selectedServerViewModel!
        let sessionVM = serverVM.sessionViewModel(for: dirtySessionId)
        sessionVM.loadChatState(serverId: server.id, sessionId: dirtySessionId, canLoadFromStorage: true)

        XCTAssertTrue(sessionVM.chatMessages.isEmpty)
        XCTAssertTrue(
            storage.fetchMessages(forSessionId: dirtySessionId, serverId: server.id).isEmpty,
            "AppViewModel.persistChatToStorage must purge Core Data rows when sanitization reduces dirty-only history to []"
        )
    }

    func testReloadSessionPreservesVisibleTranscriptDuringInFlightReplay() async throws {
        let suite = "ReloadPreserve.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let server = ACPServerConfiguration(
            id: UUID(), name: "ReloadACP", scheme: "ws", host: "127.0.0.1:18098",
            token: "tok", workingDirectory: "/tmp"
        )
        storage.saveServer(server)

        let conn = ScriptedWebSocketConnection()
        let provider = ScriptedSocketProvider(connections: [conn])
        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )
        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: true
        )
        let serverVM = try XCTUnwrap(appVM.selectedServerViewModel)

        try await respondInitialize(on: conn, loadSession: true)
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let syncReq = try XCTUnwrap(conn.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync })
        try conn.enqueueResponse(id: syncReq["id"]!, result: .object([
            "instanceId": .string("inst-reload"),
            "materializedSessionIds": .array([.string("S-reload")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("S-reload"),
                    "lastActivityAt": .string("2026-11-18T02:47:00Z"),
                    "latestTurn": .object([
                        "turnId": .string("turn-reload-0"),
                        "status": .string("completed"),
                        "lastSeq": .int(1),
                        "truncated": .bool(false),
                        "events": .array([
                            .object([
                                "seq": .int(1),
                                "method": .string("session/update"),
                                "params": .object([
                                    "sessionId": .string("S-reload"),
                                    "update": .object([
                                        "sessionUpdate": .string("agent_message_chunk"),
                                        "content": .object(["type": .string("text"), "text": .string("已有回复")])
                                    ])
                                ])
                            ])
                        ]),
                        "pendingPermissions": .array([])
                    ])
                ])
            ])
        ]))
        try await waitUntil { manager.isSessionMaterialized("S-reload") }
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == "session/list" } }
        let listReq = try XCTUnwrap(conn.sentJSONObjects.first { ($0["method"] as? String) == "session/list" })
        try conn.enqueueResponse(id: listReq["id"]!, result: .object([
            "sessions": .array([
                .object(["sessionId": .string("S-reload"), "title": .string("当前情况"), "cwd": .string("/tmp"), "updatedAt": .string("2026-11-18T02:47:00Z")])
            ])
        ]))

        appVM.openSession("S-reload")
        let vm = try XCTUnwrap(serverVM.existingSessionViewModel(for: "S-reload"))
        XCTAssertEqual(vm.chatMessages.map(\.content), ["已有回复"])
        XCTAssertTrue(conn.sentJSONObjects.filter { ($0["method"] as? String) == "session/load" }.isEmpty)

        // Trigger nonlocal/session_stale while viewing S-reload -> reloadSession runs session/load
        try conn.enqueue(.notification(.init(method: NonlocalMethods.sessionStale, params: .object([
            "instanceId": .string("inst-reload"),
            "sessionId": .string("S-reload"),
            "updatedAt": .string("2026-11-18T02:49:00Z"),
            "reason": .string("background_updated")
        ]))))
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == "session/load" } }

        // Crucial assertion: existing transcript MUST stay visible (never blank []) while session/load is in flight
        XCTAssertTrue(vm.isReplayingHistory)
        XCTAssertEqual(vm.chatMessages.map(\.content), ["已有回复"])

        let loadReq = try XCTUnwrap(conn.sentJSONObjects.first { ($0["method"] as? String) == "session/load" })
        try conn.enqueue(.notification(.init(method: "session/update", params: .object([
            "sessionId": .string("S-reload"),
            "update": .object(["sessionUpdate": .string("user_message_chunk"), "content": .object(["type": .string("text"), "text": .string("旧问题")])])
        ]))))
        try conn.enqueue(.notification(.init(method: "session/update", params: .object([
            "sessionId": .string("S-reload"),
            "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("更新后的完整回复")])])
        ]))))
        try conn.enqueueResponse(id: loadReq["id"]!, result: .object(["sessionId": .string("S-reload")]))

        try await waitUntil { !vm.isReplayingHistory && vm.chatMessages.last?.content == "更新后的完整回复" }
        XCTAssertEqual(vm.chatMessages.map(\.content), ["旧问题", "更新后的完整回复"])
        XCTAssertFalse(vm.isStreaming)
        XCTAssertNil(vm.liveActivityStatus)
    }

    private func makeFullHydrogenConfigOptions(
        modeValue: String = "auto",
        modelValue: String = "gemini-4-hydrogen",
        thoughtValue: String = "xhigh"
    ) -> [ACP.Value] {
        makeHydrogenConfigOptions(modelValue: modelValue, thoughtValue: thoughtValue) + [
            .object([
                "id": .string("mode"),
                "name": .string("Mode"),
                "category": .string("mode"),
                "type": .string("select"),
                "currentValue": .string(modeValue),
                "options": .array([
                    .object(["value": .string("default"), "name": .string("Default")]),
                    .object(["value": .string("accept-edits"), "name": .string("Accept Edits")]),
                    .object(["value": .string("auto"), "name": .string("Auto")]),
                    .object(["value": .string("plan"), "name": .string("Plan")]),
                ]),
            ])
        ]
    }

    private func makeFourModesPayload(currentModeId: String = "auto") -> ACP.Value {
        .object([
            "currentModeId": .string(currentModeId),
            "availableModes": .array([
                .object(["id": .string("default"), "name": .string("Default")]),
                .object(["id": .string("accept-edits"), "name": .string("Accept Edits")]),
                .object(["id": .string("auto"), "name": .string("Auto")]),
                .object(["id": .string("plan"), "name": .string("Plan")]),
            ]),
        ])
    }

    private func makeCommandsArray(_ names: [String]) -> [ACP.Value] {
        names.map { name in
            .object([
                "name": .string(name),
                "description": .string("Command \(name)"),
                "input": .object(["hint": .string("arg")]),
            ])
        }
    }

    func testMCAC4_ReconnectSyncWithoutModesInInitializePreservesModesAndCommandsWithoutSessionLoad() async throws {
        let suite = "MC_AC4.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let c1 = ScriptedWebSocketConnection()
        let c2 = ScriptedWebSocketConnection()
        let provider = ScriptedSocketProvider(connections: [c1, c2])
        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )
        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        appVM.addServer(
            name: "MCAC4",
            scheme: "ws",
            host: "127.0.0.1:18104",
            token: "tok",
            workingDirectory: "/tmp"
        )
        let serverVM = try XCTUnwrap(appVM.selectedServerViewModel)

        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: c1, loadSession: true)
        try await waitUntil { c1.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let sync1 = c1.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try c1.enqueueResponse(id: sync1["id"]!, result: .object(["instanceId": .string("inst-mc4"), "materializedSessionIds": .array([]), "sessions": .array([])]))

        try await waitUntil { c1.sentJSONObjects.contains { ($0["method"] as? String) == "session/list" } }
        let list1 = c1.sentJSONObjects.first { ($0["method"] as? String) == "session/list" }!
        try c1.enqueueResponse(id: list1["id"]!, result: .object([
            "sessions": .array([
                .object(["sessionId": .string("S1"), "title": .string("测试会话"), "cwd": .string("/tmp"), "updatedAt": .string("2026-11-18T01:00:00Z")])
            ])
        ]))

        appVM.openSession("S1")
        try await waitUntil { c1.sentJSONObjects.contains { ($0["method"] as? String) == "session/load" } }
        let load1 = c1.sentJSONObjects.first { ($0["method"] as? String) == "session/load" }!
        try c1.enqueue(.notification(.init(method: "session/update", params: .object([
            "sessionId": .string("S1"),
            "update": .object([
                "sessionUpdate": .string("available_commands_update"),
                "availableCommands": .array(makeCommandsArray(["compact", "goal"]))
            ])
        ]))))
        try c1.enqueueResponse(id: load1["id"]!, result: .object([
            "sessionId": .string("S1"),
            "modes": makeFourModesPayload(currentModeId: "auto"),
            "configOptions": .array(makeFullHydrogenConfigOptions(modeValue: "auto"))
        ]))
        let vmS1 = try XCTUnwrap(serverVM.existingSessionViewModel(for: "S1"))
        try await waitUntil { vmS1.availableModes.count == 4 && vmS1.availableCommands.count == 2 }

        // Simulate disconnect and reconnect where initialize omits modes AND -32601 triggers updateAgentInfo
        c1.simulateDrop()
        try await waitUntil { appVM.connectionState != .connected }
        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: c2, loadSession: true)
        try await waitUntil { c2.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }

        // Complete nonlocal/sync first (SD-1.2 gates business RPCs behind valid instanceId)
        let sync2 = c2.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try c2.enqueueResponse(id: sync2["id"]!, result: .object([
            "instanceId": .string("inst-mc4"),
            "materializedSessionIds": .array([.string("S1")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("S1"),
                    "modes": makeFourModesPayload(currentModeId: "auto"),
                    "configOptions": .array(makeFullHydrogenConfigOptions(modeValue: "auto")),
                    "availableCommands": .array(makeCommandsArray(["compact", "goal"])),
                    "latestTurn": .object([
                        "turnId": .string("t-1"),
                        "status": .string("completed"),
                        "lastSeq": .int(1),
                        "truncated": .bool(false),
                        "stopReason": .string("end_turn"),
                        "events": .array([
                            .object([
                                "seq": .int(1),
                                "method": .string("session/update"),
                                "params": .object([
                                    "sessionId": .string("S1"),
                                    "update": .object([
                                        "sessionUpdate": .string("agent_message_chunk"),
                                        "content": .object(["type": .string("text"), "text": .string("已回复")])
                                    ])
                                ])
                            ])
                        ]),
                        "pendingPermissions": .array([])
                    ])
                ])
            ])
        ]))
        try await waitUntil { manager.isSessionMaterialized("S1") }

        // Respond to session/list with -32601 to verify updateAgentInfo keeps availableModes intact
        try await waitUntil { c2.sentJSONObjects.contains { ($0["method"] as? String) == "session/list" } }
        let list2 = c2.sentJSONObjects.first { ($0["method"] as? String) == "session/list" }!
        try c2.enqueueError(id: list2["id"]!, code: -32601, message: "Method not found")

        appVM.openSession("S1")
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(
            c2.sentJSONObjects.filter { ($0["method"] as? String) == "session/load" }.count,
            0,
            "Materialized S1 must emit 0 session/load requests after reconnect"
        )
        XCTAssertEqual(vmS1.availableModes.map(\.id), ["default", "accept-edits", "auto", "plan"])
        XCTAssertEqual(vmS1.currentModeId, "auto")
        XCTAssertEqual(vmS1.visibleConfigOptions().map(\.id), ["model", "thought_level"])
        XCTAssertEqual(vmS1.availableCommands.map(\.name), ["compact", "goal"])
    }

    func testMCAC5_ColdLaunchSyncAndSessionSwitchPreservesModesAndCommandsWhileHistoricalSessionStillLoads() async throws {
        let coldSuite = "MC_AC5.\(UUID().uuidString)"
        let coldDefaults = UserDefaults(suiteName: coldSuite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: coldSuite) }
        let coldStorage = SessionStorage.inMemory()
        let coldServer = ACPServerConfiguration(
            id: UUID(), name: "ColdAC5", scheme: "ws", host: "127.0.0.1:18105",
            token: "tok", workingDirectory: "/tmp"
        )
        coldStorage.saveServer(coldServer)
        coldStorage.saveSession(StoredSessionInfo(sessionId: "S1", title: "活跃会话1", cwd: "/tmp", updatedAt: Date()), forServerId: coldServer.id)
        coldStorage.saveSession(StoredSessionInfo(sessionId: "S2", title: "历史会话2", cwd: "/tmp", updatedAt: Date().addingTimeInterval(-120)), forServerId: coldServer.id)
        coldStorage.saveMessages([StoredMessageInfo(messageId: UUID(), role: "user", content: "hi", createdAt: Date(), segmentsData: nil)], forSessionId: "S1", serverId: coldServer.id)

        let conn = ScriptedWebSocketConnection()
        let provider = ScriptedSocketProvider(connections: [conn])
        let manager = ACPClientManager(
            defaults: coldDefaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )
        let coldApp = AppViewModel(
            storage: coldStorage,
            defaults: coldDefaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: true
        )
        let serverVM = try XCTUnwrap(coldApp.selectedServerViewModel)
        XCTAssertTrue(serverVM.availableModes.isEmpty)

        try await respondInitialize(on: conn, loadSession: true)
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let syncReq = conn.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try conn.enqueueResponse(id: syncReq["id"]!, result: .object([
            "instanceId": .string("inst-mc5"),
            "materializedSessionIds": .array([.string("S1")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("S1"),
                    "modes": makeFourModesPayload(currentModeId: "auto"),
                    "configOptions": .array(makeFullHydrogenConfigOptions(modeValue: "auto")),
                    "availableCommands": .array(makeCommandsArray(["compact", "goal"])),
                    "latestTurn": .object([
                        "turnId": .string("t-mc5"),
                        "status": .string("completed"),
                        "lastSeq": .int(1),
                        "truncated": .bool(false),
                        "stopReason": .string("end_turn"),
                        "events": .array([
                            .object([
                                "seq": .int(1),
                                "method": .string("session/update"),
                                "params": .object([
                                    "sessionId": .string("S1"),
                                    "update": .object([
                                        "sessionUpdate": .string("agent_message_chunk"),
                                        "content": .object(["type": .string("text"), "text": .string("冷启动恢复")])
                                    ])
                                ])
                            ])
                        ]),
                        "pendingPermissions": .array([])
                    ])
                ]),
                .object([
                    "sessionId": .string("S2"),
                    "modes": makeFourModesPayload(currentModeId: "plan"),
                    "configOptions": .array(makeFullHydrogenConfigOptions(modeValue: "plan")),
                    "availableCommands": .array(makeCommandsArray(["help"]))
                ])
            ])
        ]))

        try await waitUntil { manager.isSessionMaterialized("S1") }
        XCTAssertFalse(manager.isSessionMaterialized("S2"), "Un-activated S2 without latestTurn must remain unmaterialized per cdd92ee")

        coldApp.openSession("S1")
        let s1VM = try XCTUnwrap(serverVM.existingSessionViewModel(for: "S1"))
        XCTAssertEqual(conn.sentJSONObjects.filter { ($0["method"] as? String) == "session/load" }.count, 0)
        XCTAssertEqual(s1VM.availableModes.map(\.id), ["default", "accept-edits", "auto", "plan"])
        XCTAssertEqual(s1VM.currentModeId, "auto")
        XCTAssertEqual(s1VM.visibleConfigOptions().map(\.id), ["model", "thought_level"])
        XCTAssertEqual(s1VM.availableCommands.map(\.name), ["compact", "goal"])

        // Switching to un-activated S2 must still issue 1 session/load per cdd92ee
        coldApp.openSession("S2")
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == "session/load" } }
        let loadS2 = try XCTUnwrap(conn.sentJSONObjects.first { ($0["method"] as? String) == "session/load" })
        XCTAssertEqual((loadS2["params"] as? [String: Any])?["sessionId"] as? String, "S2")
        try conn.enqueue(.notification(.init(method: "session/update", params: .object([
            "sessionId": .string("S2"),
            "update": .object([
                "sessionUpdate": .string("available_commands_update"),
                "availableCommands": .array(makeCommandsArray(["help"]))
            ])
        ]))))
        try conn.enqueueResponse(id: loadS2["id"]!, result: .object([
            "sessionId": .string("S2"),
            "modes": makeFourModesPayload(currentModeId: "plan"),
            "configOptions": .array(makeFullHydrogenConfigOptions(modeValue: "plan"))
        ]))
        let s2VM = try XCTUnwrap(serverVM.existingSessionViewModel(for: "S2"))
        try await waitUntil { s2VM.availableModes.count == 4 && s2VM.availableCommands.map(\.name) == ["help"] }

        // Switching back to S1 preserves S1's modes & commands without wiping or issuing session/load
        coldApp.openSession("S1")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(conn.sentJSONObjects.filter { ($0["method"] as? String) == "session/load" }.count, 1)
        XCTAssertEqual(s1VM.availableModes.map(\.id), ["default", "accept-edits", "auto", "plan"])
        XCTAssertEqual(s1VM.currentModeId, "auto")
        XCTAssertEqual(s1VM.visibleConfigOptions().map(\.id), ["model", "thought_level"])
        XCTAssertEqual(s1VM.availableCommands.map(\.name), ["compact", "goal"])
    }

    func testMCAC6_SendLoadSessionFailureFallbackPreservesCachedModesAndCommands() async throws {
        let suite = "MC_AC6_Fallback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let conn = ScriptedWebSocketConnection()
        let provider = ScriptedSocketProvider(connections: [conn])
        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )
        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        appVM.addServer(
            name: "MCAC6Fallback",
            scheme: "ws",
            host: "127.0.0.1:18106",
            token: "tok",
            workingDirectory: "/tmp"
        )
        let serverVM = try XCTUnwrap(appVM.selectedServerViewModel)

        beginConnectAndInitialize(appVM)
        try await respondInitialize(on: conn, loadSession: true)
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let syncReq = conn.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync }!
        try conn.enqueueResponse(id: syncReq["id"]!, result: .object([
            "instanceId": .string("inst-mc6"),
            "materializedSessionIds": .array([]),
            "sessions": .array([
                .object([
                    "sessionId": .string("S-fallback"),
                    "modes": makeFourModesPayload(currentModeId: "plan"),
                    "configOptions": .array(makeFullHydrogenConfigOptions(modeValue: "plan")),
                    "availableCommands": .array(makeCommandsArray(["compact"]))
                ])
            ])
        ]))
        try await waitUntil { serverVM.cachedModes(for: "S-fallback") != nil }

        appVM.openSession("S-fallback")
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == "session/load" } }
        let loadReq = try XCTUnwrap(conn.sentJSONObjects.first { ($0["method"] as? String) == "session/load" })
        try conn.enqueueError(id: loadReq["id"]!, code: -32601, message: "Method not found")

        let vm = try XCTUnwrap(serverVM.existingSessionViewModel(for: "S-fallback"))
        try await waitUntil { !vm.isReplayingHistory }
        XCTAssertEqual(serverVM.agentInfo?.capabilities.loadSession, true, "SD-1.8/SD-2.9: -32601 must not silently downgrade loadSession")
        XCTAssertEqual(vm.availableModes.map(\.id), ["default", "accept-edits", "auto", "plan"])
        XCTAssertEqual(vm.currentModeId, "plan")
        XCTAssertEqual(vm.availableCommands.map(\.name), ["compact"])
        XCTAssertEqual(vm.visibleConfigOptions().map(\.id), ["model", "thought_level"])
    }
}

private extension Result where Success == WebSocketEvent, Failure == Error {
    static var resolvedClose: Result<WebSocketEvent, Error> {
        .success(.closed(WebSocketCloseReason(code: 1000, reason: nil)))
    }
}

private extension ACPError {
    static func from(code: Int, message: String) -> ACPError {
        let json = "{\"code\":\(code),\"message\":\(String(data: try! JSONSerialization.data(withJSONObject: [message]), encoding: .utf8)!.dropFirst().dropLast())}"
        return try! JSONDecoder().decode(ACPError.self, from: Data(json.utf8))
    }
}
