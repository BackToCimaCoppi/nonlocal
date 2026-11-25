import ACP
import Foundation
import XCTest
@testable import ACPClient
import ACPClientMocks

private enum MockFailureError: Error {
    case droppedConnection
}

private final class FailingReceiveWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private var eventContinuation: AsyncStream<Result<WebSocketEvent, Error>>.Continuation?
    private let stream: AsyncStream<Result<WebSocketEvent, Error>>
    public private(set) var isConnected = false
    public private(set) var sentTexts: [String] = []

    init() {
        var continuationRef: AsyncStream<Result<WebSocketEvent, Error>>.Continuation?
        self.stream = AsyncStream { continuation in
            continuationRef = continuation
        }
        self.eventContinuation = continuationRef
    }

    func connect(headers: [String: String]) async throws {
        isConnected = true
    }

    func send(text: String) async throws {
        sentTexts.append(text)
    }

    func receive() async throws -> WebSocketEvent {
        for await item in stream {
            return try item.get()
        }
        throw MockFailureError.droppedConnection
    }

    func close() async {
        isConnected = false
        eventContinuation?.finish()
    }

    func ping() async throws {}

    func failNow(_ error: Error = MockFailureError.droppedConnection) {
        eventContinuation?.yield(.failure(error))
        eventContinuation?.finish()
    }
}

private struct SingleConnectionProvider: WebSocketProviding {
    let connection: WebSocketConnection
    func makeConnection(url: URL) -> WebSocketConnection {
        connection
    }
}

final class NonlocalSessionSyncTests: XCTestCase {

    func testPromptPayloadEncodesNonlocalClientTurnIdMeta() throws {
        let clientTurnId = "12345678-1234-4321-8765-abcdefabcdef"
        let payload = ACPSessionPromptPayload(
            sessionId: "sess-1",
            prompt: [.object(["type": .string("text"), "text": .string("hello")])],
            meta: [NonlocalMethods.clientTurnIdMetaKey: .string(clientTurnId)]
        )

        let params = payload.params().objectValue
        XCTAssertEqual(params?["sessionId"]?.stringValue, "sess-1")
        XCTAssertEqual(
            params?["_meta"]?.objectValue?[NonlocalMethods.clientTurnIdMetaKey]?.stringValue,
            clientTurnId
        )
    }

    func testSyncNonlocalSessionsAndTurnCompletedParsingAndDispatcherIsolation() async throws {
        // P0-AC-3: Verify NonlocalMethods codec, ResponseDispatcher isolation, and -32601 RPC error propagation
        let provider = MockWebSocketProvider()
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://127.0.0.1:19999")!, pingInterval: nil),
            socketProvider: provider
        )
        let service = ACPService(client: client)
        try await service.connect()

