import XCTest
import SwiftUI
import ACP
import ACPClient
@testable import Agmente

@MainActor
final class MultiServerConnectionPoolTests: XCTestCase {

    private final class PoolScriptedWebSocket: WebSocketConnection, @unchecked Sendable {
        enum ConnectionError: Error { case closed }

        private let lock = NSLock()
        private var continuation: AsyncStream<Result<WebSocketEvent, Error>>.Continuation?
        private let stream: AsyncStream<Result<WebSocketEvent, Error>>
        private var recordedTexts: [String] = []
        private(set) var connectCount = 0
        private(set) var disconnectCount = 0
        private(set) var lastConnectHeaders: [String: String] = [:]

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

        func connect(headers: [String: String]) async throws {
            connectCount += 1
            lastConnectHeaders = headers
        }

        func send(text: String) async throws {
            lock.withLock {
                recordedTexts.append(text)
            }
        }

        func receive() async throws -> WebSocketEvent {
            for await item in stream {
                return try item.get()
            }
            throw ConnectionError.closed
        }

        func close() async {
            disconnectCount += 1
            continuation?.yield(.success(.closed(WebSocketCloseReason(code: 1000, reason: nil))))
            continuation?.finish()
        }

        func ping() async throws {}

        func enqueue(_ message: ACPWireMessage) throws {
            let data = try JSONEncoder().encode(message)
            let text = String(decoding: data, as: UTF8.self)
            continuation?.yield(.success(.text(text)))
        }

        func enqueueResponse(id: Any, result: ACP.Value) throws {
            let rpcId: ACP.ID
            if let n = id as? Int {
                rpcId = .int(n)
            } else if let s = id as? String {
                rpcId = .string(s)
            } else {
                rpcId = .int(0)
            }
            try enqueue(.response(.init(id: rpcId, result: result)))
        }

        func enqueueErrorResponse(id: Any, code: Int, message: String) throws {
            let rpcId: ACP.ID
            if let n = id as? Int {
                rpcId = .int(n)
            } else if let s = id as? String {
                rpcId = .string(s)
            } else {
                rpcId = .int(0)
            }
            try enqueue(ACPMessageBuilder.errorResponse(requestId: rpcId, code: code, message: message))
        }

        func simulateDrop(_ error: Error = NSError(domain: "PoolTest", code: 1006)) {
            continuation?.yield(.failure(error))
            continuation?.finish()
        }

        func simulateClose(code: Int, reason: String? = nil) {
            continuation?.yield(.success(.closed(WebSocketCloseReason(code: code, reason: reason))))
            continuation?.finish()
        }
    }

    private final class SuspendedHandshakeWebSocket: WebSocketConnection, @unchecked Sendable {
        enum ConnectionError: Error { case closed }

        private let lock = NSLock()
        private var connectContinuation: CheckedContinuation<Void, Error>?
        private var handshakeAlreadyReleased = false
        private var streamContinuation: AsyncStream<Result<WebSocketEvent, Error>>.Continuation?
        private let stream: AsyncStream<Result<WebSocketEvent, Error>>
        private var recordedTexts: [String] = []
        private var _connectCount = 0
        private var _closeCount = 0

        var connectCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _connectCount
        }

