import Combine
import XCTest
import ACP
@testable import Agmente
import ACPClient

@MainActor
final class ACPSessionViewModelTests: XCTestCase {

    // MARK: - Mock Delegates

    /// Mock implementation of ACPSessionCacheDelegate for testing.
    private final class MockCacheDelegate: ACPSessionCacheDelegate, ACPSessionStorageDelegate {
        var savedMessages: [UUID: [String: [ChatMessage]]] = [:]
        var savedStopReasons: [UUID: [String: String]] = [:]
        var saveCalls: [(serverId: UUID, sessionId: String)] = []
        var loadCalls: [(serverId: UUID, sessionId: String)] = []
        var clearCalls: [(serverId: UUID, sessionId: String?)] = []
        var migrateCalls: [(serverId: UUID, from: String, to: String)] = []
        var storedMessages: [String: [UUID: [ChatMessage]]] = [:] // sessionId -> serverId -> messages
        var persistCalls: [(serverId: UUID, sessionId: String)] = []

        func saveMessages(_ messages: [ChatMessage], for serverId: UUID, sessionId: String) {
            var serverCache = savedMessages[serverId] ?? [:]
            serverCache[sessionId] = messages
            savedMessages[serverId] = serverCache
            saveCalls.append((serverId, sessionId))
        }

        func loadMessages(for serverId: UUID, sessionId: String) -> [ChatMessage]? {
            loadCalls.append((serverId, sessionId))
            return savedMessages[serverId]?[sessionId]
        }

        func saveStopReason(_ reason: String, for serverId: UUID, sessionId: String) {
            var serverCache = savedStopReasons[serverId] ?? [:]
            serverCache[sessionId] = reason
            savedStopReasons[serverId] = serverCache
        }

        func loadStopReason(for serverId: UUID, sessionId: String) -> String? {
            return savedStopReasons[serverId]?[sessionId]
        }

        func clearCache(for serverId: UUID, sessionId: String) {
            savedMessages[serverId]?[sessionId] = nil
            savedStopReasons[serverId]?[sessionId] = nil
            clearCalls.append((serverId, sessionId))
        }

        func clearCache(for serverId: UUID) {
            savedMessages[serverId] = nil
            savedStopReasons[serverId] = nil
            clearCalls.append((serverId, nil))
        }

        func migrateCache(serverId: UUID, from placeholderId: String, to resolvedId: String) {
            migrateCalls.append((serverId, placeholderId, resolvedId))
            if let messages = savedMessages[serverId]?[placeholderId] {
                saveMessages(messages, for: serverId, sessionId: resolvedId)
            }
            if let stopReason = savedStopReasons[serverId]?[placeholderId] {
                saveStopReason(stopReason, for: serverId, sessionId: resolvedId)
            }
        }

        func hasCachedMessages(serverId: UUID, sessionId: String) -> Bool {
            return savedMessages[serverId]?[sessionId] != nil
        }

        func getLastMessagePreview(for serverId: UUID, sessionId: String) -> String? {
            return savedMessages[serverId]?[sessionId]?.last?.content
        }

        func loadChatFromStorage(sessionId: String, serverId: UUID) -> [ChatMessage] {
            return storedMessages[sessionId]?[serverId] ?? []
        }

        func persistChatToStorage(serverId: UUID, sessionId: String, allowEmpty: Bool) {
            persistCalls.append((serverId, sessionId))
        }

        func reset() {
            savedMessages = [:]
            savedStopReasons = [:]
            saveCalls = []
            loadCalls = []
            clearCalls = []
            migrateCalls = []
            storedMessages = [:]
            persistCalls = []
        }
    }

    /// Mock implementation of ACPSessionEventDelegate for testing.
    private final class MockEventDelegate: ACPSessionEventDelegate {
        var modeChanges: [(modeId: String, serverId: UUID, sessionId: String)] = []
        var stopReasons: [(reason: String, serverId: UUID, sessionId: String)] = []
        var loadCompletions: [(serverId: UUID, sessionId: String)] = []

        func sessionModeDidChange(_ modeId: String, serverId: UUID, sessionId: String) {
            modeChanges.append((modeId, serverId, sessionId))
        }

        func sessionDidReceiveStopReason(_ reason: String, serverId: UUID, sessionId: String) {
            stopReasons.append((reason, serverId, sessionId))
        }

        func sessionLoadDidComplete(serverId: UUID, sessionId: String) {
            loadCompletions.append((serverId, sessionId))
        }

        func reset() {
            modeChanges = []
            stopReasons = []
            loadCompletions = []
        }
    }

    // MARK: - Test Helpers

    private var appendMessages: [String] = []
    private var wireMessages: [(direction: String, message: ACPWireMessage)] = []

    private func makeDependencies(service: ACPService? = nil) -> ACPSessionViewModel.Dependencies {
        return ACPSessionViewModel.Dependencies(
            getService: { service },
            append: { [weak self] message in
                self?.appendMessages.append(message)
            },
            logWire: { [weak self] direction, message in
                self?.wireMessages.append((direction, message))
            }
        )
    }

    private func makeViewModel(service: ACPService? = nil, cacheDelegate: ACPSessionCacheDelegate? = nil, eventDelegate: ACPSessionEventDelegate? = nil) -> ACPSessionViewModel {
        let viewModel = ACPSessionViewModel(dependencies: makeDependencies(service: service))
        viewModel.cacheDelegate = cacheDelegate
        viewModel.storageDelegate = cacheDelegate as? ACPSessionStorageDelegate
        viewModel.eventDelegate = eventDelegate
        return viewModel
    }

    private func resetTestState() {
        appendMessages = []
        wireMessages = []
    }

    override func setUp() {
        super.setUp()
        resetTestState()
    }

    // MARK: - Chat State Management Tests

    func testSaveChatState_DelegatesToCache() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        // Set session context
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        // Add some messages
        viewModel.addUserMessage(content: "Hello", images: [])