        let syncResultValue: ACP.Value = .object([
            "instanceId": .string("inst-uuid-001"),
            "materializedSessionIds": .array([.string("sess-1")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("sess-1"),
                    "modes": .object([
                        "currentModeId": .string("code"),
                        "availableModes": .array([
                            .object(["id": .string("code"), "name": .string("Code")])
                        ])
                    ]),
                    "configOptions": .array([
                        .object([
                            "id": .string("model"),
                            "name": .string("Model"),
                            "type": .string("select"),
                            "currentValue": .string("gemini-4-hydrogen"),
                            "options": .array([
                                .object(["value": .string("gemini-4-hydrogen"), "name": .string("Gemini 4 Hydrogen")])
                            ])
                        ])
                    ]),
                    "latestTurn": .object([
                        "turnId": .string("turn-001"),
                        "clientTurnId": .string("client-turn-001"),
                        "status": .string("active"),
                        "lastSeq": .int(2),
                        "truncated": .bool(true),
                        "events": .array([
                            .object([
                                "seq": .int(2),
                                "method": .string("session/update"),
                                "params": .object([
                                    "sessionId": .string("sess-1"),
                                    "_meta": .object([NonlocalMethods.seqMetaKey: .int(2)]),
                                    "update": .object([
                                        "sessionUpdate": .string("agent_message_chunk"),
                                        "content": .object(["type": .string("text"), "text": .string("mid")])
                                    ])
                                ])
                            ])
                        ]),
                        "pendingPermissions": .array([
                            .object([
                                "requestId": .string("perm-1"),
                                "params": .object([
                                    "sessionId": .string("sess-1"),
                                    "toolCall": .object(["toolCallId": .string("tc-1"), "title": .string("bash")]),
                                    "options": .array([])
                                ])
                            ])
                        ]),
                        "stopReason": .string("end_turn"),
                        "error": .object(["code": .int(-32000), "message": .string("sample")])
                    ])
                ])
            ])
        ])

        let _ = Task {
            let response = ACPWireMessage.response(.init(id: .int(1), result: syncResultValue))
            let data = try JSONEncoder().encode(response)
            provider.connection.enqueue(.text(String(decoding: data, as: UTF8.self)))
        }

        let syncResult = try await service.syncNonlocalSessions()
        XCTAssertEqual(syncResult?.instanceId, "inst-uuid-001")
        XCTAssertEqual(syncResult?.materializedSessionIds, ["sess-1"])
        let session = try XCTUnwrap(syncResult?.sessions.first)
        XCTAssertEqual(session.sessionId, "sess-1")
        XCTAssertEqual(session.modes?.currentModeId, "code")
        XCTAssertEqual(session.configOptions.first?.currentValue.stringValue, "gemini-4-hydrogen")
        let turn = try XCTUnwrap(session.latestTurn)
        XCTAssertEqual(turn.turnId, "turn-001")
        XCTAssertEqual(turn.clientTurnId, "client-turn-001")
        XCTAssertEqual(turn.status, .active)
        XCTAssertEqual(turn.lastSeq, 2)
        XCTAssertTrue(turn.truncated)
        XCTAssertEqual(turn.events.first?.seq, 2)
        XCTAssertEqual(NonlocalSessionSyncParser.parseSeq(from: turn.events.first?.params), 2)
        XCTAssertNil(NonlocalSessionSyncParser.parseTurnId(from: turn.events.first?.params))
        let liveUpdateParams: ACP.Value = .object([
            "sessionId": .string("sess-1"),
            "_meta": .object([
                NonlocalMethods.seqMetaKey: .int(3),
                NonlocalMethods.turnIdMetaKey: .string("turn-001")
            ])
        ])
        XCTAssertEqual(NonlocalSessionSyncParser.parseSeq(from: liveUpdateParams), 3)
        XCTAssertEqual(NonlocalSessionSyncParser.parseTurnId(from: liveUpdateParams), "turn-001")
        XCTAssertEqual(turn.pendingPermissions.first?.requestId, .string("perm-1"))
        XCTAssertEqual(turn.error, NonlocalRPCError(code: -32000, message: "sample"))

        // ResponseDispatcher must NOT trigger .sessionActivated / .stopReason / .initialized for nonlocal/sync
        let pollutedResult: ACP.Value = .object([
            "instanceId": .string("inst-uuid-001"),
            "sessionId": .string("should-ignore"),
            "stopReason": .string("should-ignore"),
            "materializedSessionIds": .array([]),
            "sessions": .array([])
        ])
        let syncActions = ACPResponseDispatcher.dispatchSuccess(
            result: pollutedResult,
            method: NonlocalMethods.sessionSync,
            context: ACPResponseDispatchContext()
        )
        XCTAssertTrue(syncActions.isEmpty)

        let staleActions = ACPResponseDispatcher.dispatchSuccess(
            result: pollutedResult,
            method: NonlocalMethods.sessionStale,
            context: ACPResponseDispatchContext()
        )
        XCTAssertTrue(staleActions.isEmpty)

        let renameActions = ACPResponseDispatcher.dispatchSuccess(
            result: .object([
                "sessionId": .string("sess-other"),
                "title": .string("中文会话"),
            ]),
            method: NonlocalMethods.renameSession,
            context: ACPResponseDispatchContext(pendingPlaceholderId: "ph-1")
        )
        XCTAssertTrue(renameActions.isEmpty, "nonlocal/rename_session must NOT emit .sessionActivated and switch active sessions")

        // Parse nonlocal/turn_completed notification
        let completedNotif = NonlocalSessionSyncParser.parseTurnCompleted(from: .object([
            "instanceId": .string("inst-uuid-001"),
            "sessionId": .string("sess-1"),
            "turnId": .string("turn-001"),
            "clientTurnId": .string("client-turn-001"),
            "status": .string("completed"),
            "stopReason": .string("end_turn")
        ]))
        XCTAssertEqual(completedNotif?.status, .completed)
        XCTAssertEqual(completedNotif?.stopReason, "end_turn")

        // Parse nonlocal/session_stale notification and verify staleSessionIds / lastActivityAt decoding
        let staleNotif = NonlocalSessionSyncParser.parseSessionStale(from: .object([
            "instanceId": .string("inst-uuid-001"),
            "sessionId": .string("sess-bg"),
            "updatedAt": .string("2026-11-16T13:10:53Z"),
            "reason": .string("background_updated")
        ]))
        XCTAssertEqual(staleNotif?.sessionId, "sess-bg")
        XCTAssertEqual(staleNotif?.reason, "background_updated")

        let staleSync = NonlocalSessionSyncParser.parseSyncResult(from: .object([
            "instanceId": .string("inst-uuid-002"),
            "materializedSessionIds": .array([]),
            "staleSessionIds": .array([.string("sess-bg")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("sess-bg"),
                    "lastActivityAt": .string("2026-11-16T13:09:41.785Z")
                ])
            ])
        ]))
        XCTAssertEqual(staleSync?.staleSessionIds, ["sess-bg"])
        XCTAssertNotNil(staleSync?.sessions.first?.lastActivityDate)

        // Verify ACPClientManager.clearSessionMaterialized drops only the requested session
        let mgr = await MainActor.run {
            ACPClientManager(defaults: UserDefaults(suiteName: "NonlocalSyncClearTest.\(UUID().uuidString)")!, shouldStartNetworkMonitoring: false)
        }
        await MainActor.run {
            mgr.markSessionMaterialized("sess-a")
            mgr.markSessionMaterialized("sess-b")
            mgr.clearSessionMaterialized("sess-a")
            XCTAssertFalse(mgr.isSessionMaterialized("sess-a"))
            XCTAssertTrue(mgr.isSessionMaterialized("sess-b"))
        }

        // Verify -32601 throws ACPServiceError.rpc and does not disable spec capabilities
        let _ = Task {
            let errResp = ACPWireMessage.response(.init(id: .int(2), error: .methodNotFound("Method not found")))
            let data = try JSONEncoder().encode(errResp)
            provider.connection.enqueue(.text(String(decoding: data, as: UTF8.self)))
        }
        do {
            _ = try await service.syncNonlocalSessions()
            XCTFail("Expected -32601 RPC error")
        } catch let error as ACPServiceError {
            XCTAssertEqual(error.rpcCode, -32601)
        }
        // SC-AC-018: -32601 throws ACPServiceError.rpc and dispatchError emits only .rpcError
        let errorActions = ACPResponseDispatcher.dispatchError(
            code: -32601,
            message: "Method not found",
            method: NonlocalMethods.sessionSync
        )
        XCTAssertEqual(errorActions, [.rpcError(ACPRPCErrorInfo(method: NonlocalMethods.sessionSync, code: -32601, message: "Method not found"))])

        await service.disconnect()
    }

    func testFailedConnectionStateWakesPendingContinuationImmediately() async throws {
        // P0-AC-3: When underlying socket enters .failed, in-flight request continuations must resume immediately with .disconnected
        let failingConn = FailingReceiveWebSocketConnection()
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://127.0.0.1:19999")!, pingInterval: nil),
            socketProvider: SingleConnectionProvider(connection: failingConn)
        )
        let service = ACPService(client: client)
        try await service.connect()

        let requestTask = Task<Error?, Never> {
            do {
                _ = try await service.sendPrompt(
                    ACPSessionPromptPayload(sessionId: "sess-1", prompt: [.object(["type": .string("text"), "text": .string("hi")])])
                )
                return nil
            } catch {
                return error
            }
        }

        // Wait until request text was actually sent so continuation is registered
        for _ in 0..<50 where failingConn.sentTexts.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(failingConn.sentTexts.isEmpty)

        failingConn.failNow()

        let returnedError = await requestTask.value
        XCTAssertEqual(returnedError as? ACPServiceError, .disconnected)

        // Subsequent request while client is already in .failed must also reject immediately with .disconnected
        do {
            _ = try await service.syncNonlocalSessions()
            XCTFail("Expected .disconnected when client state is .failed")
        } catch let err as ACPServiceError {
            XCTAssertEqual(err, .disconnected)
        }
    }

    @MainActor
    func testClientManagerReconnectReplacingOldServiceWakesPendingContinuation() async throws {
        // P0-AC-3: Replacing manager.service during reconnect immediately wakes pending continuations on old service
        let suiteName = "nonlocal-sync-manager-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let conn1 = MockWebSocketConnection()
        let conn2 = MockWebSocketConnection()
        var queue = [conn1, conn2]

        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let conn = queue.removeFirst()
                let client = ACPClient(
                    configuration: config,
                    socketProvider: SingleConnectionProvider(connection: conn),
                    logger: NoOpLogger(),
                    encoder: encoder
                )
                return ACPService(client: client)
            }
        )

        let connected1 = await manager.connectAndWait(config: ACPConnectionConfig(endpoint: URL(string: "ws://127.0.0.1:19991")!))
        XCTAssertTrue(connected1)
        let oldService = try XCTUnwrap(manager.service)

        let oldPromptTask = Task<Error?, Never> {
            do {
                _ = try await oldService.sendPrompt(
                    ACPSessionPromptPayload(sessionId: "sess-1", prompt: [.object(["type": .string("text"), "text": .string("hi")])])
                )
                return nil
            } catch {
                return error
            }
        }

        for _ in 0..<50 where conn1.sentTexts.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(conn1.sentTexts.isEmpty)

        // Replace service via reconnect
        let connected2 = await manager.connectAndWait(config: ACPConnectionConfig(endpoint: URL(string: "ws://127.0.0.1:19992")!))
        XCTAssertTrue(connected2)
        XCTAssertTrue(manager.service !== oldService)

        let oldError = await oldPromptTask.value
        XCTAssertEqual(oldError as? ACPServiceError, .disconnected)

        manager.disconnect()
    }

    func testParseSyncResultDecodesAvailableCommandsAndLegacyAbsence() throws {
        let resultValue: ACP.Value = .object([
            "instanceId": .string("inst-cmd-001"),
            "materializedSessionIds": .array([.string("sess-cmds"), .string("sess-legacy")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("sess-cmds"),
                    "availableCommands": .array([
                        .object([
                            "name": .string("compact"),
                            "description": .string("Compact conversation context"),
                            "input": .object([
                                "hint": .string("focus topic")
                            ])
                        ]),
                        .object([
                            "name": .string("clear"),
                            "description": .string("Clear current thread")
                        ])
                    ])
                ]),
                .object([
                    "sessionId": .string("sess-legacy")
                ])
            ])
        ])

        let parsed = try XCTUnwrap(NonlocalSessionSyncParser.parseSyncResult(from: resultValue))
        XCTAssertEqual(parsed.sessions.count, 2)

        let withCommands = parsed.sessions[0]
        XCTAssertEqual(withCommands.sessionId, "sess-cmds")
        XCTAssertEqual(withCommands.availableCommands, [
            SessionCommand(
                id: "compact",
                name: "compact",
                description: "Compact conversation context",
                inputHint: "focus topic"
            ),
            SessionCommand(
                id: "clear",
                name: "clear",
                description: "Clear current thread",
                inputHint: nil
            )
        ])

        let legacySession = parsed.sessions[1]
        XCTAssertEqual(legacySession.sessionId, "sess-legacy")
        XCTAssertEqual(legacySession.availableCommands, [])
    }
}