        var closeCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return _closeCount
        }

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
            self.streamContinuation = contRef
        }

        func connect(headers: [String: String]) async throws {
            let alreadyReleased = lock.withLock { () -> Bool in
                _connectCount += 1
                return handshakeAlreadyReleased
            }
            if alreadyReleased { return }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                let shouldResumeNow = lock.withLock { () -> Bool in
                    if handshakeAlreadyReleased {
                        return true
                    }
                    connectContinuation = cont
                    return false
                }
                if shouldResumeNow {
                    cont.resume()
                }
            }
        }

        func releaseHandshake() {
            let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                handshakeAlreadyReleased = true
                let c = connectContinuation
                connectContinuation = nil
                return c
            }
            cont?.resume()
        }

        func send(text: String) async throws {
            lock.withLock {
                recordedTexts.append(text)
            }
        }

        func receive() async throws -> WebSocketEvent {
            for await item in stream {
                return try item.get()
            }
            throw ConnectionError.closed
        }

        func close() async {
            let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                _closeCount += 1
                let c = connectContinuation
                connectContinuation = nil
                return c
            }
            cont?.resume(throwing: CancellationError())
            streamContinuation?.yield(.success(.closed(WebSocketCloseReason(code: 1000, reason: nil))))
            streamContinuation?.finish()
        }

        func ping() async throws {}

        func simulateClose(code: Int, reason: String? = nil) {
            streamContinuation?.yield(.success(.closed(WebSocketCloseReason(code: code, reason: reason))))
            streamContinuation?.finish()
        }

        func enqueueResponse(id: Any, result: ACP.Value) throws {
            let rpcId: ACP.ID
            if let n = id as? Int {
                rpcId = .int(n)
            } else if let s = id as? String {
                rpcId = .string(s)
            } else {
                rpcId = .int(0)
            }
            let data = try JSONEncoder().encode(ACPWireMessage.response(.init(id: rpcId, result: result)))
            let text = String(decoding: data, as: UTF8.self)
            streamContinuation?.yield(.success(.text(text)))
        }
    }

    private final class PoolSocketProvider: WebSocketProviding, @unchecked Sendable {
        private var queue: [PoolScriptedWebSocket]
        init(connections: [PoolScriptedWebSocket]) {
            self.queue = connections
        }
        func makeConnection(url: URL) -> WebSocketConnection {
            if queue.isEmpty {
                return PoolScriptedWebSocket()
            }
            return queue.removeFirst()
        }
    }

    private final class NoOpLogger: ACPLogger {
        func info(_ message: String) {}
        func error(_ message: String) {}
    }

    private func waitUntil(
        timeout: TimeInterval = 4.0,
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Timed out waiting for condition after \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
    }

    private func respondInitAndSync(on conn: PoolScriptedWebSocket, instanceId: String, sessions: [String]) async throws {
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == "initialize" } }
        let initReq = try XCTUnwrap(conn.sentJSONObjects.first { ($0["method"] as? String) == "initialize" })
        try conn.enqueueResponse(id: initReq["id"]!, result: .object([
            "protocolVersion": .int(1),
            "agentCapabilities": .object(["loadSession": .bool(true), "listSessions": .bool(true)]),
            "agentInfo": .object(["name": .string("agy"), "version": .string("1.0")])
        ]))
        try await waitUntil { conn.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        let syncReq = try XCTUnwrap(conn.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync })
        try conn.enqueueResponse(id: syncReq["id"]!, result: .object([
            "instanceId": .string(instanceId),
            "materializedSessionIds": .array(sessions.map { .string($0) }),
            "sessions": .array(sessions.map { .object(["sessionId": .string($0)]) })
        ]))
    }

    // MARK: - W2-AC-201: Dual-slot concurrent id=1 isolation, per-slot lastConnectedAt, single-server disconnect isolation

    func testW2AC201_DualSlotConcurrentIsolationAndIndependentDisconnect() async throws {
        let suite = "W2AC201.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let serverA = ACPServerConfiguration(
            id: UUID(), name: "ServerA", scheme: "ws", host: "127.0.0.1:19201",
            token: "tA", workingDirectory: "/a"
        )
        let serverB = ACPServerConfiguration(
            id: UUID(), name: "ServerB", scheme: "ws", host: "127.0.0.1:19202",
            token: "tB", workingDirectory: "/b"
        )
        storage.saveServer(serverA)
        storage.saveServer(serverB)

        let connA = PoolScriptedWebSocket()
        let connB = PoolScriptedWebSocket()
        let providerA = PoolSocketProvider(connections: [connA])
        let providerB = PoolSocketProvider(connections: [connB])

        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { serverId in
                let provider = (serverId == serverA.id) ? providerA : providerB
                return ACPClientManager(
                    defaults: defaults,
                    shouldStartNetworkMonitoring: false,
                    serviceFactory: { config, encoder in
                        let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                        return ACPService(client: client)
                    }
                )
            },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )

        appVM.connectAllServers()
        try await respondInitAndSync(on: connA, instanceId: "inst-A", sessions: ["SA1"])
        try await respondInitAndSync(on: connB, instanceId: "inst-B", sessions: ["SB1"])

        try await waitUntil {
            appVM.connectionState(for: serverA.id) == .connected
                && appVM.connectionState(for: serverB.id) == .connected
        }

        // Both slots have independent managers & both sent initialize with id=1 without colliding
        let slotA = appVM.connectionSlot(for: serverA.id)
        let slotB = appVM.connectionSlot(for: serverB.id)
        XCTAssertTrue(slotA.connectionManager !== slotB.connectionManager)
        XCTAssertNotNil(appVM.lastConnectedAt(for: serverA.id))
        XCTAssertNotNil(appVM.lastConnectedAt(for: serverB.id))

        // Interleaved session/update notifications stay strictly isolated per slot
        try connB.enqueue(.notification(.init(
            method: "session/update",
            params: .object([
                "sessionId": .string("SB1"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("Hello from B")])
                ])
            ])
        )))
        try connA.enqueue(.notification(.init(
            method: "session/update",
            params: .object([
                "sessionId": .string("SA1"),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("Hello from A")])
                ])
            ])
        )))

        let vmA = try XCTUnwrap(appVM.serverViewModels[serverA.id])
        let vmB = try XCTUnwrap(appVM.serverViewModels[serverB.id])
        try await waitUntil {
            vmA.existingSessionViewModel(for: "SA1")?.chatMessages.contains { $0.content.contains("Hello from A") } == true
                && vmB.existingSessionViewModel(for: "SB1")?.chatMessages.contains { $0.content.contains("Hello from B") } == true
        }
        XCTAssertNil(vmA.existingSessionViewModel(for: "SB1"), "Slot B session must not leak into Server A")
        XCTAssertNil(vmB.existingSessionViewModel(for: "SA1"), "Slot A session must not leak into Server B")

        // Disconnecting A leaves B connected and operational
        connA.simulateDrop()
        try await waitUntil { appVM.connectionState(for: serverA.id) != .connected }
        XCTAssertEqual(appVM.connectionState(for: serverB.id), .connected, "Server B must stay connected while A drops")
    }

    // MARK: - W2-AC-202: 3-state ScenePhase (.inactive/.background/.active), manual disconnect preservation, deleteServer slot release

    func testW2AC202_ScenePhaseLifecycleManualDisconnectAndSlotRelease() async throws {
        let suite = "W2AC202.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let serverA = ACPServerConfiguration(
            id: UUID(), name: "ServerA", scheme: "ws", host: "127.0.0.1:19211",
            token: "", workingDirectory: "/a"
        )
        let serverB = ACPServerConfiguration(
            id: UUID(), name: "ServerB", scheme: "ws", host: "127.0.0.1:19212",
            token: "", workingDirectory: "/b"
        )
        storage.saveServer(serverA)
        storage.saveServer(serverB)

        let connA1 = PoolScriptedWebSocket()
        let connA2 = PoolScriptedWebSocket()
        let connB1 = PoolScriptedWebSocket()
        let connB2 = PoolScriptedWebSocket()
        let providerA = PoolSocketProvider(connections: [connA1, connA2])
        let providerB = PoolSocketProvider(connections: [connB1, connB2])

        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { serverId in
                let provider = (serverId == serverA.id) ? providerA : providerB
                return ACPClientManager(
                    defaults: defaults,
                    shouldStartNetworkMonitoring: false,
                    serviceFactory: { config, encoder in
                        let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                        return ACPService(client: client)
                    }
                )
            },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )

        appVM.connectAllServers()
        try await respondInitAndSync(on: connA1, instanceId: "inst-A1", sessions: [])
        try await respondInitAndSync(on: connB1, instanceId: "inst-B1", sessions: [])
        try await waitUntil {
            appVM.connectionState(for: serverA.id) == .connected
                && appVM.connectionState(for: serverB.id) == .connected
        }

        // Manually disconnect B
        appVM.disconnect(serverId: serverB.id)
        try await waitUntil { appVM.connectionState(for: serverB.id) == .disconnected }
        XCTAssertTrue(appVM.isManuallyDisconnected(serverId: serverB.id))

        // .inactive must NOT disconnect A
        appVM.handleScenePhaseChanged(.inactive)
        XCTAssertEqual(appVM.connectionState(for: serverA.id), .connected, ".inactive must keep socket alive")

        // .background suspends A without marking isManuallyDisconnected
        appVM.handleScenePhaseChanged(.background)
        try await waitUntil { appVM.connectionState(for: serverA.id) == .disconnected }
        XCTAssertFalse(appVM.isManuallyDisconnected(serverId: serverA.id), "Background suspend must NOT mark manual disconnect")

        // .active reconnects A only; B stays disconnected because it was manually disconnected
        appVM.handleScenePhaseChanged(.active)
        try await respondInitAndSync(on: connA2, instanceId: "inst-A2", sessions: [])
        try await waitUntil { appVM.connectionState(for: serverA.id) == .connected }
        XCTAssertEqual(connB2.connectCount, 0, "Manually disconnected Server B must NOT auto-reconnect on .active")
        XCTAssertEqual(appVM.connectionState(for: serverB.id), .disconnected)

        // Deleting server A releases its connection slot completely
        appVM.deleteServer(serverA.id)
        XCTAssertNil(appVM.connectionSlots[serverA.id], "Deleting server A must release connectionSlots[A]")
    }

    // MARK: - W2-AC-203: Cross-server zero cross-talk in all-sessions mode (explicit serverId routing, selectedServerId preserved)

    func testW2AC203_AllSessionsCrossServerRoutingZeroCrossTalk() async throws {
        let suite = "W2AC203.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let serverA = ACPServerConfiguration(
            id: UUID(), name: "ServerA", scheme: "ws", host: "127.0.0.1:19221",
            token: "", workingDirectory: "/a"
        )
        let serverB = ACPServerConfiguration(
            id: UUID(), name: "ServerB", scheme: "ws", host: "127.0.0.1:19222",
            token: "", workingDirectory: "/b"
        )
        storage.saveServer(serverA)
        storage.saveServer(serverB)
        storage.saveSession(StoredSessionInfo(sessionId: "SB1", title: "B Session", cwd: "/b", updatedAt: Date()), forServerId: serverB.id)

        let connA = PoolScriptedWebSocket()
        let connB = PoolScriptedWebSocket()
        let providerA = PoolSocketProvider(connections: [connA])
        let providerB = PoolSocketProvider(connections: [connB])

        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { serverId in
                let provider = (serverId == serverA.id) ? providerA : providerB
                return ACPClientManager(
                    defaults: defaults,
                    shouldStartNetworkMonitoring: false,
                    serviceFactory: { config, encoder in
                        let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                        return ACPService(client: client)
                    }
                )
            },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )

        appVM.selectServer(serverA.id)
        appVM.setHomeDisplayMode(.allSessions)
        appVM.connectAllServers()
        try await respondInitAndSync(on: connA, instanceId: "inst-A", sessions: ["SA1"])
        try await respondInitAndSync(on: connB, instanceId: "inst-B", sessions: ["SB1"])
        try await waitUntil {
            appVM.connectionState(for: serverA.id) == .connected
                && appVM.connectionState(for: serverB.id) == .connected
        }

        let baselineACount = connA.sentJSONObjects.count

        // Open B's session SB1 while selectedServerId == A
        appVM.openSession(serverId: serverB.id, sessionId: "SB1")
        XCTAssertEqual(appVM.selectedServerId, serverA.id, "Opening (B, SB1) must NOT mutate selectedServerId")
        XCTAssertEqual(appVM.connectionState(for: serverA.id), .connected, "Server A must stay connected")
        XCTAssertEqual(appVM.activeViewingServerId, serverB.id)
        XCTAssertEqual(appVM.activeViewingSessionId, "SB1")

        // Rename SB1 on B -> hits B only (0 calls on A)
        let renameTask = Task {
            try await appVM.renameSession(serverId: serverB.id, sessionId: "SB1", title: "Renamed B")
        }
        try await waitUntil { connB.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.renameSession } }
        let renameReq = try XCTUnwrap(connB.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.renameSession })
        try connB.enqueueResponse(id: renameReq["id"]!, result: .object(["title": .string("Renamed B")]))
        _ = try await renameTask.value

        // Session info on B -> hits B only
        let infoTask = Task {
            try await appVM.fetchSessionInfo(serverId: serverB.id, sessionId: "SB1")
        }
        try await waitUntil { connB.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionInfo } }
        let infoReq = try XCTUnwrap(connB.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionInfo })
        try connB.enqueueResponse(id: infoReq["id"]!, result: .object([
            "sessionId": .string("SB1"),
            "subagentCount": .int(0)
        ]))
        _ = try await infoTask.value

        // Delete SB1 on B -> hits B only
        let delTask = Task {
            try await appVM.deleteRemoteSession(sessionId: "SB1", serverId: serverB.id)
        }
        try await waitUntil { connB.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.deleteSession } }
        let delReq = try XCTUnwrap(connB.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.deleteSession })
        try connB.enqueueResponse(id: delReq["id"]!, result: .object([
            "sessionId": .string("SB1"),
            "deleted": .bool(true),
            "alreadyAbsent": .bool(false),
            "deletedSubagentCount": .int(0)
        ]))
        let delRes = try await delTask.value.get()
        XCTAssertTrue(delRes.deleted)

        // Zero calls sent to Server A during all B-scoped operations!
        XCTAssertEqual(connA.sentJSONObjects.count, baselineACount, "Server A must receive 0 calls for B-scoped operations")
        XCTAssertEqual(appVM.selectedServerId, serverA.id)
    }

    // MARK: - Dual-Server Helper for BG-AC-1..BG-AC-7

    private struct DualServerHarness {
        let suite: String
        let defaults: UserDefaults
        let storage: SessionStorage
        let serverA: ACPServerConfiguration
        let serverB: ACPServerConfiguration
        let connA: PoolScriptedWebSocket
        let connB: PoolScriptedWebSocket
        let appVM: AppViewModel
        let serverVMA: ServerViewModel
        let serverVMB: ServerViewModel
    }

    private func makeDualServerHarness(
        autoInitSync: Bool = true,
        resumeSupported: Bool = true
    ) async throws -> DualServerHarness {
        let suite = "BGSlot.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let storage = SessionStorage.inMemory()
        let serverA = ACPServerConfiguration(
            id: UUID(), name: "ServerA", scheme: "ws", host: "127.0.0.1:19401",
            token: "tA", workingDirectory: "/a"
        )
        let serverB = ACPServerConfiguration(
            id: UUID(), name: "ServerB", scheme: "ws", host: "127.0.0.1:19402",
            token: "tB", workingDirectory: "/b"
        )
        storage.saveServer(serverA)
        storage.saveServer(serverB)

        let connA = PoolScriptedWebSocket()
        let connB = PoolScriptedWebSocket()
        let providerA = PoolSocketProvider(connections: [connA])
        let providerB = PoolSocketProvider(connections: [connB])

        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { serverId in
                let provider = (serverId == serverA.id) ? providerA : providerB
                return ACPClientManager(
                    defaults: defaults,
                    shouldStartNetworkMonitoring: false,
                    serviceFactory: { config, encoder in
                        let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                        return ACPService(client: client)
                    }
                )
            },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )

        appVM.selectServer(serverA.id)
        appVM.setHomeDisplayMode(.allSessions)
        appVM.connectAllServers()

        if autoInitSync {
            try await respondInitAndSync(on: connA, instanceId: "inst-A", sessions: ["SA1"])
            try await waitUntil { connB.sentJSONObjects.contains { ($0["method"] as? String) == "initialize" } }
            let initReqB = try XCTUnwrap(connB.sentJSONObjects.first { ($0["method"] as? String) == "initialize" })
            try connB.enqueueResponse(id: initReqB["id"]!, result: .object([
                "protocolVersion": .int(1),
                "agentCapabilities": .object([
                    "loadSession": .bool(true),
                    "listSessions": .bool(true),
                    "sessionCapabilities": .object(["resume": .object([:])])
                ]),
                "agentInfo": .object(["name": .string("agy"), "version": .string("1.0")])
            ]))
            try await waitUntil { connB.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
            let syncReqB = try XCTUnwrap(connB.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync })
            try connB.enqueueResponse(id: syncReqB["id"]!, result: .object([
                "instanceId": .string("inst-B"),
                "materializedSessionIds": .array([.string("SB1")]),
                "sessions": .array([.object(["sessionId": .string("SB1")])])
            ]))
            try await waitUntil {
                appVM.connectionState(for: serverA.id) == .connected
                    && appVM.connectionState(for: serverB.id) == .connected
                    && appVM.slotConnectionManager(for: serverA.id).isInitialized
                    && appVM.slotConnectionManager(for: serverB.id).isInitialized
                    && !appVM.hasInitialSyncPending(for: serverA.id)
                    && !appVM.hasInitialSyncPending(for: serverB.id)
            }
        }
        _ = resumeSupported

        let serverVMA = try XCTUnwrap(appVM.serverViewModels[serverA.id])
        let serverVMB = try XCTUnwrap(appVM.serverViewModels[serverB.id])
        return DualServerHarness(
            suite: suite, defaults: defaults, storage: storage,
            serverA: serverA, serverB: serverB, connA: connA, connB: connB,
            appVM: appVM, serverVMA: serverVMA, serverVMB: serverVMB
        )
    }

    // MARK: - BG-AC-1: Background slot nonlocal/turn_completed (completed & error) clears spinner & orange dot

    func testBGAC1_BackgroundTurnCompletedClearsSpinnerAndOrangeDot() async throws {
        let h = try await makeDualServerHarness()
        defer { UserDefaults.standard.removePersistentDomain(forName: h.suite) }

        let vmA = h.serverVMA.sessionViewModel(for: "SA1")
        vmA.startNewStreamingResponse()
        let vmB = h.serverVMB.sessionViewModel(for: "SB1")
        vmB.setSessionContext(serverId: h.serverB.id, sessionId: "SB1")
        vmB.startNewStreamingResponse()
        try h.connB.enqueue(.notification(.init(
            method: "session/update",
            params: .object([
                "sessionId": .string("SB1"),
                "update": .object([
                    "sessionUpdate": .string("agent_thought_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("Thinking...")])
                ])
            ])
        )))
        try await waitUntil { vmB.liveActivityStatus != nil }
        XCTAssertTrue(vmB.isStreaming)
        XCTAssertTrue(h.serverVMB.isSessionRunning("SB1"))
        XCTAssertEqual(h.serverVMB.sessionRowStatus(for: "SB1"), .running)

        // 1. completed notification on background slot B (selectedServerId == A)
        try h.connB.enqueue(.notification(.init(
            method: NonlocalMethods.turnCompleted,
            params: .object([
                "instanceId": .string("inst-B"),
                "sessionId": .string("SB1"),
                "turnId": .string("turn-bg-1"),
                "status": .string("completed"),
                "stopReason": .string("end_turn")
            ])
        )))

        try await waitUntil { !vmB.isStreaming && !h.serverVMB.isSessionRunning("SB1") }
        XCTAssertFalse(vmB.isStreaming)
        XCTAssertNil(vmB.liveActivityStatus)
        XCTAssertFalse(h.serverVMB.isSessionRunning("SB1"))
        XCTAssertNotEqual(h.serverVMB.sessionRowStatus(for: "SB1"), .running)
        XCTAssertEqual(h.appVM.selectedServerId, h.serverA.id)
        XCTAssertTrue(vmA.isStreaming, "Server A's active turn must remain untouched")

        // 2. error notification on background slot B
        vmB.startNewStreamingResponse()
        XCTAssertTrue(h.serverVMB.isSessionRunning("SB1"))

        try h.connB.enqueue(.notification(.init(
            method: NonlocalMethods.turnCompleted,
            params: .object([
                "instanceId": .string("inst-B"),
                "sessionId": .string("SB1"),
                "turnId": .string("turn-bg-2"),
                "status": .string("error"),
                "error": .object(["code": .int(-32000), "message": .string("Bridge turn failed")])
            ])
        )))

        try await waitUntil { !vmB.isStreaming && !h.serverVMB.isSessionRunning("SB1") }
        XCTAssertFalse(vmB.isStreaming)
        XCTAssertNil(vmB.liveActivityStatus)
        XCTAssertFalse(h.serverVMB.isSessionRunning("SB1"))
        XCTAssertNotEqual(h.serverVMB.sessionRowStatus(for: "SB1"), .running)
        XCTAssertEqual(vmB.chatMessages.filter(\.isError).count, 1)
        XCTAssertEqual(h.appVM.selectedServerId, h.serverA.id)
        XCTAssertTrue(vmA.isStreaming)
    }

    // MARK: - BG-AC-2: Background session/prompt completion & mid-flight server switch race

    func testBGAC2_BackgroundPromptCompletionAndSwitchRace() async throws {
        let h = try await makeDualServerHarness()
        defer { UserDefaults.standard.removePersistentDomain(forName: h.suite) }

        let vmA = h.serverVMA.sessionViewModel(for: "SA1")
        vmA.startNewStreamingResponse()

        // Case 1: selectedServerId stays A while B sends & completes session/prompt
        h.appVM.slotConnectionManager(for: h.serverB.id).markSessionMaterialized("SB1")
        h.serverVMB.setActiveSession("SB1", cwd: "/b", modes: nil)
        let vmB = h.serverVMB.sessionViewModel(for: "SB1")
        let accepted1 = h.serverVMB.submitPrompt(promptText: "Ping B 1", images: [], commandName: nil)
        XCTAssertTrue(accepted1)

        try await waitUntil { h.connB.sentJSONObjects.contains { ($0["method"] as? String) == "session/prompt" } }
        let promptReq1 = try XCTUnwrap(h.connB.sentJSONObjects.last { ($0["method"] as? String) == "session/prompt" })
        XCTAssertTrue(vmB.isStreaming)
        XCTAssertTrue(h.serverVMB.isSessionRunning("SB1"))

        try h.connB.enqueueResponse(id: promptReq1["id"]!, result: .object(["stopReason": .string("end_turn")]))
        try await waitUntil { !vmB.isStreaming && !h.serverVMB.isSessionRunning("SB1") }
        XCTAssertNil(vmB.liveActivityStatus)
        XCTAssertNotEqual(h.serverVMB.sessionRowStatus(for: "SB1"), .running)
        XCTAssertEqual(h.appVM.selectedServerId, h.serverA.id)
        XCTAssertTrue(vmA.isStreaming)

        // Case 2: Switch race — send on B while selectedServerId == A, then switch selectedServerId to B & another session SB2 before response arrives
        let accepted2 = h.serverVMB.submitPrompt(promptText: "Ping B 2", images: [], commandName: nil)
        XCTAssertTrue(accepted2)
        try await waitUntil { h.connB.sentJSONObjects.filter { ($0["method"] as? String) == "session/prompt" }.count == 2 }
        let promptReq2 = try XCTUnwrap(h.connB.sentJSONObjects.last { ($0["method"] as? String) == "session/prompt" })

        let vmB2 = h.serverVMB.sessionViewModel(for: "SB2")
        vmB2.startNewStreamingResponse()
        h.appVM.selectServer(h.serverB.id)
        h.serverVMB.setActiveSession("SB2", cwd: "/b", modes: nil)

        try h.connB.enqueueResponse(id: promptReq2["id"]!, result: .object(["stopReason": .string("end_turn")]))
        try await waitUntil { !vmB.isStreaming && !h.serverVMB.isSessionRunning("SB1") }
        XCTAssertTrue(vmB2.isStreaming, "Completion of SB1 must NOT terminate SB2")
        XCTAssertTrue(vmA.isStreaming, "Completion of SB1 must NOT terminate Server A")
    }

    // MARK: - BG-AC-3: Real submitPrompt RPC error on background slot produces exactly 1 error bubble & clean restore

    func testBGAC3_BackgroundSubmitPromptRpcErrorSingleBubbleAndRestore() async throws {
        let h = try await makeDualServerHarness()
        defer { UserDefaults.standard.removePersistentDomain(forName: h.suite) }

        let vmA = h.serverVMA.sessionViewModel(for: "SA1")
        let baselineACount = vmA.chatMessages.count

        h.appVM.slotConnectionManager(for: h.serverB.id).markSessionMaterialized("SB1")
        h.serverVMB.setActiveSession("SB1", cwd: "/b", modes: nil)
        let vmB = h.serverVMB.sessionViewModel(for: "SB1")
        let accepted = h.serverVMB.submitPrompt(promptText: "Will fail on B", images: [], commandName: nil)
        XCTAssertTrue(accepted)

        try await waitUntil { h.connB.sentJSONObjects.contains { ($0["method"] as? String) == "session/prompt" } }
        let promptReq = try XCTUnwrap(h.connB.sentJSONObjects.last { ($0["method"] as? String) == "session/prompt" })

        try h.connB.enqueueErrorResponse(id: promptReq["id"]!, code: -32000, message: "Upstream model overloaded")

        try await waitUntil { !vmB.isStreaming && vmB.chatMessages.contains(where: \.isError) }
        // Give any stray duplicate Task a chance to run so we prove single-writer semantics
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(vmB.isStreaming)
        XCTAssertNil(vmB.liveActivityStatus)
        XCTAssertFalse(h.serverVMB.isSessionRunning("SB1"))
        XCTAssertNotEqual(h.serverVMB.sessionRowStatus(for: "SB1"), .running)
        XCTAssertEqual(vmB.chatMessages.filter(\.isError).count, 1, "BG-AC-3: Must produce exactly 1 error bubble (no double-write)")
        XCTAssertEqual(vmA.chatMessages.count, baselineACount, "Server A messages must remain untouched")

        let failedMsgId = try XCTUnwrap(vmB.failedDeliveryMessageIds.first)
        vmB.restoreFailedDelivery(for: failedMsgId)
        XCTAssertEqual(vmB.chatMessages.filter(\.isError).count, 0, "BG-AC-3: restoreFailedDelivery must leave 0 orphan error bubbles")
        XCTAssertTrue(vmB.promptText.contains("Will fail on B"))
    }

    // MARK: - BG-AC-4: Background session/load marks materialized & finishes replay

    func testBGAC4_BackgroundSessionLoadSemantics() async throws {
        let h = try await makeDualServerHarness()
        defer { UserDefaults.standard.removePersistentDomain(forName: h.suite) }

        // session/load on background server B
        let vmBLoad = h.serverVMB.sessionViewModel(for: "SB_LOAD")
        vmBLoad.beginHistoryReplay()
        vmBLoad.startNewStreamingResponse()
        let loadTask = Task {
            try await h.appVM.service(for: h.serverB.id)?.loadSession(ACPSessionLoadPayload(sessionId: "SB_LOAD", workingDirectory: "/b"))
        }
        try await waitUntil { h.connB.sentJSONObjects.contains { ($0["method"] as? String) == "session/load" } }
        let loadReq = try XCTUnwrap(h.connB.sentJSONObjects.last { ($0["method"] as? String) == "session/load" })
        try h.connB.enqueueResponse(id: loadReq["id"]!, result: .object([:]))
        _ = try await loadTask.value

        try await waitUntil { !vmBLoad.isStreaming && h.appVM.slotConnectionManager(for: h.serverB.id).isSessionMaterialized("SB_LOAD") }
        XCTAssertFalse(vmBLoad.isStreaming)
        XCTAssertFalse(h.serverVMB.isSessionRunning("SB_LOAD"))
        XCTAssertTrue(h.appVM.slotConnectionManager(for: h.serverB.id).isSessionMaterialized("SB_LOAD"))
        XCTAssertFalse(h.appVM.slotConnectionManager(for: h.serverA.id).isSessionMaterialized("SB_LOAD"))
    }

    // MARK: - BG-AC-5: finishStreamingMessage & abandonStreamingMessage clear all residual isStreaming flags; user chunk split preserved

    func testBGAC5_FinishAndAbandonClearAllStreamingFlagsWithoutBreakingUserChunkSplit() async throws {
        let vm = ACPSessionViewModel(
            dependencies: .init(
                getService: { nil },
                append: { _ in },
                logWire: { _, _ in }
            )
        )

        // 1. Public finishStreamingMessage() clears multiple residual isStreaming flags even if streamingMessageId mismatched
        let m1 = ChatMessage(role: .assistant, content: "Stale 1", isStreaming: true)
        let m2 = ChatMessage(role: .assistant, content: "Stale 2", isStreaming: true)
        vm.setChatMessages([m1, m2])
        vm.finishStreamingMessage()
        XCTAssertTrue(vm.chatMessages.allSatisfy { !$0.isStreaming })
        XCTAssertFalse(vm.isStreaming)

        // 2. Public abandonStreamingMessage() also clears all residual isStreaming flags
        let m3 = ChatMessage(role: .assistant, content: "Stale 3", isStreaming: true)
        let m4 = ChatMessage(role: .assistant, content: "Stale 4", isStreaming: true)
        vm.setChatMessages([m3, m4])
        vm.abandonStreamingMessage()
        XCTAssertTrue(vm.chatMessages.allSatisfy { !$0.isStreaming })
        XCTAssertFalse(vm.isStreaming)

        // 3. Mid-turn user_message_chunk split only closes current streaming bubble and does not wipe unrelated streaming flag
        let m5 = ChatMessage(role: .assistant, content: "Earlier", isStreaming: true)
        let m6 = ChatMessage(role: .assistant, content: "Current", isStreaming: true)
        vm.setChatMessages([m5, m6])
        vm.handleSessionUpdateEvents(
            ACP.Value.object([
                "sessionId": ACP.Value.string("S1"),
                "update": ACP.Value.object([
                    "sessionUpdate": ACP.Value.string("user_message_chunk"),
                    "content": ACP.Value.object(["type": ACP.Value.string("text"), "text": ACP.Value.string("Mid-turn user")])
                ])
            ]),
            activeSessionId: "S1",
            serverId: UUID()
        )
        XCTAssertTrue(vm.chatMessages.first(where: { $0.id == m5.id })?.isStreaming == true, "BG-AC-5: appendUserChunk must NOT wipe unrelated streaming flag")
        XCTAssertTrue(vm.chatMessages.first(where: { $0.id == m6.id })?.isStreaming == false)
    }

    // MARK: - BG-AC-6: Background initialize updates agentInfo, sync barrier isolated per server, update buffered/deduped, sync not treated as session/list

    func testBGAC6_BackgroundInitializeSyncBarrierDedupAndNoSyncAsListOverwrite() async throws {
        let h = try await makeDualServerHarness(autoInitSync: false)
        defer { UserDefaults.standard.removePersistentDomain(forName: h.suite) }

        // Seed B with an existing cached session that must NOT be overwritten/pruned by nonlocal/sync
        h.storage.saveSession(StoredSessionInfo(sessionId: "SB_EXISTING", title: "Keep My Title", cwd: "/b", updatedAt: Date()), forServerId: h.serverB.id)
        h.serverVMB.loadCachedSessions()

        // Complete A's initialize + sync first so A is idle while B is still syncing
        try await respondInitAndSync(on: h.connA, instanceId: "inst-A", sessions: ["SA1"])
        try await waitUntil { !h.appVM.hasInitialSyncPending(for: h.serverA.id) }

        // Respond B's initialize (background slot) -> verify agentInfoCache[B] & serverVMB.agentInfo populated
        try await waitUntil { h.connB.sentJSONObjects.contains { ($0["method"] as? String) == "initialize" } }
        let initReqB = try XCTUnwrap(h.connB.sentJSONObjects.first { ($0["method"] as? String) == "initialize" })
        try h.connB.enqueueResponse(id: initReqB["id"]!, result: .object([
            "protocolVersion": .int(1),
            "agentCapabilities": .object(["loadSession": .bool(true), "listSessions": .bool(true)]),
            "agentInfo": .object(["name": .string("agy-bg"), "version": .string("2.0")])
        ]))

        // Wait until B starts nonlocal/sync (isSyncingByServer[B] == true) while A is idle
        try await waitUntil { h.connB.sentJSONObjects.contains { ($0["method"] as? String) == NonlocalMethods.sessionSync } }
        XCTAssertEqual(h.serverVMB.agentInfo?.name, "agy-bg", "BG-AC-6: Background initialize must populate serverVMB.agentInfo")
        XCTAssertFalse(h.appVM.hasInitialSyncPending(for: h.serverA.id))
        XCTAssertTrue(h.appVM.hasInitialSyncPending(for: h.serverB.id), "BG-AC-6: B's sync barrier must be isolated from idle A")

        // While B is syncing, enqueue a live session/update with nonlocalSeq=2 (duplicate of snapshot) and seq=3 (new)
        try h.connB.enqueue(.notification(.init(
            method: "session/update",
            params: .object([
                "sessionId": .string("SB1"),
                "_meta": .object(["nonlocalTurnId": .string("t-sync-1"), "nonlocalSeq": .int(2)]),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("Part1 ")])
                ])
            ])
        )))
        try h.connB.enqueue(.notification(.init(
            method: "session/update",
            params: .object([
                "sessionId": .string("SB1"),
                "_meta": .object(["nonlocalTurnId": .string("t-sync-1"), "nonlocalSeq": .int(3)]),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("Part2")])
                ])
            ])
        )))
        try await Task.sleep(nanoseconds: 60_000_000)

        // Complete B's nonlocal/sync with snapshot containing seq 1..2 (and sessions: [SB1])
        let syncReqB = try XCTUnwrap(h.connB.sentJSONObjects.first { ($0["method"] as? String) == NonlocalMethods.sessionSync })
        try h.connB.enqueueResponse(id: syncReqB["id"]!, result: .object([
            "instanceId": .string("inst-B"),
            "materializedSessionIds": .array([.string("SB1")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("SB1"),
                    "latestTurn": .object([
                        "turnId": .string("t-sync-1"),
                        "status": .string("active"),
                        "seq": .int(2),
                        "assistantText": .string("Part1 ")
                    ])
                ])
            ])
        ]))

        try await waitUntil { !h.appVM.hasInitialSyncPending(for: h.serverB.id) }
        let vmB = h.serverVMB.sessionViewModel(for: "SB1")
        try await waitUntil { vmB.chatMessages.contains { $0.content.contains("Part2") } }
        let assistantContent = vmB.chatMessages.filter { $0.role == .assistant }.map(\.content).joined()
        XCTAssertEqual(assistantContent, "Part1 Part2", "BG-AC-6: Buffered update seq=2 must be deduped while seq=3 appends once")
        XCTAssertTrue(
            h.serverVMB.sessionSummaries.contains { $0.id == "SB_EXISTING" && $0.title == "Keep My Title" },
            "BG-AC-6: nonlocal/sync response must NEVER be misparsed as session/list to overwrite/prune existing sessions"
        )
    }

    // MARK: - BG-AC-7: Background slot server requests (permission & fs/*) + sendPermissionResponse & sendCancel isolation

    func testBGAC7_BackgroundServerRequestPermissionFsErrorAndCancelIsolation() async throws {
        let h = try await makeDualServerHarness()
        defer { UserDefaults.standard.removePersistentDomain(forName: h.suite) }

        let baselineACount = h.connA.sentJSONObjects.count
        let vmB = h.serverVMB.sessionViewModel(for: "SB1")
        vmB.setSessionContext(serverId: h.serverB.id, sessionId: "SB1")
        vmB.startNewStreamingResponse()

        // 1. Background slot B receives session/request_permission for SB1
        try h.connB.enqueue(.request(.init(
            id: .int(701),
            method: "session/request_permission",
            params: .object([
                "sessionId": .string("SB1"),
                "toolCall": .object(["toolCallId": .string("tc-701"), "title": .string("Run shell")]),
                "options": .array([
                    .object(["optionId": .string("allow_once"), "name": .string("Allow"), "kind": .string("allow_once")])
                ])
            ])
        )))

        try await waitUntil {
            vmB.chatMessages.contains { $0.segments.contains { $0.toolCall?.permissionOptions != nil } }
        }

        // 2. Background slot B receives fs/read_text_file -> B socket replies with -32001 error
        try h.connB.enqueue(.request(.init(
            id: .int(702),
            method: "fs/read_text_file",
            params: .object(["sessionId": .string("SB1"), "path": .string("/tmp/secret")])
        )))
        try await waitUntil {
            h.connB.sentJSONObjects.contains {
                ($0["id"] as? Int) == 702 && (($0["error"] as? [String: Any])?["code"] as? Int) == -32001
            }
        }

        // 3. Respond to permission via serverVMB & cancel via appVM.sendCancel(serverId: B, sessionId: "SB1")
        h.serverVMB.sendPermissionResponse(requestId: .int(701), optionId: "allow_once")
        try await waitUntil { h.connB.sentJSONObjects.contains { ($0["id"] as? Int) == 701 } }

        h.appVM.sendCancel(serverId: h.serverB.id, sessionId: "SB1")
        try await waitUntil { h.connB.sentJSONObjects.contains { ($0["method"] as? String) == "session/cancel" } }

        XCTAssertFalse(vmB.isStreaming)
        XCTAssertEqual(h.connA.sentJSONObjects.count, baselineACount, "BG-AC-7: Server A must receive 0 frames for B's permission/fs/cancel")
        XCTAssertEqual(h.appVM.selectedServerId, h.serverA.id)
    }

    // MARK: - AC-1 ⑤: Editing server name or workingDirectory skips out-of-pool validation (DEC-1=A)

    func testAC1_EditServerNameOrWorkingDirectorySkipsRemoteValidationAndKeepsConnection() async throws {
        let existing = ACPServerConfiguration(
            id: UUID(),
            name: "MacMini",
            scheme: "ws",
            host: "127.0.0.1:19501",
            token: "tok-1",
            workingDirectory: "/Users/dev/a"
        )

        // Add mode (editingServer == nil) must still run validation
        XCTAssertFalse(AddServerView.shouldSkipRemoteValidationOnEdit(
            editingServer: nil,
            scheme: "ws",
            host: "127.0.0.1:19501",
            token: "tok-1",
        ))

        // Name / workingDirectory-only changes (including whitespace / explicit scheme prefix) skip validation
        XCTAssertTrue(AddServerView.shouldSkipRemoteValidationOnEdit(
            editingServer: existing,
            scheme: "ws",
            host: " 127.0.0.1:19501 ",
            token: "tok-1",
        ))
        XCTAssertTrue(AddServerView.shouldSkipRemoteValidationOnEdit(
            editingServer: existing,
            scheme: "ws",
            host: "ws://127.0.0.1:19501",
            token: "tok-1",
        ))

        // Any connection parameter change must still validate
        XCTAssertFalse(AddServerView.shouldSkipRemoteValidationOnEdit(
            editingServer: existing, scheme: "wss", host: "127.0.0.1:19501",
            token: "tok-1",
        ))
        XCTAssertFalse(AddServerView.shouldSkipRemoteValidationOnEdit(
            editingServer: existing, scheme: "ws", host: "127.0.0.1:19502",
            token: "tok-1",
        ))
        XCTAssertFalse(AddServerView.shouldSkipRemoteValidationOnEdit(
            editingServer: existing, scheme: "ws", host: "127.0.0.1:19501",
            token: "tok-2",
        ))

        // Saving a name/workingDirectory-only edit keeps the live connection intact with 0 extra connects
        let suite = "AC1Edit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        storage.saveServer(existing)
        let conn = PoolScriptedWebSocket()
        var factoryCalls = 0
        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            defaultSlotServiceFactory: { config, encoder in
                factoryCalls += 1
                let provider = PoolSocketProvider(connections: [conn])
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: true
        )
        try await respondInitAndSync(on: conn, instanceId: "inst-edit", sessions: [])
        try await waitUntil { appVM.connectionState(for: existing.id) == .connected }
        XCTAssertEqual(factoryCalls, 1)

        let validated = ValidatedServerConfiguration(
            name: "MacMini Renamed",
            scheme: "ws",
            host: "127.0.0.1:19501",
            token: "tok-1",
            workingDirectory: "/Users/dev/b",
            agentInfo: nil
        )
        appVM.updateServer(existing.id, with: validated)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(factoryCalls, 1, "Name/workingDirectory-only edit must not open any extra WebSocket")
        XCTAssertEqual(conn.connectCount, 1)
        XCTAssertEqual(appVM.connectionState(for: existing.id), .connected)
        XCTAssertEqual(appVM.servers.first(where: { $0.id == existing.id })?.name, "MacMini Renamed")
        XCTAssertEqual(appVM.servers.first(where: { $0.id == existing.id })?.workingDirectory, "/Users/dev/b")
    }

    // MARK: - AC-2 / SC-AC-037: Real default-pool path with Server B selected & updateServer no rollback

    func testAC2_DefaultClaimPathSecondServerSelectedColdLaunchAndUpdateServerNoRollback() async throws {
        let suite = "AC2DefaultClaim.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let serverA = ACPServerConfiguration(
            id: UUID(), name: "ServerA", scheme: "ws", host: "127.0.0.1:19601",
            token: "tA", workingDirectory: "/a"
        )
        let serverB = ACPServerConfiguration(
            id: UUID(), name: "ServerB", scheme: "ws", host: "127.0.0.1:19602",
            token: "tB", workingDirectory: "/b"
        )
        storage.saveServer(serverA)
        storage.saveServer(serverB)
        // Cold launch selects Server B (the second server, exercising unified single-track ServerConnectionPool)
        defaults.set(serverB.id.uuidString, forKey: "Agmente.lastServerId")

        let connA1 = PoolScriptedWebSocket()
        let connB1 = PoolScriptedWebSocket()
        let connB2 = PoolScriptedWebSocket()
        let connBNew1 = PoolScriptedWebSocket()
        let connBNew2 = PoolScriptedWebSocket()

        var queueA = [connA1]
        var queueB = [connB1, connB2]
        var queueBNew = [connBNew1, connBNew2]
        var dialedUrls: [String] = []

        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            defaultSlotServiceFactory: { config, encoder in
                let urlStr = config.endpoint.absoluteString
                dialedUrls.append(urlStr)
                let sock: PoolScriptedWebSocket
                if urlStr.contains("19601") {
                    sock = queueA.isEmpty ? PoolScriptedWebSocket() : queueA.removeFirst()
                } else if urlStr.contains("19602") {
                    sock = queueB.isEmpty ? PoolScriptedWebSocket() : queueB.removeFirst()
                } else {
                    sock = queueBNew.isEmpty ? PoolScriptedWebSocket() : queueBNew.removeFirst()
                }
                let client = ACPClient(
                    configuration: config,
                    socketProvider: PoolSocketProvider(connections: [sock]),
                    logger: NoOpLogger(),
                    encoder: encoder
                )
                return ACPService(client: client)
            },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: true
        )

        XCTAssertEqual(appVM.selectedServerId, serverB.id)
        try await respondInitAndSync(on: connA1, instanceId: "inst-A", sessions: ["SA1"])
        try await respondInitAndSync(on: connB1, instanceId: "inst-B", sessions: ["SB1"])
        try await waitUntil {
            appVM.connectionState(for: serverA.id) == .connected
                && appVM.connectionState(for: serverB.id) == .connected
        }

        // Single-track connection pool: each server owns an independent slot & manager (SC-AC-037)
        let slotA = appVM.connectionSlot(for: serverA.id)
        let slotB = appVM.connectionSlot(for: serverB.id)
        XCTAssertTrue(slotA.connectionManager !== slotB.connectionManager, "AC-2: Each server must run on an independent manager")
        XCTAssertEqual(dialedUrls.filter { $0.contains("19601") }.count, 1)
        XCTAssertEqual(dialedUrls.filter { $0.contains("19602") }.count, 1)
        XCTAssertEqual(appVM.connectionState, .connected)
        XCTAssertTrue(appVM.service === appVM.service(for: serverB.id), "AC-2: appVM.service must reflect selected Server B")
        XCTAssertFalse(appVM.service === appVM.service(for: serverA.id))

        // disconnect() / connect() / connectAndWait() / initializeAndWait() must target Server B ONLY
        appVM.disconnect()
        XCTAssertEqual(appVM.connectionState(for: serverB.id), .disconnected)
        XCTAssertEqual(appVM.connectionState, .disconnected)
        XCTAssertNil(appVM.service)
        XCTAssertEqual(appVM.connectionState(for: serverA.id), .connected, "AC-2: Disconnecting selected Server B must leave Server A untouched")

        let reconnectTask = Task { await appVM.connectAndWait() }
        try await respondInitAndSync(on: connB2, instanceId: "inst-B2", sessions: ["SB1"])
        let reconnected = await reconnectTask.value
        XCTAssertTrue(reconnected)
        let initOk = await appVM.initializeAndWait()
        XCTAssertTrue(initOk)
        XCTAssertEqual(dialedUrls.filter { $0.contains("19601") }.count, 1, "AC-2: Server A must have 0 extra connects")
        XCTAssertEqual(dialedUrls.filter { $0.contains("19602") }.count, 2)

        // updateServer(ServerB) with new port + token must immediately dial new endpoint and never roll back on subsequent connect()
        let updatedB = ValidatedServerConfiguration(
            name: "ServerB",
            scheme: "ws",
            host: "127.0.0.1:19603",
            token: "tB-new",
            workingDirectory: "/b",
            agentInfo: nil
        )
        appVM.updateServer(serverB.id, with: updatedB)
        try await respondInitAndSync(on: connBNew1, instanceId: "inst-BNew1", sessions: ["SB1"])
        try await waitUntil { appVM.connectionState(for: serverB.id) == .connected }
        XCTAssertEqual(dialedUrls.last, "ws://127.0.0.1:19603")
        XCTAssertEqual(connBNew1.lastConnectHeaders["Authorization"], "Bearer tB-new")
        XCTAssertEqual(appVM.endpointHost, "127.0.0.1:19603")
        XCTAssertEqual(appVM.token, "tB-new")

        // Subsequent disconnect() + connect() must persist and dial NEW host/token (zero rollback to 19602 / tB)
        appVM.disconnect()
        appVM.connect()
        try await respondInitAndSync(on: connBNew2, instanceId: "inst-BNew2", sessions: ["SB1"])
        try await waitUntil { appVM.connectionState(for: serverB.id) == .connected }
        XCTAssertEqual(dialedUrls.last, "ws://127.0.0.1:19603")
        XCTAssertEqual(connBNew2.lastConnectHeaders["Authorization"], "Bearer tB-new")
        let persistedB = storage.fetchServers().first(where: { $0.id == serverB.id })
        XCTAssertEqual(persistedB?.host, "127.0.0.1:19603", "AC-2: Core Data must retain updated host")
        XCTAssertEqual(persistedB?.token, "tB-new", "AC-2: Core Data must retain updated token")
        XCTAssertEqual(dialedUrls.filter { $0.contains("19601") }.count, 1, "AC-2: Server A still untouched")
    }

    // MARK: - AC-3 / SC-AC-038 / SC-AC-053: Disconnected slot service == nil, sync barrier isolation across servers, sendCancel zero cross-talk, single-track slot tests

    func testAC3_SlotIsolationDisconnectedServiceNilSyncBarrierPreservedAndCancelZeroCrossTalk() async throws {
        let suite = "AC3Isolation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let serverA = ACPServerConfiguration(
            id: UUID(), name: "ServerA", scheme: "ws", host: "127.0.0.1:19701",
            token: "tA", workingDirectory: "/a"
        )
        let serverB = ACPServerConfiguration(
            id: UUID(), name: "ServerB", scheme: "ws", host: "127.0.0.1:19702",
            token: "tB", workingDirectory: "/b"
        )
        storage.saveServer(serverA)
        storage.saveServer(serverB)
        defaults.set(serverB.id.uuidString, forKey: "Agmente.lastServerId")

        let connA = PoolScriptedWebSocket()
        let connB1 = PoolScriptedWebSocket()
        let connB2 = PoolScriptedWebSocket()
        let connB3 = PoolScriptedWebSocket()
        let connB4 = PoolScriptedWebSocket()
        var queueA = [connA]
        var queueB = [connB1, connB2, connB3, connB4]

        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            defaultSlotServiceFactory: { config, encoder in
                let isA = config.endpoint.absoluteString.contains("19701")
                let sock = isA
                    ? (queueA.isEmpty ? PoolScriptedWebSocket() : queueA.removeFirst())
                    : (queueB.isEmpty ? PoolScriptedWebSocket() : queueB.removeFirst())
                let client = ACPClient(
                    configuration: config,
                    socketProvider: PoolSocketProvider(connections: [sock]),
                    logger: NoOpLogger(),
                    encoder: encoder
                )
                return ACPService(client: client)
            },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: true
        )

        try await respondInitAndSync(on: connA, instanceId: "inst-A", sessions: ["SA1"])
        try await respondInitAndSync(on: connB1, instanceId: "inst-B", sessions: ["SB1"])
        try await waitUntil {
            appVM.connectionState(for: serverA.id) == .connected
                && appVM.connectionState(for: serverB.id) == .connected
        }

        let vmA = try XCTUnwrap(appVM.serverViewModels[serverA.id])
        try await waitUntil { vmA.hasCompletedNonlocalSync }

        // Keep an active sync barrier & streaming session on Server A (owned exclusively by BridgeSyncCoordinator, SD-2.4)
        let syncTaskA = Task<Void, Never> {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
        defer { syncTaskA.cancel() }
        var stateA = appVM.syncCoordinator.syncStateByServer[serverA.id] ?? .init()
        stateA.initialSyncTask = syncTaskA
        appVM.syncCoordinator.syncStateByServer[serverA.id] = stateA
        let origSyncedServiceIdA = stateA.syncedServiceObjectId
        appVM.syncCoordinator.isSyncingByServer[serverA.id] = true
        appVM.syncCoordinator.bufferedLiveUpdatesDuringSync[serverA.id] = [
            ACP.Value.object(["sessionId": ACP.Value.string("SA1")])
        ]
        appVM.syncCoordinator.bufferedTurnCompletedDuringSync[serverA.id] = [
            NonlocalTurnCompletedNotification(instanceId: "inst-A", sessionId: "SA1", turnId: "t-buf-1", status: .completed)
        ]
        appVM.syncCoordinator.bufferedSessionStaleDuringSync[serverA.id] = [
            NonlocalSessionStaleNotification(instanceId: "inst-A", sessionId: "SA1", updatedAt: nil)
        ]
        appVM.syncCoordinator.bufferedSessionDeletedDuringSync[serverA.id] = [
            NonlocalSessionDeletedNotification(instanceId: "inst-A", sessionId: "SA1")
        ]
        let assertServerASyncBarrierIntact: (String) -> Void = { step in
            XCTAssertNotNil(appVM.syncCoordinator.syncStateByServer[serverA.id]?.initialSyncTask, "AC-3 ② (\(step)): must preserve A's initialSyncTask")
            XCTAssertFalse(syncTaskA.isCancelled, "AC-3 ② (\(step)): must NOT cancel A's initialSyncTask")
            XCTAssertEqual(appVM.syncCoordinator.syncStateByServer[serverA.id]?.syncedServiceObjectId, origSyncedServiceIdA, "AC-3 ② (\(step)): must preserve A's syncedServiceObjectId")
            XCTAssertEqual(appVM.isSyncingByServer[serverA.id], true, "AC-3 ② (\(step)): must preserve isSyncingByServer[A]")
            XCTAssertEqual(appVM.syncCoordinator.bufferedLiveUpdatesDuringSync[serverA.id]?.count, 1, "AC-3 ② (\(step)): must preserve bufferedLiveUpdatesDuringSync[A]")
            XCTAssertEqual(appVM.syncCoordinator.bufferedTurnCompletedDuringSync[serverA.id]?.count, 1, "AC-3 ② (\(step)): must preserve bufferedTurnCompletedDuringSync[A]")
            XCTAssertEqual(appVM.syncCoordinator.bufferedSessionStaleDuringSync[serverA.id]?.count, 1, "AC-3 ② (\(step)): must preserve bufferedSessionStaleDuringSync[A]")
            XCTAssertEqual(appVM.syncCoordinator.bufferedSessionDeletedDuringSync[serverA.id]?.count, 1, "AC-3 ② (\(step)): must preserve bufferedSessionDeletedDuringSync[A]")
            XCTAssertTrue(vmA.hasCompletedNonlocalSync, "AC-3 ② (\(step)): must preserve A's hasCompletedNonlocalSync")
        }
        let sessionVMA = vmA.sessionViewModel(for: "SA1")
        sessionVMA.setSessionContext(serverId: serverA.id, sessionId: "SA1")
        sessionVMA.startNewStreamingResponse()

        // Passively close Server B with 4001 (so manager.service may still exist internally while state is .disconnected)
        connB1.simulateClose(code: 4001, reason: "preempted_by_new_connection")
        try await waitUntil { appVM.connectionState(for: serverB.id) == .disconnected }

        // ① Strictly disconnected / nil — never fall back to Server A and never return stale disconnected ACPService
        XCTAssertEqual(appVM.connectionState(for: serverB.id), .disconnected)
        XCTAssertNil(appVM.service(for: serverB.id), "AC-3 ①: service(for: B) must be nil when B is disconnected")
        XCTAssertEqual(appVM.connectionState, .disconnected)
        XCTAssertNil(appVM.service, "AC-3 ①: appVM.service must be nil when selected Server B is disconnected")
        XCTAssertEqual(appVM.connectionState(for: serverA.id), .connected)
        XCTAssertNotNil(appVM.service(for: serverA.id))

        // ③ sendCancel on offline Server B sends 0 frames to Server A and does not cancel Server A's active stream
        let baselineACount = connA.sentJSONObjects.count
        appVM.sendCancel(serverId: serverB.id, sessionId: "SB1")
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(connA.sentJSONObjects.count, baselineACount, "AC-3 ③: Offline B sendCancel must send 0 frames on A")
        XCTAssertTrue(sessionVMA.isStreaming, "AC-3 ③: Offline B sendCancel must NOT stop A's active streaming session")

        // ② disconnect() / connect() / connectAndWait() / updateServer(B with real connection change) must preserve Server A's entire sync barrier state
        appVM.disconnect()
        assertServerASyncBarrierIntact("disconnect(B)")

        appVM.connect()
        try await respondInitAndSync(on: connB2, instanceId: "inst-B2", sessions: ["SB1"])
        try await waitUntil { appVM.connectionState(for: serverB.id) == .connected }
        assertServerASyncBarrierIntact("connect(B)")

        appVM.disconnect()
        let connectWaitTask = Task { await appVM.connectAndWait() }
        try await respondInitAndSync(on: connB3, instanceId: "inst-B3", sessions: ["SB1"])
        let waitedOk = await connectWaitTask.value
        XCTAssertTrue(waitedOk)
        assertServerASyncBarrierIntact("connectAndWait(B)")

        // Real connection parameter change (host + token changed -> connectionChanged == true -> executes resetSyncCoordinationState(for: B))
        appVM.updateServer(
            serverB.id,
            with: ValidatedServerConfiguration(
                name: "ServerB-Edited",
                scheme: "ws",
                host: "127.0.0.1:19703",
                token: "tB-new",
                workingDirectory: "/b2",
                agentInfo: nil
            )
        )
        try await respondInitAndSync(on: connB4, instanceId: "inst-B4", sessions: ["SB1"])
        try await waitUntil { appVM.connectionState(for: serverB.id) == .connected }
        assertServerASyncBarrierIntact("updateServer(B connectionChanged)")

        // SC-AC-038 ③: Per-server logWire isolation — appVM.updates reflects ONLY selected server's slot.updates
        let msgA = ACPWireMessage.notification(.init(method: "custom/logA", params: .object(["tag": .string("LOG_ONLY_A")])))
        let msgB = ACPWireMessage.notification(.init(method: "custom/logB", params: .object(["tag": .string("LOG_ONLY_B")])))
        appVM.logWire("←", message: msgA, serverId: serverA.id)
        appVM.logWire("←", message: msgB, serverId: serverB.id)
        XCTAssertTrue(appVM.updates.contains { $0.message.contains("LOG_ONLY_B") }, "SC-AC-038 ③: selected ServerB updates must contain LOG_ONLY_B")
        XCTAssertFalse(appVM.updates.contains { $0.message.contains("LOG_ONLY_A") }, "SC-AC-038 ③: selected ServerB updates must NOT leak LOG_ONLY_A")
        XCTAssertTrue(appVM.connectionPool.updates(for: serverA.id).contains { $0.message.contains("LOG_ONLY_A") })
        XCTAssertFalse(appVM.connectionPool.updates(for: serverA.id).contains { $0.message.contains("LOG_ONLY_B") })

        // SC-AC-038 ④: Released slot B must not fall back to Server A's manager & late stale callbacks are silently dropped
        let staleManagerB = try XCTUnwrap(appVM.slotConnectionManagerIfExists(for: serverB.id))
        let aLogsBeforeStale = appVM.connectionPool.updates(for: serverA.id).count
        appVM.deleteServer(serverB.id)
        XCTAssertNil(appVM.slotConnectionManagerIfExists(for: serverB.id), "Released slot B must not fall back to legacy manager")
        XCTAssertNil(appVM.syncCoordinator.syncStateByServer[serverB.id], "SC-AC-038 ④: deleted slot sync state must be cleared")
        appVM.slotManager(staleManagerB, serverId: serverB.id, didChangeState: .connected)
        appVM.slotManager(staleManagerB, serverId: serverB.id, didLog: "STALE_LATE_CALLBACK_B")
        XCTAssertNil(appVM.slotConnectionManagerIfExists(for: serverB.id), "SC-AC-038 ④: late callback must not recreate deleted slot B")
        XCTAssertEqual(appVM.connectionPool.updates(for: serverA.id).count, aLogsBeforeStale, "SC-AC-038 ④: late callback on B must have zero side effect on A")
    }

    // MARK: - AC-4 / SC-AC-039: Handshake dedup, rapid .background -> .active, and 4001 preemption recovery boundaries (DEC-1=A, DEC-2=A)

    func testAC4_HandshakeDedupRapidBackgroundActiveAndPreemptionRecoveryRules() async throws {
        let suite = "AC4Lifecycle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let serverA = ACPServerConfiguration(
            id: UUID(), name: "ServerA", scheme: "ws", host: "127.0.0.1:19801",
            token: "tA", workingDirectory: "/a"
        )
        let serverB = ACPServerConfiguration(
            id: UUID(), name: "ServerB", scheme: "ws", host: "127.0.0.1:19802",
            token: "tB", workingDirectory: "/b"
        )
        storage.saveServer(serverA)
        storage.saveServer(serverB)
        defaults.set(serverB.id.uuidString, forKey: "Agmente.lastServerId")

        var socketsA: [SuspendedHandshakeWebSocket] = []
        var socketsB: [SuspendedHandshakeWebSocket] = []

        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            defaultSlotServiceFactory: { config, encoder in
                let sock = SuspendedHandshakeWebSocket()
                if config.endpoint.absoluteString.contains("19801") {
                    socketsA.append(sock)
                } else {
                    socketsB.append(sock)
                }
                let singleClient = ACPClient(
                    configuration: config,
                    socketProvider: SingleSocketProvider(socket: sock),
                    logger: NoOpLogger(),
                    encoder: encoder
                )
                return ACPService(client: singleClient)
            },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )

        // ① Start connecting both servers -> suspended mid-handshake (isConnecting == true, state == .disconnected)
        appVM.connectAllServers()
        try await waitUntil { socketsA.count == 1 && socketsB.count == 1 }
        try await waitUntil {
            appVM.connectionSlot(for: serverA.id).connectionManager.isConnecting
                && appVM.connectionSlot(for: serverB.id).connectionManager.isConnecting
        }

        // Repeated re-entrant triggers during handshake must NOT create duplicate sockets
        appVM.connectAllServers()
        appVM.handleScenePhaseChanged(.active)
        appVM.resumeConnectionIfNeeded()
        await appVM.refreshSessions()
        try await Task.sleep(nanoseconds: 60_000_000)

        XCTAssertEqual(socketsA.count, 1, "AC-4 ①: Server A must dial strictly once while handshake is pending")
        XCTAssertEqual(socketsB.count, 1, "AC-4 ①: Server B must dial strictly once while handshake is pending")

        // ② Rapid .background -> .active while still in handshake (without waiting for async socket close)
        appVM.handleScenePhaseChanged(.background)
        XCTAssertFalse(appVM.connectionSlot(for: serverA.id).connectionManager.isConnecting, "AC-4 ②: disconnect() must synchronously clear isConnecting")
        XCTAssertFalse(appVM.connectionSlot(for: serverB.id).connectionManager.isConnecting)

        appVM.handleScenePhaseChanged(.active)
        try await waitUntil { socketsA.count == 2 && socketsB.count == 2 }
        socketsA[1].releaseHandshake()
        socketsB[1].releaseHandshake()
        try await waitUntil {
            appVM.connectionState(for: serverA.id) == .connected
                && appVM.connectionState(for: serverB.id) == .connected
        }
        XCTAssertEqual(socketsA.count, 2, "AC-4 ②: Rapid .background -> .active must reconnect cleanly once")
        XCTAssertEqual(socketsB.count, 2, "AC-4 ②: Rapid .background -> .active must reconnect cleanly once")

        // Complete initialize on selected Server B so `isInitialAppLaunch` flips to `false` (ensuring !wasPreempted is the sole gate in shouldAutoConnectOnSessionListAppear)
        try await waitUntil { socketsB[1].sentJSONObjects.contains { ($0["method"] as? String) == "initialize" } }
        let initReqB = try XCTUnwrap(socketsB[1].sentJSONObjects.first { ($0["method"] as? String) == "initialize" })
        try socketsB[1].enqueueResponse(id: initReqB["id"]!, result: .object([
            "protocolVersion": .int(1),
            "agentCapabilities": .object(["loadSession": .bool(true), "listSessions": .bool(true)]),
            "agentInfo": .object(["name": .string("agy"), "version": .string("1.0")])
        ]))
        try await waitUntil { !appVM.isInitialAppLaunch }

        // ③ Server B preempted by external 4001 -> DEC-1=A status/banner & DEC-2=A recovery boundaries
        socketsB[1].simulateClose(code: 4001, reason: "preempted_by_new_connection")
        try await waitUntil {
            appVM.connectionState(for: serverB.id) == .disconnected
                && appVM.wasPreempted(for: serverB.id)
        }
        XCTAssertFalse(appVM.isInitialAppLaunch, "AC-4 ③: isInitialAppLaunch must be false so !wasPreempted is actually tested")
        XCTAssertFalse(appVM.isManuallyDisconnected(serverId: serverB.id))
        XCTAssertEqual(appVM.connectionState, .disconnected)
        XCTAssertFalse(appVM.isConnecting)
        XCTAssertTrue(appVM.wasPreempted)
        XCTAssertEqual(appVM.preemptedServersInCurrentMode.map(\.id), [serverB.id])
        XCTAssertEqual(appVM.stateLabel(for: serverB.id), AppLocalization.localized("Taken over by another connection"))
        XCTAssertEqual(appVM.currentStateLabel, AppLocalization.localized("Taken over by another connection"))
        XCTAssertFalse(appVM.shouldAutoConnectOnSessionListAppear, "AC-4 ③ / DEC-2=A: SessionListPage.onAppear must NOT auto-reconnect 4001-preempted slot")

        // .active -> .inactive -> .active (Notification Center / Face ID) must NOT auto-reclaim preempted Server B
        appVM.handleScenePhaseChanged(.inactive)
        appVM.handleScenePhaseChanged(.active)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(socketsB.count, 2, "AC-4 ③ / DEC-2=A: .inactive -> .active must NOT auto-reconnect 4001-preempted slot")
        XCTAssertTrue(appVM.wasPreempted(for: serverB.id))

        // Real iOS background/foreground sequence: .inactive -> .background -> .inactive -> .active MUST clear preemption and reclaim Server B
        appVM.handleScenePhaseChanged(.inactive)
        appVM.handleScenePhaseChanged(.background)
        appVM.handleScenePhaseChanged(.inactive)
        appVM.handleScenePhaseChanged(.active)
        try await waitUntil { socketsB.count == 3 && socketsA.count == 3 }
        socketsA[2].releaseHandshake()
        socketsB[2].releaseHandshake()
        try await waitUntil { appVM.connectionState(for: serverB.id) == .connected }
        XCTAssertFalse(appVM.wasPreempted(for: serverB.id))
        XCTAssertTrue(appVM.preemptedServersInCurrentMode.isEmpty)

        // Preempt B again -> explicit connectServer(B) clears preemption and reconnects
        socketsB[2].simulateClose(code: 4001, reason: "preempted_by_new_connection")
        try await waitUntil { appVM.wasPreempted(for: serverB.id) }
        appVM.connectServer(serverB.id)
        try await waitUntil { socketsB.count == 4 }
        socketsB[3].releaseHandshake()
        try await waitUntil { appVM.connectionState(for: serverB.id) == .connected }
        XCTAssertFalse(appVM.wasPreempted(for: serverB.id))
    }

    private final class SingleSocketProvider: WebSocketProviding, @unchecked Sendable {
        private let socket: WebSocketConnection
        init(socket: WebSocketConnection) { self.socket = socket }
        func makeConnection(url: URL) -> WebSocketConnection { socket }
    }
}