        // Verify cache delegate was called
        XCTAssertFalse(cacheDelegate.saveCalls.isEmpty, "saveChatState should call cacheDelegate.saveMessages")
        XCTAssertEqual(cacheDelegate.saveCalls.last?.serverId, serverId)
        XCTAssertEqual(cacheDelegate.saveCalls.last?.sessionId, sessionId)
        XCTAssertEqual(cacheDelegate.savedMessages[serverId]?[sessionId]?.count, 1)
        XCTAssertEqual(cacheDelegate.savedMessages[serverId]?[sessionId]?.first?.content, "Hello")
    }

    func testSaveChatState_WithStopReason_SavesBoth() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)
        viewModel.setStopReason("max_tokens")

        // Verify stop reason was saved
        XCTAssertEqual(cacheDelegate.savedStopReasons[serverId]?[sessionId], "max_tokens")
    }

    func testSaveChatState_WithoutSessionContext_DoesNotSave() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        // Don't set session context
        viewModel.addUserMessage(content: "Hello", images: [])

        // Verify no save occurred
        XCTAssertTrue(cacheDelegate.saveCalls.isEmpty, "Should not save without session context")
    }

    func testLoadChatState_FromCache_LoadsSuccessfully() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        // Pre-populate cache
        let cachedMessages = [
            ChatMessage(role: .user, content: "Cached message", isStreaming: false)
        ]
        cacheDelegate.saveMessages(cachedMessages, for: serverId, sessionId: sessionId)
        cacheDelegate.saveStopReason("end_turn", for: serverId, sessionId: sessionId)

        // Load state
        viewModel.loadChatState(serverId: serverId, sessionId: sessionId, canLoadFromStorage: false)

        // Verify loaded from cache
        XCTAssertEqual(viewModel.chatMessages.count, 1)
        XCTAssertEqual(viewModel.chatMessages.first?.content, "Cached message")
        XCTAssertEqual(viewModel.stopReason, "end_turn")
        XCTAssertFalse(cacheDelegate.loadCalls.isEmpty, "Should have called loadMessages")
    }

    func testLoadChatState_FromStorage_WhenCacheEmpty() {
        let cacheDelegate = MockCacheDelegate()
        let viewModel = makeViewModel(cacheDelegate: cacheDelegate)

        let serverId = UUID()
        let sessionId = "test-session"

        // Pre-populate storage
        let messages = [
            ChatMessage(role: .user, content: "Stored message", isStreaming: false)
        ]
        cacheDelegate.storedMessages[sessionId] = [serverId: messages]

        // Load state (cache is empty, should fallback to storage)
        viewModel.loadChatState(serverId: serverId, sessionId: sessionId, canLoadFromStorage: true)

        // Verify loaded from storage
        XCTAssertEqual(viewModel.chatMessages.count, 1)
        XCTAssertEqual(viewModel.chatMessages.first?.content, "Stored message")

        // Verify storage messages were cached
        XCTAssertEqual(cacheDelegate.savedMessages[serverId]?[sessionId]?.count, 1)

        // Verify append message was called
        XCTAssertTrue(appendMessages.contains { $0.contains("Restored 1 message") })
    }

    func testLoadChatState_EmptyCacheAndNoStorage_LoadsEmpty() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        // Load state (nothing in cache or storage)
        viewModel.loadChatState(serverId: serverId, sessionId: sessionId, canLoadFromStorage: true)

        // Verify empty state
        XCTAssertTrue(viewModel.chatMessages.isEmpty)
        XCTAssertEqual(viewModel.stopReason, "")
    }

    func testResetChatState_ClearsAllState() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        // Set up some state
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)
        viewModel.addUserMessage(content: "Test", images: [])
        viewModel.setStopReason("max_tokens")

        // Reset
        viewModel.resetChatState()

        // Verify all state cleared
        XCTAssertTrue(viewModel.chatMessages.isEmpty)
        XCTAssertEqual(viewModel.stopReason, "")
    }

    func testSetChatMessages_SetsDirectly() {
        let viewModel = makeViewModel()

        let messages = [
            ChatMessage(role: .user, content: "Message 1", isStreaming: false),
            ChatMessage(role: .assistant, content: "Message 2", isStreaming: false)
        ]

        viewModel.setChatMessages(messages)

        XCTAssertEqual(viewModel.chatMessages.count, 2)
        XCTAssertEqual(viewModel.chatMessages[0].content, "Message 1")
        XCTAssertEqual(viewModel.chatMessages[1].content, "Message 2")
    }

    // MARK: - Event Delegate Tests

    func testHandleStopReason_CallsDelegate() {
        let viewModel = makeViewModel()
        let eventDelegate = MockEventDelegate()
        viewModel.eventDelegate = eventDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)
        viewModel.handleStopReason("max_tokens", serverId: serverId, sessionId: sessionId)

        // Verify delegate was called
        XCTAssertEqual(eventDelegate.stopReasons.count, 1)
        XCTAssertEqual(eventDelegate.stopReasons.first?.reason, "max_tokens")
        XCTAssertEqual(eventDelegate.stopReasons.first?.serverId, serverId)
        XCTAssertEqual(eventDelegate.stopReasons.first?.sessionId, sessionId)

        // Verify stop reason was set
        XCTAssertEqual(viewModel.stopReason, "max_tokens")
    }

    func testHandleSessionLoadCompleted_CallsDelegate() {
        let viewModel = makeViewModel()
        let eventDelegate = MockEventDelegate()
        viewModel.eventDelegate = eventDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        viewModel.handleSessionLoadCompleted(serverId: serverId, sessionId: sessionId)

        // Verify delegate was called
        XCTAssertEqual(eventDelegate.loadCompletions.count, 1)
        XCTAssertEqual(eventDelegate.loadCompletions.first?.serverId, serverId)
        XCTAssertEqual(eventDelegate.loadCompletions.first?.sessionId, sessionId)
    }

    func testModeChange_CallsEventDelegate() {
        let viewModel = makeViewModel()
        let eventDelegate = MockEventDelegate()
        viewModel.eventDelegate = eventDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        // Simulate mode change event
        let params: ACP.Value = .object([
            "sessionId": .string(sessionId),
            "update": .object([
                "sessionUpdate": .string("current_mode_update"),
                "modeId": .string("code")
            ])
        ])

        viewModel.handleChatUpdate(params, activeSessionId: sessionId, serverId: serverId)

        // Verify mode was updated
        XCTAssertEqual(viewModel.currentModeId, "code")

        // Verify delegate was called
        XCTAssertEqual(eventDelegate.modeChanges.count, 1)
        XCTAssertEqual(eventDelegate.modeChanges.first?.modeId, "code")
        XCTAssertEqual(eventDelegate.modeChanges.first?.serverId, serverId)
        XCTAssertEqual(eventDelegate.modeChanges.first?.sessionId, sessionId)
    }

    // MARK: - Message Composition Tests

    func testAddUserMessage_AddsToChat() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        viewModel.addUserMessage(content: "Hello world", images: [])

        XCTAssertEqual(viewModel.chatMessages.count, 1)
        XCTAssertEqual(viewModel.chatMessages.first?.role, .user)
        XCTAssertEqual(viewModel.chatMessages.first?.content, "Hello world")
        XCTAssertFalse(viewModel.chatMessages.first?.isStreaming ?? true)
    }

    func testStartNewStreamingResponse_AddsStreamingMessage() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        viewModel.startNewStreamingResponse()

        XCTAssertEqual(viewModel.chatMessages.count, 1)
        XCTAssertEqual(viewModel.chatMessages.first?.role, .assistant)
        XCTAssertEqual(viewModel.chatMessages.first?.content, "")
        XCTAssertTrue(viewModel.chatMessages.first?.isStreaming ?? false)
    }

    func testAddSystemErrorMessage_AddsErrorMessage() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        viewModel.addSystemErrorMessage("Connection failed")

        XCTAssertEqual(viewModel.chatMessages.count, 1)
        XCTAssertEqual(viewModel.chatMessages.first?.role, .system)
        XCTAssertEqual(viewModel.chatMessages.first?.content, "Connection failed")
        XCTAssertTrue(viewModel.chatMessages.first?.isError ?? false)
    }

    // MARK: - Mode State Management Tests

    func testSetCurrentModeId_UpdatesMode() {
        let viewModel = makeViewModel()

        viewModel.setCurrentModeId("test-mode")

        XCTAssertEqual(viewModel.currentModeId, "test-mode")
    }

    func testCacheCurrentMode_StoresMode() {
        let viewModel = makeViewModel()
        let serverId = UUID()
        let sessionId = "test-session"

        viewModel.setCurrentModeId("code")
        viewModel.cacheCurrentMode(serverId: serverId, sessionId: sessionId)

        let cached = viewModel.cachedMode(for: serverId, sessionId: sessionId)
        XCTAssertEqual(cached, "code")
    }

    func testMigrateSessionModeCache_MigratesSuccessfully() {
        let viewModel = makeViewModel()
        let serverId = UUID()
        let placeholderId = "placeholder-123"
        let resolvedId = "resolved-456"

        // Set mode for placeholder
        viewModel.setCurrentModeId("test-mode")
        viewModel.cacheCurrentMode(serverId: serverId, sessionId: placeholderId)

        // Migrate
        viewModel.migrateSessionModeCache(for: serverId, from: placeholderId, to: resolvedId)

        // Verify migrated
        XCTAssertEqual(viewModel.cachedMode(for: serverId, sessionId: resolvedId), "test-mode")
    }

    func testMigrateSessionModeCache_DoesNotOverwriteExisting() {
        let viewModel = makeViewModel()
        let serverId = UUID()
        let placeholderId = "placeholder-123"
        let resolvedId = "resolved-456"

        // Set mode for both
        viewModel.setCurrentModeId("mode-1")
        viewModel.cacheCurrentMode(serverId: serverId, sessionId: placeholderId)

        viewModel.setCurrentModeId("mode-2")
        viewModel.cacheCurrentMode(serverId: serverId, sessionId: resolvedId)

        // Migrate (should not overwrite)
        viewModel.migrateSessionModeCache(for: serverId, from: placeholderId, to: resolvedId)

        // Verify not overwritten
        XCTAssertEqual(viewModel.cachedMode(for: serverId, sessionId: resolvedId), "mode-2")
    }

    // MARK: - State Transition Tests

    func testStateTransition_LoadActiveReset() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        // 1. Load state (empty)
        viewModel.loadChatState(serverId: serverId, sessionId: sessionId, canLoadFromStorage: false)
        XCTAssertTrue(viewModel.chatMessages.isEmpty)

        // 2. Active - add messages
        viewModel.addUserMessage(content: "Message 1", images: [])
        viewModel.addUserMessage(content: "Message 2", images: [])
        XCTAssertEqual(viewModel.chatMessages.count, 2)

        // 3. Reset
        viewModel.resetChatState()
        XCTAssertTrue(viewModel.chatMessages.isEmpty)
    }

    func testStateTransition_SaveAndReload() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        // Set context and add messages
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)
        viewModel.addUserMessage(content: "Saved message", images: [])
        viewModel.setStopReason("end_turn")

        // Verify saved to cache
        XCTAssertFalse(cacheDelegate.savedMessages.isEmpty)

        // Reset and reload
        viewModel.resetChatState()
        XCTAssertTrue(viewModel.chatMessages.isEmpty)

        viewModel.loadChatState(serverId: serverId, sessionId: sessionId, canLoadFromStorage: false)

        // Verify reloaded
        XCTAssertEqual(viewModel.chatMessages.count, 1)
        XCTAssertEqual(viewModel.chatMessages.first?.content, "Saved message")
        XCTAssertEqual(viewModel.stopReason, "end_turn")
    }

    func testMultipleSessionsCache_IsolatedProperly() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId1 = UUID()
        let serverId2 = UUID()
        let sessionId1 = "session-1"
        let sessionId2 = "session-2"

        // Session 1
        viewModel.loadChatState(serverId: serverId1, sessionId: sessionId1, canLoadFromStorage: false)
        viewModel.addUserMessage(content: "Session 1 message", images: [])

        // Switch to Session 2
        viewModel.loadChatState(serverId: serverId2, sessionId: sessionId2, canLoadFromStorage: false)
        viewModel.addUserMessage(content: "Session 2 message", images: [])

        // Verify both cached independently
        XCTAssertEqual(cacheDelegate.savedMessages[serverId1]?[sessionId1]?.first?.content, "Session 1 message")
        XCTAssertEqual(cacheDelegate.savedMessages[serverId2]?[sessionId2]?.first?.content, "Session 2 message")

        // Load session 1 back
        viewModel.loadChatState(serverId: serverId1, sessionId: sessionId1, canLoadFromStorage: false)
        XCTAssertEqual(viewModel.chatMessages.first?.content, "Session 1 message")
    }

    func testStreamingStateRestore_AfterLoad() {
        let viewModel = makeViewModel()
        let cacheDelegate = MockCacheDelegate()
        viewModel.cacheDelegate = cacheDelegate

        let serverId = UUID()
        let sessionId = "test-session"

        // Create messages with streaming state
        let messages = [
            ChatMessage(role: .user, content: "Question", isStreaming: false),
            ChatMessage(role: .assistant, content: "Partial answer...", isStreaming: true)
        ]
        cacheDelegate.saveMessages(messages, for: serverId, sessionId: sessionId)

        // Load and verify streaming state restored
        viewModel.loadChatState(serverId: serverId, sessionId: sessionId, canLoadFromStorage: false)

        XCTAssertEqual(viewModel.chatMessages.count, 2)
        XCTAssertTrue(viewModel.chatMessages.last?.isStreaming ?? false)
    }

    // MARK: - Commands Tests

    func testHandleAvailableCommandsUpdate_UpdatesCommands() {
        let viewModel = makeViewModel()
        let serverId = UUID()
        let sessionId = "test-session"

        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        let commands = [
            SessionCommand(id: "cmd1", name: "test-command", description: "Test", inputHint: nil)
        ]

        viewModel.handleAvailableCommandsUpdate(commands, serverId: serverId, sessionId: sessionId)

        XCTAssertEqual(viewModel.availableCommands.count, 1)
        XCTAssertEqual(viewModel.availableCommands.first?.name, "test-command")
    }

    func testRestoreAvailableCommands_FromCache() {
        let viewModel = makeViewModel()
        let serverId = UUID()
        let sessionId = "test-session"

        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        // Set and cache commands
        let commands = [
            SessionCommand(id: "cmd1", name: "cached-command", description: "Test", inputHint: nil)
        ]
        viewModel.handleAvailableCommandsUpdate(commands, serverId: serverId, sessionId: sessionId)

        // Reset
        viewModel.resetCommands()
        XCTAssertTrue(viewModel.availableCommands.isEmpty)

        // Restore
        viewModel.restoreAvailableCommands(for: serverId, sessionId: sessionId, isNew: false)
        XCTAssertEqual(viewModel.availableCommands.count, 1)
        XCTAssertEqual(viewModel.availableCommands.first?.name, "cached-command")
    }

    // MARK: - Plan Snapshot Tests

    private func planParams(entries: [ACP.Value], sessionId: String) -> ACP.Value {
        .object([
            "sessionId": .string(sessionId),
            "update": .object([
                "sessionUpdate": .string("plan"),
                "entries": .array(entries),
            ]),
        ])
    }

    func testPlanUpdate_PopulatesPlan() {
        let viewModel = makeViewModel()
        let serverId = UUID()
        let sessionId = "test-session"
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        let params = planParams(entries: [
            .object([
                "content": .string("Step one"),
                "priority": .string("high"),
                "status": .string("in_progress"),
            ]),
            .object([
                "content": .string("Step two"),
                "priority": .string("low"),
                "status": .string("pending"),
            ]),
        ], sessionId: sessionId)

        viewModel.handleChatUpdate(params, activeSessionId: sessionId, serverId: serverId)

        XCTAssertEqual(viewModel.plan.count, 2)
        XCTAssertEqual(viewModel.plan[0].content, "Step one")
        XCTAssertEqual(viewModel.plan[0].priority, .high)
        XCTAssertEqual(viewModel.plan[0].status, .inProgress)
        XCTAssertEqual(viewModel.plan[1].status, .pending)
    }

    func testPlanUpdate_ReplacesPriorSnapshot() {
        let viewModel = makeViewModel()
        let serverId = UUID()
        let sessionId = "test-session"
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        viewModel.handleChatUpdate(planParams(entries: [
            .object(["content": .string("Old A"), "status": .string("completed")]),
            .object(["content": .string("Old B"), "status": .string("pending")]),
        ], sessionId: sessionId), activeSessionId: sessionId, serverId: serverId)
        XCTAssertEqual(viewModel.plan.count, 2)

        // A fresh snapshot fully replaces the previous plan.
        viewModel.handleChatUpdate(planParams(entries: [
            .object(["content": .string("New only"), "status": .string("in_progress")]),
        ], sessionId: sessionId), activeSessionId: sessionId, serverId: serverId)

        XCTAssertEqual(viewModel.plan.count, 1)
        XCTAssertEqual(viewModel.plan[0].content, "New only")
    }

    func testPlanUpdate_EmptyEntriesClearsPlan() {
        let viewModel = makeViewModel()
        let serverId = UUID()
        let sessionId = "test-session"
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        viewModel.handleChatUpdate(planParams(entries: [
            .object(["content": .string("Something"), "status": .string("pending")]),
        ], sessionId: sessionId), activeSessionId: sessionId, serverId: serverId)
        XCTAssertFalse(viewModel.plan.isEmpty)

        viewModel.handleChatUpdate(planParams(entries: [], sessionId: sessionId),
                                   activeSessionId: sessionId, serverId: serverId)
        XCTAssertTrue(viewModel.plan.isEmpty)
    }

    func testPlan_ClearedOnLoadChatState() {
        let viewModel = makeViewModel(cacheDelegate: MockCacheDelegate())
        let serverId = UUID()
        let sessionId = "test-session"
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        viewModel.handleChatUpdate(planParams(entries: [
            .object(["content": .string("Lingering"), "status": .string("pending")]),
        ], sessionId: sessionId), activeSessionId: sessionId, serverId: serverId)
        XCTAssertFalse(viewModel.plan.isEmpty)

        // Switching sessions clears the non-persisted plan snapshot.
        viewModel.loadChatState(serverId: serverId, sessionId: "other-session", canLoadFromStorage: false)
        XCTAssertTrue(viewModel.plan.isEmpty)
    }

    func testMigrateSessionCommandsCache_MigratesSuccessfully() {
        let viewModel = makeViewModel()
        let serverId = UUID()
        let placeholderId = "placeholder-123"
        let resolvedId = "resolved-456"

        viewModel.setSessionContext(serverId: serverId, sessionId: placeholderId)

        // Set commands for placeholder
        let commands = [
            SessionCommand(id: "cmd1", name: "test-command", description: "Test", inputHint: nil)
        ]
        viewModel.handleAvailableCommandsUpdate(commands, serverId: serverId, sessionId: placeholderId)

        // Migrate
        viewModel.migrateSessionCommandsCache(for: serverId, from: placeholderId, to: resolvedId)

        // Verify migrated
        viewModel.restoreAvailableCommands(for: serverId, sessionId: resolvedId, isNew: false)
        XCTAssertEqual(viewModel.availableCommands.count, 1)
        XCTAssertEqual(viewModel.availableCommands.first?.name, "test-command")
    }

    // MARK: - Model Config Option (standard ACP configId "model")

    func testVisibleConfigOptions_ShowsModelOption() {
        let viewModel = makeViewModel()
        let modelOption = ACPSessionConfigOption(
            id: ACPModelConfig.configId,
            name: "Model",
            kind: .select(options: [ACPSessionConfigOptionChoice(id: "m1", name: "Model 1")]),
            currentValue: .string("m1")
        )
        viewModel.applySessionConfigOptions([modelOption], serverId: UUID(), sessionId: "s1")

        XCTAssertTrue(viewModel.visibleConfigOptions().contains(where: { $0.id == ACPModelConfig.configId }))
        // The agent-reported current model is adopted.
        XCTAssertEqual(viewModel.currentModelId, "m1")
    }

    func testSendSetModel_NotConnected_DoesNotShowPhantomModel() {
        // Tapping a model while disconnected must not leave the picker showing a
        // phantom active model — the selection is never applied.
        let viewModel = makeViewModel(service: nil)
        viewModel.sendSetModel("claude-opus", sessionId: "s1", serverId: UUID())
        XCTAssertNil(viewModel.selectedModelId)
        XCTAssertNil(viewModel.currentModelId)
    }

    func testSendSetModel_RPCError_RevertsSelection() async throws {
        let connection = RollbackWebSocketConnection()
        let provider = RollbackWebSocketProvider(connection: connection)
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://localhost:1234")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let viewModel = makeViewModel(service: service)

        // Establish a prior selection to revert to.
        let modelOption = ACPSessionConfigOption(
            id: ACPModelConfig.configId,
            name: "Model",
            kind: .select(options: [
                ACPSessionConfigOptionChoice(id: "old-model", name: "Old"),
                ACPSessionConfigOptionChoice(id: "new-model", name: "New"),
            ]),
            currentValue: .string("old-model")
        )
        viewModel.applySessionConfigOptions([modelOption], serverId: UUID(), sessionId: "s1")
        XCTAssertEqual(viewModel.selectedModelId, "old-model")

        viewModel.sendSetModel("new-model", sessionId: "s1", serverId: UUID())
        // Applied optimistically.
        XCTAssertEqual(viewModel.selectedModelId, "new-model")

        // Reject the set with an RPC error; the selection must roll back.
        let requestId = try await waitForRequestId(connection: connection, method: "session/set_config_option")
        try enqueueError(id: requestId, error: .serverError(code: -32000, message: "rejected"), on: connection)

        let reverted = await waitUntil { viewModel.selectedModelId == "old-model" }
        XCTAssertTrue(reverted, "selection should revert to the previous model on RPC error")
    }

    // MARK: - Config Option Update (REPLACE snapshot)

    func testApplySessionConfigOptions_ReplacesSetAndReconcilesModelSelection() {
        let viewModel = makeViewModel()

        // Initial snapshot advertises a model option selecting "m1".
        let first = ACPSessionConfigOption(
            id: ACPModelConfig.configId,
            name: "Model",
            kind: .select(options: [
                ACPSessionConfigOptionChoice(id: "m1", name: "One"),
                ACPSessionConfigOptionChoice(id: "m2", name: "Two"),
            ]),
            currentValue: .string("m1")
        )
        viewModel.applySessionConfigOptions([first], serverId: UUID(), sessionId: "s1")
        XCTAssertEqual(viewModel.selectedModelId, "m1")

        // A server-pushed REPLACE snapshot moves the current model to "m2" and
        // drops down to a single option — the picker selection follows.
        let second = ACPSessionConfigOption(
            id: ACPModelConfig.configId,
            name: "Model",
            kind: .select(options: [ACPSessionConfigOptionChoice(id: "m2", name: "Two")]),
            currentValue: .string("m2")
        )
        viewModel.applySessionConfigOptions([second], serverId: UUID(), sessionId: "s1")

        XCTAssertEqual(viewModel.selectedModelId, "m2")
        XCTAssertEqual(viewModel.currentModelId, "m2")
        // REPLACE: the prior set is gone, only the new option remains.
        XCTAssertEqual(viewModel.sessionConfigOptions.map(\.id), [ACPModelConfig.configId])
        guard case .select(let choices) = viewModel.sessionConfigOptions.first?.kind else {
            return XCTFail("Expected select kind")
        }
        XCTAssertEqual(choices.map(\.id), ["m2"])
    }

    func testApplySessionConfigOptions_ModelLessSnapshotPreservesSelection() {
        // A non-empty snapshot that OMITS the model option must NOT wipe the
        // model selection — only a session switch/reset clears it. This pins the
        // deliberate "don't clear selection when the model option is absent"
        // behavior so a future refactor can't silently start wiping it.
        let viewModel = makeViewModel()
        let modelOption = ACPSessionConfigOption(
            id: ACPModelConfig.configId,
            name: "Model",
            kind: .select(options: [ACPSessionConfigOptionChoice(id: "m1", name: "One")]),
            currentValue: .string("m1")
        )
        viewModel.applySessionConfigOptions([modelOption], serverId: UUID(), sessionId: "s1")
        XCTAssertEqual(viewModel.selectedModelId, "m1")

        // New, non-empty snapshot with only an unrelated boolean option.
        let boolOption = ACPSessionConfigOption(
            id: "yolo",
            name: "YOLO mode",
            kind: .boolean,
            currentValue: .bool(true)
        )
        viewModel.applySessionConfigOptions([boolOption], serverId: UUID(), sessionId: "s1")

        // Selection survives; the config-option set is still REPLACED wholesale.
        XCTAssertEqual(viewModel.selectedModelId, "m1")
        XCTAssertEqual(viewModel.currentModelId, "m1")
        XCTAssertEqual(viewModel.sessionConfigOptions.map(\.id), ["yolo"])
    }

    func testLoadChatState_ResetsConfigOptionsAndModelSelection() {
        let viewModel = makeViewModel()
        let modelOption = ACPSessionConfigOption(
            id: ACPModelConfig.configId,
            name: "Model",
            kind: .select(options: [ACPSessionConfigOptionChoice(id: "m1", name: "One")]),
            currentValue: .string("m1")
        )
        viewModel.applySessionConfigOptions([modelOption], serverId: UUID(), sessionId: "s1")
        XCTAssertEqual(viewModel.selectedModelId, "m1")
        XCTAssertFalse(viewModel.sessionConfigOptions.isEmpty)

        // Switching sessions clears session-scoped config/model state so it
        // cannot bleed into the next session before its snapshot arrives.
        viewModel.loadChatState(serverId: UUID(), sessionId: "s2", canLoadFromStorage: false)

        XCTAssertNil(viewModel.selectedModelId)
        XCTAssertNil(viewModel.currentModelId)
        XCTAssertTrue(viewModel.sessionConfigOptions.isEmpty)
    }

    func testResetChatState_ClearsConfigOptionsAndModelSelection() {
        let viewModel = makeViewModel()
        let modelOption = ACPSessionConfigOption(
            id: ACPModelConfig.configId,
            name: "Model",
            kind: .select(options: [ACPSessionConfigOptionChoice(id: "m1", name: "One")]),
            currentValue: .string("m1")
        )
        viewModel.applySessionConfigOptions([modelOption], serverId: UUID(), sessionId: "s1")

        viewModel.resetChatState()

        XCTAssertNil(viewModel.selectedModelId)
        XCTAssertTrue(viewModel.sessionConfigOptions.isEmpty)
    }

    // MARK: Rollback-test mock transport

    private final class RollbackWebSocketConnection: WebSocketConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var events: [WebSocketEvent] = []
        private var sentTexts: [String] = []

        func connect(headers: [String: String]) async throws {}

        func send(text: String) async throws {
            lock.lock(); sentTexts.append(text); lock.unlock()
        }

        func receive() async throws -> WebSocketEvent {
            while true {
                lock.lock()
                if !events.isEmpty {
                    let event = events.removeFirst()
                    lock.unlock()
                    return event
                }
                lock.unlock()
                try await Task.sleep(nanoseconds: 1_000_000)
            }
        }

        func close() async {}
        func ping() async throws {}

        func enqueue(_ event: WebSocketEvent) {
            lock.lock(); events.append(event); lock.unlock()
        }

        func sentTextsSnapshot() -> [String] {
            lock.lock(); defer { lock.unlock() }; return sentTexts
        }
    }

    private struct RollbackWebSocketProvider: WebSocketProviding, @unchecked Sendable {
        let connection: RollbackWebSocketConnection
        func makeConnection(url: URL) -> WebSocketConnection { connection }
    }

    private func waitForRequestId(
        connection: RollbackWebSocketConnection,
        method: String,
        attempts: Int = 200
    ) async throws -> Int {
        for _ in 0..<attempts {
            for text in connection.sentTextsSnapshot() {
                guard let data = text.data(using: .utf8),
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["method"] as? String == method,
                      let id = object["id"] as? Int else { continue }
                return id
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw XCTSkip("Request \(method) was not sent")
    }

    private func enqueueError(id: Int, error: ACPError, on connection: RollbackWebSocketConnection) throws {
        let response = ACPWireMessage.response(.init(id: .int(id), error: error))
        let data = try JSONEncoder().encode(response)
        connection.enqueue(.text(String(decoding: data, as: UTF8.self)))
    }

    private func waitUntil(attempts: Int = 200, _ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<attempts {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    func testHistoryReplay_BatchesLargeReplayWithSingleCommitAndClearsStreaming() {
        let cacheDelegate = MockCacheDelegate()
        let eventDelegate = MockEventDelegate()
        let viewModel = makeViewModel(cacheDelegate: cacheDelegate, eventDelegate: eventDelegate)
        let serverId = UUID()
        let sessionId = "huge-replay"
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        var chatPublications = 0
        let cancellable = viewModel.$chatMessages
            .dropFirst()
            .sink { _ in chatPublications += 1 }
        defer { cancellable.cancel() }

        let start = CFAbsoluteTimeGetCurrent()
        viewModel.beginHistoryReplay()

        var toolCallCounter = 0
        for turn in 0..<20 {
            let userParams: ACP.Value = .object([
                "sessionId": .string(sessionId),
                "update": .object([
                    "sessionUpdate": .string("user_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("User turn \(turn)")]),
                ]),
            ])
            viewModel.handleSessionUpdateEvents(userParams, activeSessionId: sessionId, serverId: serverId)

            for _ in 0..<15 {
                let thoughtParams: ACP.Value = .object([
                    "sessionId": .string(sessionId),
                    "update": .object([
                        "sessionUpdate": .string("agent_thought_chunk"),
                        "content": .object(["type": .string("text"), "text": .string("Thinking step ")]),
                    ]),
                ])
                viewModel.handleSessionUpdateEvents(thoughtParams, activeSessionId: sessionId, serverId: serverId)
            }

            for t in 0..<35 {
                let tcId = "tc-\(toolCallCounter)"
                toolCallCounter += 1
                // Include an orphaned in_progress tool call on the final turn to verify load completion clears streaming.
                let status = (turn == 19 && t == 34) ? "in_progress" : "completed"
                let tcParams: ACP.Value = .object([
                    "sessionId": .string(sessionId),
                    "update": .object([
                        "sessionUpdate": .string("tool_call"),
                        "toolCallId": .string(tcId),
                        "title": .string("Read File \(tcId)"),
                        "kind": .string("read"),
                        "status": .string(status),
                    ]),
                ])
                viewModel.handleSessionUpdateEvents(tcParams, activeSessionId: sessionId, serverId: serverId)
            }

            for chunk in 0..<8 {
                let msgParams: ACP.Value = .object([
                    "sessionId": .string(sessionId),
                    "update": .object([
                        "sessionUpdate": .string("agent_message_chunk"),
                        "content": .object(["type": .string("text"), "text": .string("Answer \(turn)-\(chunk) ")]),
                    ]),
                ])
                viewModel.handleSessionUpdateEvents(msgParams, activeSessionId: sessionId, serverId: serverId)
            }
        }

        // Mid-replay: no @Published churn and no storage writes yet.
        XCTAssertEqual(chatPublications, 0)
        XCTAssertEqual(cacheDelegate.saveCalls.count, 0)
        XCTAssertEqual(cacheDelegate.persistCalls.count, 0)
        XCTAssertFalse(viewModel.isStreaming)

        viewModel.handleSessionLoadCompleted(serverId: serverId, sessionId: sessionId)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertEqual(chatPublications, 1, "Entire 1160+ event history replay should publish once")
        XCTAssertEqual(cacheDelegate.saveCalls.count, 1)
        XCTAssertEqual(cacheDelegate.persistCalls.count, 1)
        XCTAssertFalse(viewModel.isStreaming)
        XCTAssertTrue(viewModel.chatMessages.allSatisfy { !$0.isStreaming })
        XCTAssertEqual(viewModel.chatMessages.filter { $0.role == .user }.count, 20)
        XCTAssertEqual(viewModel.chatMessages.filter { $0.role == .assistant }.count, 20)
        XCTAssertNil(viewModel.liveActivityStatus)
        let retainedProcessSegments = viewModel.chatMessages
            .flatMap(\.segments)
            .filter { $0.kind == .toolCall || $0.kind == .thought || $0.kind == .plan }
        XCTAssertTrue(retainedProcessSegments.isEmpty)
        XCTAssertFalse(viewModel.chatMessages.contains { $0.content.contains("Tool call:") })
        XCTAssertLessThan(elapsed, 2.0, "Replaying 1160+ events took \(elapsed)s")
    }

    func testStreamingChunks_DeferStoragePersistenceUntilCompletion() {
        let cacheDelegate = MockCacheDelegate()
        let eventDelegate = MockEventDelegate()
        let viewModel = makeViewModel(cacheDelegate: cacheDelegate, eventDelegate: eventDelegate)
        let serverId = UUID()
        let sessionId = "live-session"
        viewModel.setSessionContext(serverId: serverId, sessionId: sessionId)

        viewModel.addUserMessage(content: "Hello", images: [])
        let persistsAfterUser = cacheDelegate.persistCalls.count
        XCTAssertEqual(persistsAfterUser, 1)

        for i in 0..<25 {
            viewModel.appendAssistantText("chunk-\(i) ", kind: .message)
        }
        let tcParams: ACP.Value = .object([
            "sessionId": .string(sessionId),
            "update": .object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("live-tc-1"),
                "title": .string("Run check"),
                "kind": .string("execute"),
                "status": .string("in_progress"),
            ]),
        ])
        viewModel.handleSessionUpdateEvents(tcParams, activeSessionId: sessionId, serverId: serverId)

        // In-memory cache is kept warm per chunk, while Core Data storage isn't rewritten 26 times mid-turn.
        XCTAssertGreaterThan(cacheDelegate.saveCalls.count, 20)
        XCTAssertEqual(cacheDelegate.persistCalls.count, persistsAfterUser)

        viewModel.handleStopReason("end_turn", serverId: serverId, sessionId: sessionId)
        XCTAssertGreaterThan(cacheDelegate.persistCalls.count, persistsAfterUser)
        XCTAssertFalse(viewModel.isStreaming)
    }

    func testCCAC6_ACPPersistenceAndReloadStripProcessArtifacts() {
        let storage = SessionStorage.inMemory()
        let serverId = UUID()
        let sessionId = "acp-clean-sess"
        storage.saveServer(ACPServerConfiguration(
            id: serverId, name: "CleanACP", scheme: "ws", host: "127.0.0.1:9000",
            token: "", workingDirectory: "/tmp"
        ))

        final class RealStorageDelegate: ACPSessionCacheDelegate, ACPSessionStorageDelegate {
            let storage: SessionStorage
            var memory: [UUID: [String: [ChatMessage]]] = [:]
            var stops: [UUID: [String: String]] = [:]
            var onPersist: ((UUID, String) -> [ChatMessage])?
            init(storage: SessionStorage) { self.storage = storage }
            func saveMessages(_ messages: [ChatMessage], for serverId: UUID, sessionId: String) {
                memory[serverId, default: [:]][sessionId] = messages
            }
            func loadMessages(for serverId: UUID, sessionId: String) -> [ChatMessage]? {
                memory[serverId]?[sessionId]
            }
            func saveStopReason(_ reason: String, for serverId: UUID, sessionId: String) {
                stops[serverId, default: [:]][sessionId] = reason
            }
            func loadStopReason(for serverId: UUID, sessionId: String) -> String? {
                stops[serverId]?[sessionId]
            }
            func clearCache(for serverId: UUID, sessionId: String) {
                memory[serverId]?[sessionId] = nil
            }
            func clearCache(for serverId: UUID) { memory[serverId] = nil }
            func migrateCache(serverId: UUID, from placeholderId: String, to resolvedId: String) {}
            func hasCachedMessages(serverId: UUID, sessionId: String) -> Bool {
                memory[serverId]?[sessionId]?.isEmpty == false
            }
            func getLastMessagePreview(for serverId: UUID, sessionId: String) -> String? { nil }
            func loadChatFromStorage(sessionId: String, serverId: UUID) -> [ChatMessage] {
                storage.fetchMessages(forSessionId: sessionId, serverId: serverId).map { ChatMessage(from: $0) }
            }
            func persistChatToStorage(serverId: UUID, sessionId: String, allowEmpty: Bool) {
                storage.saveSession(StoredSessionInfo(sessionId: sessionId, title: nil, cwd: "/tmp", updatedAt: nil), forServerId: serverId)
                let msgs = onPersist?(serverId, sessionId) ?? (memory[serverId]?[sessionId] ?? [])
                storage.saveMessages(msgs.map { $0.toStoredInfo() }, forSessionId: sessionId, serverId: serverId)
            }
        }

        let cache = RealStorageDelegate(storage: storage)

        // 1. Seed Core Data with dirty legacy data: .thought, .toolCall, .plan segments + plain "Tool call:" lines
        storage.saveSession(StoredSessionInfo(sessionId: sessionId, title: "Clean", cwd: "/tmp", updatedAt: nil), forServerId: serverId)
        let dirtyWithText = ChatMessage(
            role: .assistant,
            content: "Thinking...\nTool call: [read] README.md (completed)\nClean final answer",
            isStreaming: false,
            segments: [
                AssistantSegment(kind: .thought, text: "Thinking..."),
                AssistantSegment(kind: .toolCall, text: "README.md", toolCall: ToolCallDisplay(toolCallId: "old-tc", title: "README.md", kind: "read", status: "completed")),
                AssistantSegment(kind: .plan, text: "1. Do step"),
                AssistantSegment(kind: .message, text: "Clean final answer"),
            ]
        )
        let dirtyToolOnlyPlain = ChatMessage(
            role: .assistant,
            content: "Tool call: [execute] ls (completed)\nTool call: [read] main.swift (completed)",
            isStreaming: false
        )
        let userMsg = ChatMessage(role: .user, content: "Explain this", isStreaming: false)
        let errMsg = ChatMessage(role: .system, content: "Timeout error", isStreaming: false, isError: true)
        storage.saveMessages([userMsg, dirtyWithText, dirtyToolOnlyPlain, errMsg].map { $0.toStoredInfo() }, forSessionId: sessionId, serverId: serverId)

        let acpVM = makeViewModel(cacheDelegate: cache)
        cache.onPersist = { _, _ in acpVM.chatMessages }

        // Offline loadChatState must scrub both memory & Core Data
        acpVM.loadChatState(serverId: serverId, sessionId: sessionId, canLoadFromStorage: true)
        XCTAssertEqual(acpVM.chatMessages.map(\.role), [.user, .assistant, .system])
        XCTAssertEqual(acpVM.chatMessages[1].content, "Clean final answer")
        XCTAssertEqual(acpVM.chatMessages[1].segments.map(\.kind), [.message])
        let resaved = storage.fetchMessages(forSessionId: sessionId, serverId: serverId)
        XCTAssertEqual(resaved.map(\.content), ["Explain this", "Clean final answer", "Timeout error"])
        XCTAssertFalse(resaved.contains { $0.content.contains("Tool call:") })

        // 2. Cached reload & beginHistoryReplay(preserveExistingMessages: true) also scrub
        cache.saveMessages([dirtyWithText, dirtyToolOnlyPlain], for: serverId, sessionId: sessionId)
        acpVM.loadChatState(serverId: serverId, sessionId: sessionId, canLoadFromStorage: false)
        XCTAssertEqual(acpVM.chatMessages.map(\.content), ["Clean final answer"])

        acpVM.beginHistoryReplay(preserveExistingMessages: true)
        acpVM.handleSessionUpdateEvents([
            "sessionId": .string(sessionId),
            "update": .object([
                "sessionUpdate": .string("agent_thought_chunk"),
                "content": .object(["type": .string("text"), "text": .string("Hidden replay thought")])
            ])
        ], activeSessionId: sessionId, serverId: serverId)
        acpVM.handleSessionUpdateEvents([
            "sessionId": .string(sessionId),
            "update": .object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("r-tc"),
                "title": .string("Read file"),
                "kind": .string("read"),
                "status": .string("completed")
            ])
        ], activeSessionId: sessionId, serverId: serverId)
        acpVM.handleSessionUpdateEvents([
            "sessionId": .string(sessionId),
            "update": .object([
                "sessionUpdate": .string("plan"),
                "entries": .array([.object(["content": .string("Plan step"), "priority": .string("high"), "status": .string("pending")])])
            ])
        ], activeSessionId: sessionId, serverId: serverId)
        acpVM.finishHistoryReplay(clearRemainingStreaming: true)
        XCTAssertNil(acpVM.liveActivityStatus, "Replay must never populate liveActivityStatus")
        XCTAssertTrue(acpVM.chatMessages.flatMap(\.segments).allSatisfy { $0.kind == .message })

        // 3. Empty streaming shell without text/images/error is removed on finishStreamingMessage / abandonStreamingMessage
        acpVM.startNewStreamingResponse()
        XCTAssertEqual(acpVM.liveActivityStatus, String(localized: "Thinking…"))
        acpVM.finishStreamingMessage()
        XCTAssertEqual(acpVM.chatMessages.map(\.content), ["Clean final answer"])
        XCTAssertNil(acpVM.liveActivityStatus)

        acpVM.startNewStreamingResponse()
        acpVM.abandonStreamingMessage()
        XCTAssertEqual(acpVM.chatMessages.map(\.content), ["Clean final answer"])
    }

    func testCCAC7_LiveStatusUpdates_ReplayGuard_Dedupe_AndPermissionLifecycle() {
        let vm = makeViewModel()
        let serverId = UUID()
        let sessionId = "acp-live-status"
        vm.setSessionContext(serverId: serverId, sessionId: sessionId)

        var statusTransitions: [String?] = []
        let cancellable = vm.$liveActivityStatus.dropFirst().sink { statusTransitions.append($0) }
        defer { cancellable.cancel() }

        vm.startNewStreamingResponse()
        XCTAssertEqual(vm.liveActivityStatus, String(localized: "Thinking…"))

        // Duplicate thought chunks must dedupe without re-emitting liveActivityStatus
        for _ in 0..<3 {
            vm.handleSessionUpdateEvents([
                "sessionId": .string(sessionId),
                "update": .object([
                    "sessionUpdate": .string("agent_thought_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("pondering")])
                ])
            ], activeSessionId: sessionId, serverId: serverId)
        }
        XCTAssertEqual(statusTransitions.count, 1, "Repeated identical status must be deduplicated")

        vm.handleSessionUpdateEvents([
            "sessionId": .string(sessionId),
            "update": .object([
                "sessionUpdate": .string("tool_call"),
                "toolCallId": .string("tc-live-1"),
                "title": .string("Read AppViewModel.swift"),
                "kind": .string("read"),
                "status": .string("in_progress")
            ])
        ], activeSessionId: sessionId, serverId: serverId)
        XCTAssertEqual(vm.liveActivityStatus, String(localized: "Running: \("Read AppViewModel.swift")"))

        // Permission card arrival + turn end removal
        vm.handlePermissionRequest(ACP.AnyRequest(
            id: .string("perm-turn-end"),
            method: "session/request_permission",
            params: .object([
                "sessionId": .string(sessionId),
                "toolCall": .object([
                    "toolCallId": .string("tc-perm-end"),
                    "title": .string("Edit App.swift"),
                    "kind": .string("edit"),
                    "status": .string("pending")
                ]),
                "options": .array([
                    .object(["optionId": .string("allow"), "name": .string("Allow"), "kind": .string("allow_once")])
                ])
            ])
        ))
        XCTAssertEqual(vm.liveActivityStatus, String(localized: "Waiting for confirmation: \("Edit App.swift")"))
        XCTAssertTrue(vm.chatMessages.flatMap(\.segments).contains { $0.kind == .toolCall && $0.toolCall?.permissionOptions != nil })

        vm.handleStopReason("end_turn", serverId: serverId, sessionId: sessionId)
        XCTAssertNil(vm.liveActivityStatus)
        XCTAssertFalse(vm.ownsPermissionRequest(.string("perm-turn-end")))
        XCTAssertTrue(vm.chatMessages.isEmpty, "Empty assistant shell removed cleanly after turn end strips temporary permission")

        // Cancel lifecycle removes permission card
        vm.startNewStreamingResponse()
        vm.handlePermissionRequest(ACP.AnyRequest(
            id: .string("perm-cancel"),
            method: "session/request_permission",
            params: .object([
                "sessionId": .string(sessionId),
                "toolCall": .object(["toolCallId": .string("tc-cancel"), "title": .string("Run rm"), "kind": .string("execute")]),
                "options": .array([.object(["optionId": .string("allow"), "name": .string("Allow"), "kind": .string("allow_once")])])
            ])
        ))
        XCTAssertEqual(vm.chatMessages.flatMap(\.segments).filter { $0.kind == .toolCall }.count, 1)
        vm.cancelPendingPermissionRequests(for: sessionId)
        vm.abandonStreamingMessage()
        XCTAssertTrue(vm.chatMessages.isEmpty)
        XCTAssertNil(vm.liveActivityStatus)

        // reconcilePendingPermissions removes stale permission card after nonlocal/sync drops it
        vm.startNewStreamingResponse()
        vm.handlePermissionRequest(ACP.AnyRequest(
            id: .string("perm-stale"),
            method: "session/request_permission",
            params: .object([
                "sessionId": .string(sessionId),
                "toolCall": .object(["toolCallId": .string("tc-stale"), "title": .string("Edit A.swift"), "kind": .string("edit")]),
                "options": .array([.object(["optionId": .string("allow"), "name": .string("Allow"), "kind": .string("allow_once")])])
            ])
        ))
        XCTAssertTrue(vm.ownsPermissionRequest(.string("perm-stale")))
        vm.reconcilePendingPermissions(validRequestIds: [])
        XCTAssertFalse(vm.ownsPermissionRequest(.string("perm-stale")))
        XCTAssertTrue(vm.chatMessages.flatMap(\.segments).filter { $0.kind == .toolCall }.isEmpty)
        vm.finishStreamingMessage()
    }

    func testPassiveStreamingAutoSettlesWhileExplicitTurnStaysActive() async throws {
        let serverId = UUID()
        let sessionId = "passive-settle-sess"
        let fastDelays = ACPSessionViewModel.PassiveStreamingSettleDelays(
            usageAfterMessageNs: 40_000_000,      // 40ms
            messageNs: 90_000_000,                // 90ms
            thoughtOrCompletedToolNs: 120_000_000,// 120ms
            activeToolNs: 250_000_000             // 250ms
        )
        let vm = ACPSessionViewModel(
            dependencies: .init(getService: { nil }, append: { _ in }, logWire: { _, _ in }),
            passiveSettleDelays: fastDelays
        )
        vm.setSessionContext(serverId: serverId, sessionId: sessionId)

        // 1. Passive background wakeup stream (no explicit session/prompt): settles cleanly after usage_update
        vm.handleSessionUpdateEvents([
            "sessionId": .string(sessionId),
            "update": .object(["sessionUpdate": .string("agent_thought_chunk"), "content": .object(["type": .string("text"), "text": .string("thinking")])])
        ], activeSessionId: sessionId, serverId: serverId)
        XCTAssertEqual(vm.liveActivityStatus, String(localized: "Thinking…"))

        vm.handleSessionUpdateEvents([
            "sessionId": .string(sessionId),
            "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("后台唤醒已回复完毕")])])
        ], activeSessionId: sessionId, serverId: serverId)
        XCTAssertTrue(vm.isStreaming)
        XCTAssertEqual(vm.liveActivityStatus, String(localized: "Generating reply…"))

        vm.handleSessionUpdateEvents([
            "sessionId": .string(sessionId),
            "update": .object(["sessionUpdate": .string("usage_update"), "used": .int(100), "size": .int(1000)])
        ], activeSessionId: sessionId, serverId: serverId)

        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(vm.isStreaming, "Passive post-prompt wakeup must clear spinner after usage_update quiet window")
        XCTAssertNil(vm.liveActivityStatus)
        XCTAssertEqual(vm.chatMessages.last?.content, "后台唤醒已回复完毕")

        // 2. Passive tool_call in_progress defers settle until completed + final message + usage_update
        vm.handleSessionUpdateEvents([
            "sessionId": .string(sessionId),
            "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("先看工具进展")])])
        ], activeSessionId: sessionId, serverId: serverId)
        vm.handleSessionUpdateEvents([
            "sessionId": .string(sessionId),
            "update": .object(["sessionUpdate": .string("tool_call"), "toolCallId": .string("bg-tc"), "title": .string("Run check"), "kind": .string("execute"), "status": .string("in_progress")])
        ], activeSessionId: sessionId, serverId: serverId)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(vm.isStreaming)
        XCTAssertEqual(vm.liveActivityStatus, String(localized: "Running: \("Run check")"))

        vm.handleSessionUpdateEvents([
            "sessionId": .string(sessionId),
            "update": .object(["sessionUpdate": .string("tool_call_update"), "toolCallId": .string("bg-tc"), "status": .string("completed")])
        ], activeSessionId: sessionId, serverId: serverId)
        vm.handleSessionUpdateEvents([
            "sessionId": .string(sessionId),
            "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("第二段结论")])])
        ], activeSessionId: sessionId, serverId: serverId)
        vm.handleSessionUpdateEvents([
            "sessionId": .string(sessionId),
            "update": .object(["sessionUpdate": .string("usage_update"), "used": .int(150), "size": .int(1000)])
        ], activeSessionId: sessionId, serverId: serverId)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(vm.isStreaming)
        XCTAssertNil(vm.liveActivityStatus)

        // 3. Explicit active turn (startNewStreamingResponse or markExplicitActiveTurn) NEVER auto-settles past passive delays
        vm.startNewStreamingResponse()
        vm.handleSessionUpdateEvents([
            "sessionId": .string(sessionId),
            "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("主动提问输出")])])
        ], activeSessionId: sessionId, serverId: serverId)
        vm.handleSessionUpdateEvents([
            "sessionId": .string(sessionId),
            "update": .object(["sessionUpdate": .string("usage_update"), "used": .int(200), "size": .int(1000)])
        ], activeSessionId: sessionId, serverId: serverId)
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertTrue(vm.isStreaming, "Explicit turn waiting for stopReason must never settle early")
        vm.handleStopReason("end_turn", serverId: serverId, sessionId: sessionId)
        XCTAssertFalse(vm.isStreaming)
        XCTAssertNil(vm.liveActivityStatus)

        vm.markExplicitActiveTurn()
        vm.handleSessionUpdateEvents([
            "sessionId": .string(sessionId),
            "update": .object(["sessionUpdate": .string("agent_message_chunk"), "content": .object(["type": .string("text"), "text": .string("断线重连恢复输出")])])
        ], activeSessionId: sessionId, serverId: serverId)
        try await Task.sleep(nanoseconds: 180_000_000)
        XCTAssertTrue(vm.isStreaming, "Recovered active turn must stay streaming until nonlocal/turn_completed or stopReason")
        vm.handleStopReason("end_turn", serverId: serverId, sessionId: sessionId)
        XCTAssertFalse(vm.isStreaming)
    }

    func testMCAC6_MergePreservingRuntimeStatePreservesCommandsAndEmptySetModesDoesNotClobber() {
        let serverId = UUID()
        let resolvedVM = makeViewModel()
        resolvedVM.setSessionContext(serverId: serverId, sessionId: "resolved-1")
        resolvedVM.applySessionConfigOptions([
            ACPSessionConfigOption(
                id: "mode",
                name: "Mode",
                description: nil,
                category: "mode",
                kind: .select(options: [
                    ACPSessionConfigOptionChoice(id: "default", name: "Default", description: nil),
                    ACPSessionConfigOptionChoice(id: "auto", name: "Auto", description: nil),
                ]),
                currentValue: .string("auto")
            )
        ], serverId: serverId, sessionId: "resolved-1")
        XCTAssertEqual(resolvedVM.availableModes.map(\.id), ["default", "auto"])

        // Passing an empty server-level fallback list must never wipe modes already derived from configOptions
        resolvedVM.setAvailableModes([], currentModeId: "auto")
        XCTAssertEqual(resolvedVM.availableModes.map(\.id), ["default", "auto"])
        XCTAssertEqual(resolvedVM.currentModeId, "auto")

        let placeholderVM = makeViewModel()
        placeholderVM.setSessionContext(serverId: serverId, sessionId: "pending-1")
        placeholderVM.handleAvailableCommandsUpdate([
            SessionCommand(id: "compact", name: "compact", description: "Compact", inputHint: nil),
            SessionCommand(id: "goal", name: "goal", description: "Goal", inputHint: "objective"),
        ], serverId: serverId, sessionId: "pending-1")

        resolvedVM.mergePreservingRuntimeState(from: placeholderVM, serverId: serverId, sessionId: "resolved-1")
        XCTAssertEqual(resolvedVM.availableCommands.map(\.name), ["compact", "goal"])
        XCTAssertEqual(resolvedVM.availableModes.map(\.id), ["default", "auto"])
    }

    // MARK: - W2-AC-403 / SC-AC-072: #4b pre-flight disconnected guard, failed delivery recording, never auto-rewriting promptText, manual restore without auto-resend

    func testW2AC403_DisconnectedPreFlightAndFailedDeliveryNeverAutoRewritesInput() throws {
        let storage = SessionStorage.inMemory()
        let defaults = UserDefaults(suiteName: "W2AC403.\(UUID().uuidString)")!
        let server = ACPServerConfiguration(
            id: UUID(), name: "Off", scheme: "ws", host: "127.0.0.1:19450",
            token: "", workingDirectory: "/tmp"
        )
        storage.saveServer(server)
        let appVM = AppViewModel(storage: storage, defaults: defaults, shouldStartNetworkMonitoring: false, shouldConnectOnStartup: false)
        let serverVM = try XCTUnwrap(appVM.serverViewModels[server.id])

        // 1. Disconnected server: submitPrompt returns false synchronously, 0 user bubbles added
        let vm = serverVM.sessionViewModel(for: "S-off")
        vm.promptText = "Unsent draft"
        let submitted = serverVM.submitPrompt(promptText: "Unsent draft", images: [])
        XCTAssertFalse(submitted, "Disconnected server must fail pre-flight synchronously")
        XCTAssertEqual(vm.promptText, "Unsent draft")
        XCTAssertTrue(vm.chatMessages.isEmpty)

        // 2. Pending delivery fails -> recorded in failedDeliveriesByMessageId, promptText stays empty (never auto-rewritten)
        let userMsgId = vm.addUserMessage(content: "Hello world", images: [])
        vm.promptText = ""
        vm.recordPendingPromptDelivery(userMessageId: userMsgId, promptText: "Hello world", images: [], clientTurnId: "ct-1")
        let errMsgId = vm.addSystemErrorMessage("Connection lost")
        vm.markPendingPromptDeliveryFailed(errorMessageId: errMsgId)

        XCTAssertTrue(vm.failedDeliveryMessageIds.contains(userMsgId))
        XCTAssertEqual(vm.promptText, "", "Failure must NEVER auto-fill promptText")
    }

    // MARK: - W2-AC-404: #4b 4 confirmed delivery / cancel paths clear pending delivery with 0 failedDeliveries

    func testW2AC404_ConfirmedDeliveryAndCancelProduceZeroFailedDeliveries() {
        let vm = makeViewModel()
        let serverId = UUID()
        vm.setSessionContext(serverId: serverId, sessionId: "S-404")

        // Path 1: explicit clearPendingPromptDelivery (e.g. sendPrompt returned / sync matched clientTurnId)
        let m1 = vm.addUserMessage(content: "M1", images: [])
        vm.recordPendingPromptDelivery(userMessageId: m1, promptText: "M1", images: [], clientTurnId: "c1")
        vm.clearPendingPromptDelivery()
        vm.markPendingPromptDeliveryFailed(errorMessageId: nil)
        XCTAssertTrue(vm.failedDeliveryMessageIds.isEmpty)

        // Path 2: non-empty agent_message_chunk arrives -> clears pending delivery so later disconnect does NOT mark failed
        let m2 = vm.addUserMessage(content: "M2", images: [])
        vm.recordPendingPromptDelivery(userMessageId: m2, promptText: "M2", images: [], clientTurnId: "c2")
        vm.appendAssistantText("Partial reply", kind: .message)
        vm.markPendingPromptDeliveryFailed(errorMessageId: nil)
        XCTAssertTrue(vm.failedDeliveryMessageIds.isEmpty, "Non-empty assistant output must confirm delivery")

        // Path 3: user cancel clears pending delivery
        let m3 = vm.addUserMessage(content: "M3", images: [])
        vm.recordPendingPromptDelivery(userMessageId: m3, promptText: "M3", images: [], clientTurnId: "c3")
        vm.clearPendingPromptDelivery()
        vm.markPendingPromptDeliveryFailed(errorMessageId: nil)
        XCTAssertTrue(vm.failedDeliveryMessageIds.isEmpty)
    }

    // MARK: - W2-AC-405: #4b restoreFailedDelivery (empty vs draft + 3+3 image cap, finishHistoryReplay tail-append, merge migration, reset)

    func testW2AC405_RestoreFailedDeliveryImageCapHistoryReplayMergeAndReset() {
        let vm = makeViewModel()
        let serverId = UUID()
        vm.setSessionContext(serverId: serverId, sessionId: "S-405")

        // 1. Empty/whitespace draft -> plain text (no leading newline), removes bubble & error
        let u1 = vm.addUserMessage(content: "Retry me", images: [])
        let e1 = vm.addSystemErrorMessage("Failed")
        vm.recordPendingPromptDelivery(userMessageId: u1, promptText: "Retry me", images: [], clientTurnId: nil)
        vm.markPendingPromptDeliveryFailed(errorMessageId: e1)
        vm.promptText = "   \n  "
        vm.restoreFailedDelivery(for: u1)
        XCTAssertEqual(vm.promptText, "Retry me")
        XCTAssertFalse(vm.chatMessages.contains { $0.id == u1 || $0.id == e1 })
        XCTAssertFalse(vm.failedDeliveryMessageIds.contains(u1))

        // 2. Existing draft "Draft" + 3 draft images + failed 3 images [F1,F2,F3] -> "Draft\nFailedText" + 5 images (cap 5, F3 dropped)
        func makeSolidImage() -> UIImage {
            UIGraphicsBeginImageContextWithOptions(CGSize(width: 4, height: 4), true, 1.0)
            UIColor.red.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 4, height: 4))
            let img = UIGraphicsGetImageFromCurrentImageContext() ?? UIImage()
            UIGraphicsEndImageContext()
            return img
        }
        func makeImg(_ tag: String) -> ImageAttachment {
            ImageAttachment(id: UUID(), image: makeSolidImage(), mimeType: "image/png", base64Data: Data(tag.utf8).base64EncodedString(), originalSize: 1024)
        }
        let fImgs = [makeImg("F1"), makeImg("F2"), makeImg("F3")]
        let u2 = vm.addUserMessage(content: "FailedText", images: [])
        let e2 = vm.addSystemErrorMessage("Err")
        vm.recordPendingPromptDelivery(userMessageId: u2, promptText: "FailedText", images: fImgs, clientTurnId: nil)
        vm.markPendingPromptDeliveryFailed(errorMessageId: e2)

        vm.promptText = "Draft"
        vm.setSupportsImageAttachment(true)
        XCTAssertTrue(vm.addImageAttachment(makeSolidImage()))
        XCTAssertTrue(vm.addImageAttachment(makeSolidImage()))
        XCTAssertTrue(vm.addImageAttachment(makeSolidImage()))
        let draftImageIds = vm.attachedImages.map(\.id)
        vm.restoreFailedDelivery(for: u2)
        XCTAssertEqual(vm.promptText, "Draft\nFailedText")
        XCTAssertEqual(vm.attachedImages.count, 5, "Must cap total attached images at 5")
        XCTAssertEqual(Array(vm.attachedImages.prefix(3).map(\.id)), draftImageIds, "Must preserve all 3 draft images first")
        XCTAssertEqual(Array(vm.attachedImages.suffix(2).map(\.base64Data)), [fImgs[0].base64Data, fImgs[1].base64Data], "Must append F1, F2 and drop F3")

        // 3. finishHistoryReplay preserves un-restored failed bubble pair at tail; mergePreservingRuntimeState migrates; resetChatState clears
        let u3 = vm.addUserMessage(content: "StillFailed", images: [])
        let e3 = vm.addSystemErrorMessage("Err3")
        vm.recordPendingPromptDelivery(userMessageId: u3, promptText: "StillFailed", images: [], clientTurnId: nil)
        vm.markPendingPromptDeliveryFailed(errorMessageId: e3)

        vm.beginHistoryReplay()
        vm.finishHistoryReplay()
        XCTAssertTrue(vm.chatMessages.contains { $0.id == u3 }, "finishHistoryReplay must keep un-restored failed bubble")
        XCTAssertTrue(vm.failedDeliveryMessageIds.contains(u3))

        let resolvedVM = makeViewModel()
        resolvedVM.setSessionContext(serverId: serverId, sessionId: "S-405-resolved")
        resolvedVM.mergePreservingRuntimeState(from: vm, serverId: serverId, sessionId: "S-405-resolved")
        XCTAssertTrue(resolvedVM.failedDeliveryMessageIds.contains(u3))

        resolvedVM.resetChatState()
        XCTAssertTrue(resolvedVM.failedDeliveryMessageIds.isEmpty)
    }

    // MARK: - W2-AC-408: #4c completed snapshot with hasUnresolvedToolCalls == false hits fast-path (no 60s passiveStreamingSettleTask)

    func testW2AC408_CompletedSnapshotWithoutUnresolvedToolsSkipsPassiveWait() {
        let vm = makeViewModel()
        let serverId = UUID()
        vm.setSessionContext(serverId: serverId, sessionId: "S-408")

        // When bridge converges watch window (hasUnresolvedToolCalls: false), session ends streaming immediately
        vm.startNewStreamingResponse()
        vm.finishStreamingMessage()
        XCTAssertFalse(vm.isStreaming)
        XCTAssertFalse(vm.isActivelyRunning)
    }
}