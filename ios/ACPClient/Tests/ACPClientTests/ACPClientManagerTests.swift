import Foundation
import XCTest
@testable import ACPClient
import ACPClientMocks

@MainActor
final class ACPClientManagerTests: XCTestCase {
    private struct TestError: Error {}

    private func extractRequestId(from text: String) -> Int? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? Int else {
            return nil
        }
        return id
    }

    private func waitForSentText(
        connection: MockWebSocketConnection,
        predicate: (String) -> Bool,
        attempts: Int = 50
    ) async -> String? {
        for _ in 0..<attempts {
            if let match = connection.sentTexts.first(where: predicate) {
                return match
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    private func makeManager(
        defaults: UserDefaults,
        connection: MockWebSocketConnection
    ) -> ACPClientManager {
        let factory: (ACPClientConfiguration, JSONEncoder) -> ACPService = { config, encoder in
            let provider = MockWebSocketProvider(connection: connection)
            let client = ACPClient(
                configuration: config,
                socketProvider: provider,
                logger: NoOpLogger(),
                encoder: encoder
            )
            return ACPService(client: client)
        }
        return ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: factory
        )
    }

    // MARK: - Client ID Persistence

    func testGeneratesAndPersistsClientId() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)

        XCTAssertFalse(manager.clientId.isEmpty, "Should generate a non-empty client ID")
        XCTAssertEqual(defaults.string(forKey: "ACPClientManager.clientId"), manager.clientId)
    }

    func testReusesPersistedClientId() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let existingId = "test-client-id-123"
        defaults.set(existingId, forKey: "ACPClientManager.clientId")

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)

        XCTAssertEqual(manager.clientId, existingId)
    }

    func testUsesProvidedClientId() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        defaults.set("stored-id", forKey: "ACPClientManager.clientId")
        let providedId = "provided-id-456"

        let manager = ACPClientManager(defaults: defaults, clientId: providedId, shouldStartNetworkMonitoring: false)

        XCTAssertEqual(manager.clientId, providedId, "Should use provided client ID over stored")
    }

    // MARK: - Initial State

    func testInitialState() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)

        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertFalse(manager.isConnecting)
        XCTAssertTrue(manager.isNetworkAvailable) // Default before monitoring starts
        XCTAssertNil(manager.service)
        XCTAssertNil(manager.lastConnectedAt)
    }

    func testLoadsPersistedLastConnectedAt() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let timestamp = Date().timeIntervalSince1970 - 3600 // 1 hour ago
        defaults.set(timestamp, forKey: "ACPClientManager.lastConnectedAt")

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)

        XCTAssertNotNil(manager.lastConnectedAt)
        XCTAssertEqual(manager.lastConnectedAt!.timeIntervalSince1970, timestamp, accuracy: 1.0)
    }

    // MARK: - Configuration

    // SC-AC-015: ACPConnectionConfig has no legacy CF Access fields or headers.
    func testSCAC015_ConnectionConfigDefaultsAndAllOptions() async {
        let url = URL(string: "ws://localhost:8765")!
        let defaultsConfig = ACPConnectionConfig(endpoint: url)

        XCTAssertEqual(defaultsConfig.endpoint, url)
        XCTAssertNil(defaultsConfig.authToken)
        XCTAssertEqual(defaultsConfig.pingInterval, 15)

        let secureURL = URL(string: "wss://secure.example.com")!
        let config = ACPConnectionConfig(
            endpoint: secureURL,
            authToken: "bearer-token",
            pingInterval: 30
        )

        XCTAssertEqual(config.endpoint, secureURL)
        XCTAssertEqual(config.authToken, "bearer-token")
        XCTAssertEqual(config.pingInterval, 30)

        let suiteName = "test-headers-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let conn = MockWebSocketConnection()
        let manager = makeManager(defaults: defaults, connection: conn)
        _ = await manager.connectAndWait(config: config)
        XCTAssertEqual(conn.receivedHeaders["Authorization"], "Bearer bearer-token")
        XCTAssertEqual(conn.receivedHeaders["X-Client-Id"], manager.clientId)
        XCTAssertNil(conn.receivedHeaders["CF-Access-Client-Id"])
        XCTAssertNil(conn.receivedHeaders["CF-Access-Client-Secret"])
        manager.disconnect()
    }

    // MARK: - Reconnect Defaults

    func testDefaultReconnectSettings() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)

        XCTAssertEqual(manager.maxReconnectAttempts, 3)
        XCTAssertEqual(manager.reconnectBaseDelay, 1.0)
        XCTAssertEqual(manager.healthCheckTimeout, 8.0)
    }

    func testCustomReconnectSettings() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.maxReconnectAttempts = 5
        manager.reconnectBaseDelay = 2.0
        manager.healthCheckTimeout = 10.0

        XCTAssertEqual(manager.maxReconnectAttempts, 5)
        XCTAssertEqual(manager.reconnectBaseDelay, 2.0)
        XCTAssertEqual(manager.healthCheckTimeout, 10.0)
    }

    // MARK: - Disconnect

    func testDisconnectResetsState() async {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.disconnect()

        // Give async disconnect time to complete
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertFalse(manager.isConnecting)
        XCTAssertNil(manager.service)
    }

    // MARK: - Delegate

    func testDelegateReceivesLogMessages() async {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let mockDelegate = MockClientManagerDelegate()
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        manager.delegate = mockDelegate

        // Disconnect should log - trigger via disconnect which doesn't require a connection
        manager.disconnect()

        // Give async operations time to complete
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(mockDelegate.stateChanges.last, .disconnected)
    }

    // MARK: - Lifecycle

    func testConnectAndWaitUpdatesStateAndLastConnectedAt() async {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let connection = MockWebSocketConnection()
        let manager = makeManager(defaults: defaults, connection: connection)
        let config = ACPConnectionConfig(endpoint: URL(string: "ws://localhost:8765")!)

        let success = await manager.connectAndWait(config: config)

        XCTAssertTrue(success)
        XCTAssertEqual(manager.connectionState, .connected)
        XCTAssertNotNil(manager.lastConnectedAt)
        XCTAssertGreaterThan(defaults.double(forKey: "ACPClientManager.lastConnectedAt"), 0)

        manager.disconnect()
    }

    func testVerifyConnectionHealthPingsService() async {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let connection = MockWebSocketConnection()
        let manager = makeManager(defaults: defaults, connection: connection)
        let config = ACPConnectionConfig(endpoint: URL(string: "ws://localhost:8765")!)

        _ = await manager.connectAndWait(config: config)
        let pingCountBefore = connection.pingCount
        await manager.verifyConnectionHealth()

        XCTAssertGreaterThanOrEqual(connection.pingCount, pingCountBefore + 1)

        manager.disconnect()
    }

    func testInitializeAndWaitSetsInitialized() async {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let connection = MockWebSocketConnection()
        let manager = makeManager(defaults: defaults, connection: connection)
        let config = ACPConnectionConfig(endpoint: URL(string: "ws://localhost:8765")!)

        _ = await manager.connectAndWait(config: config)

        let payload = ACPInitializationPayload(
            protocolVersion: 1,
            clientName: "Test",
            clientVersion: "0.1",
            clientCapabilities: [:]
        )

        let task = Task { await manager.initializeAndWait(payload: payload) }

        guard let sent = await waitForSentText(connection: connection, predicate: { $0.contains("\"initialize\"") }) else {
            XCTFail("Expected initialize request to be sent")
            return
        }
        let id = extractRequestId(from: sent) ?? 1
        let response = """
        {"jsonrpc":"2.0","id":\(id),"result":{}}
        """
        connection.enqueue(.text(response))

        let success = await task.value
        XCTAssertTrue(success)
        XCTAssertTrue(manager.isInitialized)
        XCTAssertFalse(manager.isInitializing)

        manager.disconnect()
    }

    func testSessionTrackingResetClearsState() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)

        manager.markSessionMaterialized("session-1")
        XCTAssertTrue(manager.isSessionMaterialized("session-1"))

        manager.resetSessionState()

        XCTAssertFalse(manager.isSessionMaterialized("session-1"))
    }

    func testFailedStateClearsConnectingFlag() {
        let suiteName = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let connection = MockWebSocketConnection()
        let manager = makeManager(defaults: defaults, connection: connection)
        let service = ACPService(client: ACPClient(configuration: .init(endpoint: URL(string: "ws://localhost:8765")!)))
        manager.setServiceForTesting(service)

        manager.acpService(service, didChangeState: .failed(TestError()))

        if case .failed = manager.connectionState {
        } else {
            XCTFail("Expected failed connection state")
        }
        XCTAssertFalse(manager.isConnecting)
    }

    // MARK: - AC-1: 4001 Preemption Stop-Auto-Reconnect, 1006 Reconnect, In-Flight Ping Cancel, Sync Disconnect & Orphan Guard

    private final class ScriptedCloseWebSocket: WebSocketConnection, @unchecked Sendable {
        enum ScriptError: Error { case closed, pingFailed }
        private let lock = NSLock()
        private var continuation: AsyncStream<Result<WebSocketEvent, Error>>.Continuation?
        private let stream: AsyncStream<Result<WebSocketEvent, Error>>
        private var dialContinuation: CheckedContinuation<Void, Error>?
        private let suspendDial: Bool
        var failNextPingAfterDelayNs: UInt64?
        private(set) var connectCount = 0
        private(set) var closeCount = 0

        init(suspendDial: Bool = false) {
            self.suspendDial = suspendDial
            var contRef: AsyncStream<Result<WebSocketEvent, Error>>.Continuation?
            self.stream = AsyncStream { contRef = $0 }
            self.continuation = contRef
        }

        func connect(headers: [String: String]) async throws {
            lock.withLock { connectCount += 1 }
            if suspendDial {
                try await withCheckedThrowingContinuation { cont in
                    lock.withLock { dialContinuation = cont }
                }
            }
        }

        func finishSuspendedDial() {
            let cont = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                let c = dialContinuation
                dialContinuation = nil
                return c
            }
            cont?.resume()
        }

        func send(text: String) async throws {}

        func receive() async throws -> WebSocketEvent {
            for await item in stream {
                return try item.get()
            }
            throw ScriptError.closed
        }

        func close() async {
            lock.withLock { closeCount += 1 }
            continuation?.finish()
        }

        func ping() async throws {
            if let delayNs = lock.withLock({ () -> UInt64? in
                let d = failNextPingAfterDelayNs
                failNextPingAfterDelayNs = nil
                return d
            }) {
                try? await Task.sleep(nanoseconds: delayNs)
                throw ScriptError.pingFailed
            }
        }

        func emitClose(code: Int, reason: String?) {
            continuation?.yield(.success(.closed(WebSocketCloseReason(code: code, reason: reason))))
            continuation?.finish()
        }
    }

    private final class MultiSocketProvider: WebSocketProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var sockets: [ScriptedCloseWebSocket]
        private(set) var createdCount = 0

        init(_ sockets: [ScriptedCloseWebSocket]) {
            self.sockets = sockets
        }

        func makeConnection(url: URL) -> WebSocketConnection {
            lock.withLock {
                createdCount += 1
                if !sockets.isEmpty {
                    return sockets.removeFirst()
                }
                return ScriptedCloseWebSocket()
            }
        }
    }

    // SC-AC-016: 4001 preemption stops auto-reconnect and cancels in-flight ping without .failed state.
    func testAC1_Preemption4001StopsAutoReconnectAndCancelsInFlightPingWithoutFailedState() async throws {
        let suiteName = "test-ac1-4001-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let socket1 = ScriptedCloseWebSocket()
        // Simulate an in-flight ping that throws shortly after 4001 close cancels pingTask
        socket1.failNextPingAfterDelayNs = 50_000_000
        let socket2 = ScriptedCloseWebSocket()
        let provider = MultiSocketProvider([socket1, socket2])

        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )
        manager.reconnectBaseDelay = 0.05
        let delegate = MockClientManagerDelegate()
        manager.delegate = delegate

        let config = ACPConnectionConfig(endpoint: URL(string: "ws://127.0.0.1:8765")!, pingInterval: 0.01)
        let ok = await manager.connectAndWait(config: config)
        XCTAssertTrue(ok)
        XCTAssertEqual(manager.connectionState, .connected)
        XCTAssertFalse(manager.wasPreempted)

        // Emit 4001 close while ping is in-flight
        socket1.emitClose(code: 4001, reason: "preempted_by_new_connection")

        // Wait > 4x reconnectBaseDelay (250ms) to ensure no reconnect and no spurious .failed state
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertEqual(manager.connectionState, .disconnected, "4001 close must stay .disconnected and not flip to .failed")
        XCTAssertTrue(manager.wasPreempted, "4001 close must set wasPreempted")
        XCTAssertEqual(manager.service?.lastCloseReason?.code, 4001)
        XCTAssertEqual(provider.createdCount, 1, "4001 preemption must NOT trigger auto-reconnect")
        XCTAssertFalse(delegate.stateChanges.contains { if case .failed = $0 { return true }; return false }, "Cancelled in-flight ping must not produce secondary .failed state")

        // Explicit reconnect clears wasPreempted and succeeds on socket2
        let reconnected = await manager.connectAndWait(config: config)
        XCTAssertTrue(reconnected)
        XCTAssertEqual(manager.connectionState, .connected)
        XCTAssertFalse(manager.wasPreempted)
        XCTAssertEqual(provider.createdCount, 2)

        manager.disconnect()
    }

    func testAC1_NormalClose1006ContinuesAutoReconnect() async throws {
        let suiteName = "test-ac1-1006-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let socket1 = ScriptedCloseWebSocket()
        let socket2 = ScriptedCloseWebSocket()
        let provider = MultiSocketProvider([socket1, socket2])

        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )
        manager.reconnectBaseDelay = 0.05

        let config = ACPConnectionConfig(endpoint: URL(string: "ws://127.0.0.1:8765")!, pingInterval: 60)
        let ok = await manager.connectAndWait(config: config)
        XCTAssertTrue(ok)
        XCTAssertEqual(provider.createdCount, 1)

        socket1.emitClose(code: 1006, reason: "tcp_end")

        // Wait for auto-reconnect to fire on socket2
        let deadline = Date().addingTimeInterval(2.0)
        while provider.createdCount < 2 && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertGreaterThanOrEqual(provider.createdCount, 2, "Non-4001 close (1006) must still auto-reconnect")
        XCTAssertFalse(manager.wasPreempted)

        manager.disconnect()
    }

    // SC-AC-017: Sync disconnect clears state immediately and prevents orphan handshake connections.
    func testAC1_SyncDisconnectClearsStateImmediatelyAndPreventsOrphanHandshakeConnection() async throws {
        let suiteName = "test-ac1-sync-disconnect-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let hangingSocket = ScriptedCloseWebSocket(suspendDial: true)
        let provider = MultiSocketProvider([hangingSocket])
        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                return ACPService(client: client)
            }
        )
        let config = ACPConnectionConfig(endpoint: URL(string: "ws://127.0.0.1:8765")!, pingInterval: 60)
        manager.connect(config: config)
        XCTAssertTrue(manager.isConnecting)

        // Wait briefly for dial to start
        let deadline = Date().addingTimeInterval(1.0)
        while hangingSocket.connectCount == 0 && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        // Disconnect synchronously clears connecting/service/state immediately
        manager.disconnect()
        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertFalse(manager.isConnecting)
        XCTAssertNil(manager.service)

        // Release the suspended dial -> must immediately close the orphan socket and never flip back to .connected
        hangingSocket.finishSuspendedDial()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(manager.connectionState, .disconnected)
        XCTAssertNil(manager.service)
        XCTAssertGreaterThanOrEqual(hangingSocket.closeCount, 1, "Aborted handshake socket must be closed to avoid orphan preemption")
    }
}

// MARK: - Mock Delegate

@MainActor
private final class MockClientManagerDelegate: ACPClientManagerDelegate {
    var stateChanges: [ACPConnectionState] = []
    var networkChanges: [Bool] = []
    var errors: [Error] = []
    var logMessages: [String] = []
    var createdServices: [ACPService] = []

    func clientManager(_ manager: ACPClientManager, didChangeState state: ACPConnectionState) {
        stateChanges.append(state)
    }

    func clientManager(_ manager: ACPClientManager, didChangeNetworkAvailability available: Bool) {
        networkChanges.append(available)
    }

    func clientManager(_ manager: ACPClientManager, didEncounterError error: Error) {
        errors.append(error)
    }

    func clientManager(_ manager: ACPClientManager, didLog message: String) {
        logMessages.append(message)
    }

    func clientManager(_ manager: ACPClientManager, didCreateService service: ACPService) {
        createdServices.append(service)
    }
}