import XCTest
import SwiftUI
import ACP
import ACPClient
@testable import Agmente

/// Comprehensive unit & state-machine test suite covering:
/// - SC-AC-020..031, SC-AC-071 (BridgeServerValidator admission, form validation, phased protocol lockout, 5-path block, DEC-30)
/// - SC-AC-040 (5-server network recovery with half-open .connected ping() health check)
/// - SC-AC-042 (QuotaManager DEC-27 multi-server push ingestion, wrong-binding rejection, cross-server timer migration)
/// - SC-AC-044 (ChatMessageCache + ServerViewModel Core Data separation)
/// - SC-AC-045 (PassiveStreamingSettler direct unidirectional state machine)
/// - SC-AC-046 (6-part shadow-state/patch removal regression)
/// - SC-AC-048, SC-AC-049 (Full TD-2 cross-server isolation positive + offline negative)
@MainActor
final class BridgeAdmissionAndLockoutTests: XCTestCase {

    // MARK: - Scripted Socket Infrastructure

    private final class ScriptedSocket: WebSocketConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var events: [WebSocketEvent] = []
        private var receiveCont: CheckedContinuation<WebSocketEvent, Error>?
        private(set) var sentTexts: [String] = []
        private(set) var closedCount: Int = 0
        private(set) var pingCount: Int = 0
        private(set) var connectCount: Int = 0
        var connectError: Error?
        var pingError: Error?
        var onSend: ((String, ScriptedSocket) -> Void)?

        func connect(headers: [String: String]) async throws {
            lock.lock()
            connectCount += 1
            let err = connectError
            lock.unlock()
            if let err { throw err }
        }

        func send(text: String) async throws {
            lock.lock()
            sentTexts.append(text)
            let cb = onSend
            lock.unlock()
            cb?(text, self)
        }

        func receive() async throws -> WebSocketEvent {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if !events.isEmpty {
                    let ev = events.removeFirst()
                    lock.unlock()
                    cont.resume(returning: ev)
                } else {
                    receiveCont = cont
                    lock.unlock()
                }
            }
        }

        func close() async {
            lock.lock()
            closedCount += 1
            let cont = receiveCont
            receiveCont = nil
            lock.unlock()
            cont?.resume(returning: .closed(WebSocketCloseReason(code: 1000)))
        }

        func ping() async throws {
            lock.lock()
            pingCount += 1
            let err = pingError
            lock.unlock()
            if let err { throw err }
        }

        func push(_ event: WebSocketEvent) {
            lock.lock()
            if let cont = receiveCont {
                receiveCont = nil
                lock.unlock()
                cont.resume(returning: event)
            } else {
                events.append(event)
                lock.unlock()
            }
        }

        func enqueueResponse(id: ACP.ID, result: ACP.Value) {
            let wire = ACPWireMessage.response(.init(id: id, result: result))
            if let data = try? JSONEncoder().encode(wire) {
                push(.text(String(decoding: data, as: UTF8.self)))
            }
        }

        func enqueueError(id: ACP.ID, code: Int, message: String) {
            let wire = ACPWireMessage.response(.init(id: id, error: .serverError(code: code, message: message)))
            if let data = try? JSONEncoder().encode(wire) {
                push(.text(String(decoding: data, as: UTF8.self)))
            }
        }

        func sentRequests() -> [ACP.AnyRequest] {
            lock.lock()
            let copy = sentTexts
            lock.unlock()
            return copy.compactMap { text in
                guard let data = text.data(using: .utf8),
                      let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                      case .request(let req) = wire else { return nil }
                return req
            }
        }

        func sentMethods() -> [String] {
            sentRequests().map(\.method)
        }

        func sentRawMessages() -> [ACPWireMessage] {
            lock.lock()
            let copy = sentTexts
            lock.unlock()
            return copy.compactMap { text in
                guard let data = text.data(using: .utf8) else { return nil }
                return try? JSONDecoder().decode(ACPWireMessage.self, from: data)
            }
        }
    }

    private final class SocketQueueProvider: WebSocketProviding, @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [ScriptedSocket]
        private(set) var makeCount: Int = 0
        private var factory: (() -> ScriptedSocket)?

        init(_ sockets: [ScriptedSocket], fallbackFactory: (() -> ScriptedSocket)? = nil) {
            self.queue = sockets
            self.factory = fallbackFactory
        }

        func makeConnection(url: URL) -> WebSocketConnection {
            lock.lock()
            makeCount += 1
            let next: ScriptedSocket
            if !queue.isEmpty {
                next = queue.removeFirst()
            } else if let factory {
                next = factory()
            } else {
                next = ScriptedSocket()
            }
            lock.unlock()
            return next
        }
    }

    private final class TestQuotaClock: QuotaUsageClock {
        private var current: Date
        private var waiters: [(deadline: Date, cont: CheckedContinuation<Void, Error>)] = []

        init(start: Date) { self.current = start }
        func now() -> Date { current }

        func sleep(seconds: TimeInterval) async throws {
            let deadline = current.addingTimeInterval(max(0, seconds))
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        cont.resume(throwing: CancellationError())
                        return
                    }
                    waiters.append((deadline, cont))
                }
            } onCancel: {
                Task { @MainActor in
                    let pending = self.waiters
                    self.waiters.removeAll()
                    for w in pending { w.cont.resume(throwing: CancellationError()) }
                }
            }
        }

        func advance(by seconds: TimeInterval) {
            current = current.addingTimeInterval(seconds)
            var remaining: [(deadline: Date, cont: CheckedContinuation<Void, Error>)] = []
            for w in waiters {
                if w.deadline <= current {
                    w.cont.resume(returning: ())
                } else {
                    remaining.append(w)
                }
            }
            waiters = remaining
        }
    }

    private var createdSuites: [String] = []

    override func tearDown() {
        for name in createdSuites {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        createdSuites.removeAll()
        super.tearDown()
    }

    private func makeDefaults(_ tag: String) -> UserDefaults {
        let name = "BridgeAdmissionAndLockoutTests.\(tag).\(UUID().uuidString)"
        createdSuites.append(name)
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    private func validInitResult() -> ACP.Value {
        .object([
            "protocolVersion": .int(1),
            "agentInfo": .object(["name": .string("agy"), "version": .string("2.0")]),
            "agentCapabilities": .object([
                "loadSession": .bool(true),
                "listSessions": .bool(true),
            ]),
        ])
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ label: @autoclosure () -> String = "",
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        XCTFail("Timed out waiting for condition [\(label())] after \(timeout)s")
    }

    // MARK: - SC-AC-020: Valid Nonlocal Bridge admission order & trimmedToken consistency

    func testSCAC020_ValidBridgeAdmissionOrderAndTrimmedToken() async {
        let defaults = makeDefaults("SCAC020")
        let socket = ScriptedSocket()
        var initParams: ACP.Value?
        socket.onSend = { text, sock in
            guard let data = text.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                  case .request(let req) = wire else { return }
            if req.method == "initialize" {
                initParams = req.params
                sock.enqueueResponse(id: req.id, result: self.validInitResult())
            } else if req.method == NonlocalMethods.sessionSync {
                sock.enqueueResponse(id: req.id, result: .object([
                    "instanceId": .string("inst-1"),
                    "activeTurns": .array([])
                ]))
            }
        }

        let validator = BridgeServerValidator(defaults: defaults) { config in
            ACPService(client: ACPClient(configuration: config, socketProvider: SocketQueueProvider([socket])))
        }

        let result = await validator.validate(
            name: "Mini",
            scheme: "ws",
            host: "127.0.0.1:18765",
            token: "  secret-token-32bytes  ",
            workingDirectory: "~",
            clientName: "Agmente iOS",
            clientVersion: "0.1.0",
            supportsFSRead: false,
            supportsFSWrite: false,
            supportsTerminal: false
        )

        switch result {
        case .success(let validated):
            XCTAssertEqual(validated.token, "secret-token-32bytes")
            XCTAssertEqual(validated.scheme, "ws")
            XCTAssertEqual(validated.host, "127.0.0.1:18765")
        case .failure(let error):
            XCTFail("SC-AC-020 expected success, got \(error)")
        }

        XCTAssertEqual(socket.sentMethods(), ["initialize", NonlocalMethods.sessionSync])
        XCTAssertFalse(socket.sentMethods().contains("session/list"))
        XCTAssertFalse(socket.sentMethods().contains("capability-probe"))
        XCTAssertNil(initParams?.objectValue?["experimentalApi"])
        XCTAssertGreaterThanOrEqual(socket.closedCount, 1, "SC-AC-020: temporary connection must be closed")
    }

    // MARK: - SC-AC-021: Initialize 5 rejections + "already initialized" positive exception

    func testSCAC021_InitializeFiveRejectionsAndAlreadyInitializedException() async {
        let defaults = makeDefaults("SCAC021")
        enum InitCase {
            case emptyObject
            case codexUserAgent
            case rpcError(Int)
        }
        let rejectCases: [(String, InitCase)] = [
            ("empty {}", .emptyObject),
            ("codex userAgent", .codexUserAgent),
            ("-32601", .rpcError(-32601)),
            ("-32600", .rpcError(-32600)),
            ("-32602", .rpcError(-32602)),
        ]

        for (label, mode) in rejectCases {
            let socket = ScriptedSocket()
            socket.onSend = { text, sock in
                guard let data = text.data(using: .utf8),
                      let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                      case .request(let req) = wire,
                      req.method == "initialize" else { return }
                switch mode {
                case .emptyObject:
                    sock.enqueueResponse(id: req.id, result: .object([:]))
                case .codexUserAgent:
                    sock.enqueueResponse(id: req.id, result: .object(["userAgent": .string("codex/1.0")]))
                case .rpcError(let code):
                    sock.enqueueError(id: req.id, code: code, message: "Rejected \(code)")
                }
            }
            let validator = BridgeServerValidator(defaults: defaults) { config in
                ACPService(client: ACPClient(configuration: config, socketProvider: SocketQueueProvider([socket])))
            }
            let result = await validator.validate(
                name: "Bad \(label)",
                scheme: "ws",
                host: "127.0.0.1:18766",
                token: "tok",
                workingDirectory: "~",
                clientName: "Agmente iOS",
                clientVersion: "0.1.0",
                supportsFSRead: false,
                supportsFSWrite: false,
                supportsTerminal: false
            )
            switch result {
            case .success:
                XCTFail("SC-AC-021 [\(label)]: must reject")
            case .failure(let err):
                let vErr = err as? AddServerValidationError
                XCTAssertTrue(vErr?.isIncompatibleBridgeError == true, "SC-AC-021 [\(label)]: must return .incompatibleBridge, got \(err)")
                XCTAssertFalse(vErr?.isLocalNetworkPermissionError == true)
                XCTAssertTrue(AddServerFormValidation.shouldPresentErrorAlert(for: err))
            }
            XCTAssertEqual(socket.sentMethods(), ["initialize"], "SC-AC-021 [\(label)]: must issue 0 nonlocal/sync")
            XCTAssertGreaterThanOrEqual(socket.closedCount, 1, "SC-AC-021 [\(label)]: must close temp socket")
        }

        // 6th case: "already initialized" positive exception proceeds to nonlocal/sync and succeeds
        let okSocket = ScriptedSocket()
        okSocket.onSend = { text, sock in
            guard let data = text.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                  case .request(let req) = wire else { return }
            if req.method == "initialize" {
                sock.enqueueError(id: req.id, code: -32600, message: "Server already initialized")
            } else if req.method == NonlocalMethods.sessionSync {
                sock.enqueueResponse(id: req.id, result: .object(["instanceId": .string("inst-already")]))
            }
        }
        let okValidator = BridgeServerValidator(defaults: defaults) { config in
            ACPService(client: ACPClient(configuration: config, socketProvider: SocketQueueProvider([okSocket])))
        }
        let okResult = await okValidator.validate(
            name: "AlreadyInit",
            scheme: "ws",
            host: "127.0.0.1:18766",
            token: "tok",
            workingDirectory: "~",
            clientName: "Agmente iOS",
            clientVersion: "0.1.0",
            supportsFSRead: false,
            supportsFSWrite: false,
            supportsTerminal: false
        )
        if case .failure(let err) = okResult {
            XCTFail("SC-AC-021 positive 'already initialized' must succeed, got \(err)")
        }
        XCTAssertEqual(okSocket.sentMethods(), ["initialize", NonlocalMethods.sessionSync])
    }

    // MARK: - SC-AC-022: nonlocal/sync 6 rejection cases

    func testSCAC022_NonlocalSyncSixRejectionCases() async {
        let defaults = makeDefaults("SCAC022")
        enum SyncCase {
            case rpcError(Int)
            case result(ACP.Value)
        }
        let cases: [(String, SyncCase)] = [
            ("-32601", .rpcError(-32601)),
            ("-32600", .rpcError(-32600)),
            ("-32602", .rpcError(-32602)),
            ("empty {}", .result(.object([:]))),
            ("empty instanceId", .result(.object(["instanceId": .string("")]))),
            ("whitespace instanceId", .result(.object(["instanceId": .string("   ")]))),
        ]

        for (label, mode) in cases {
            let socket = ScriptedSocket()
            socket.onSend = { text, sock in
                guard let data = text.data(using: .utf8),
                      let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                      case .request(let req) = wire else { return }
                if req.method == "initialize" {
                    sock.enqueueResponse(id: req.id, result: self.validInitResult())
                } else if req.method == NonlocalMethods.sessionSync {
                    switch mode {
                    case .rpcError(let code):
                        sock.enqueueError(id: req.id, code: code, message: "Sync error \(code)")
                    case .result(let val):
                        sock.enqueueResponse(id: req.id, result: val)
                    }
                }
            }
            let validator = BridgeServerValidator(defaults: defaults) { config in
                ACPService(client: ACPClient(configuration: config, socketProvider: SocketQueueProvider([socket])))
            }
            let result = await validator.validate(
                name: "SyncBad \(label)",
                scheme: "ws",
                host: "127.0.0.1:18767",
                token: "tok",
                workingDirectory: "~",
                clientName: "Agmente iOS",
                clientVersion: "0.1.0",
                supportsFSRead: false,
                supportsFSWrite: false,
                supportsTerminal: false
            )
            switch result {
            case .success:
                XCTFail("SC-AC-022 [\(label)]: must reject")
            case .failure(let err):
                let vErr = err as? AddServerValidationError
                XCTAssertTrue(vErr?.isIncompatibleBridgeError == true, "SC-AC-022 [\(label)]: expected .incompatibleBridge, got \(err)")
                XCTAssertTrue(AddServerFormValidation.shouldPresentErrorAlert(for: err))
            }
            XCTAssertGreaterThanOrEqual(socket.closedCount, 1, "SC-AC-022 [\(label)]: temp socket must be closed")
        }
    }

    // MARK: - SC-AC-023: 5 non-protocol faults never misclassified as .incompatibleBridge

    func testSCAC023_NonProtocolFaultsIsolatedFromIncompatibleBridge() async {
        let defaults = makeDefaults("SCAC023")

        // 1 & 2: -32000 & -32603 transient RPC errors
        for code in [-32000, -32603] {
            let socket = ScriptedSocket()
            socket.onSend = { text, sock in
                guard let data = text.data(using: .utf8),
                      let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                      case .request(let req) = wire,
                      req.method == "initialize" else { return }
                sock.enqueueError(id: req.id, code: code, message: "Transient \(code)")
            }
            let validator = BridgeServerValidator(defaults: defaults) { config in
                ACPService(client: ACPClient(configuration: config, socketProvider: SocketQueueProvider([socket])))
            }
            let res = await validator.validate(
                name: "Transient", scheme: "wss", host: "bridge.example.test", token: "tok",
                workingDirectory: "~", clientName: "Agmente iOS", clientVersion: "0.1.0",
                supportsFSRead: false, supportsFSWrite: false, supportsTerminal: false
            )
            if case .failure(let err) = res {
                let vErr = err as? AddServerValidationError
                XCTAssertFalse(vErr?.isIncompatibleBridgeError == true, "SC-AC-023 [\(code)] must NOT be .incompatibleBridge")
                XCTAssertFalse(vErr?.isLocalNetworkPermissionError == true)
                XCTAssertTrue(AddServerFormValidation.shouldPresentErrorAlert(for: err))
            } else {
                XCTFail("SC-AC-023 [\(code)] expected failure")
            }
        }

        // 3: HTTP 401 -> non-.incompatibleBridge (.networkError preserving 401 message) & showError == true
        let sock401 = ScriptedSocket()
        sock401.connectError = NSError(
            domain: "ACPClient.NativeWebSocketError",
            code: 401,
            userInfo: [NSLocalizedDescriptionKey: "Unexpected WebSocket handshake status code: 401"]
        )
        let val401 = BridgeServerValidator(defaults: defaults) { config in
            ACPService(client: ACPClient(configuration: config, socketProvider: SocketQueueProvider([sock401])))
        }
        let res401 = await val401.validate(
            name: "Auth401", scheme: "wss", host: "bridge.example.test", token: "bad",
            workingDirectory: "~", clientName: "Agmente iOS", clientVersion: "0.1.0",
            supportsFSRead: false, supportsFSWrite: false, supportsTerminal: false
        )
        if case .failure(let err) = res401 {
            let vErr = err as? AddServerValidationError
            XCTAssertFalse(vErr?.isIncompatibleBridgeError == true)
            XCTAssertFalse(vErr?.isLocalNetworkPermissionError == true)
            XCTAssertTrue(err.localizedDescription.contains("401"), "SC-AC-023: HTTP 401 description must retain 401, got: \(err.localizedDescription)")
            XCTAssertTrue(AddServerFormValidation.shouldPresentErrorAlert(for: err))
        } else {
            XCTFail("SC-AC-023 [401] expected failure")
        }

        // 4: Connection timeout on non-local host -> .networkError, showError == true
        let sockTimeout = ScriptedSocket()
        sockTimeout.connectError = URLError(.timedOut)
        let valTimeout = BridgeServerValidator(defaults: defaults) { config in
            ACPService(client: ACPClient(configuration: config, socketProvider: SocketQueueProvider([sockTimeout])))
        }
        let resTimeout = await valTimeout.validate(
            name: "Timeout", scheme: "wss", host: "bridge.example.test", token: "tok",
            workingDirectory: "~", clientName: "Agmente iOS", clientVersion: "0.1.0",
            supportsFSRead: false, supportsFSWrite: false, supportsTerminal: false
        )
        if case .failure(let err) = resTimeout {
            let vErr = err as? AddServerValidationError
            XCTAssertFalse(vErr?.isIncompatibleBridgeError == true)
            XCTAssertFalse(vErr?.isLocalNetworkPermissionError == true)
            XCTAssertTrue(AddServerFormValidation.shouldPresentErrorAlert(for: err))
        } else {
            XCTFail("SC-AC-023 [timeout] expected failure")
        }

        // 5: Local network permission error -> .localNetworkPermissionNeeded & form alert suppressed (showError == false)
        let sockLAN = ScriptedSocket()
        sockLAN.connectError = URLError(.cannotConnectToHost)
        let valLAN = BridgeServerValidator(defaults: defaults) { config in
            ACPService(client: ACPClient(configuration: config, socketProvider: SocketQueueProvider([sockLAN])))
        }
        let resLAN = await valLAN.validate(
            name: "LAN", scheme: "ws", host: "192.168.1.50:8765", token: "tok",
            workingDirectory: "~", clientName: "Agmente iOS", clientVersion: "0.1.0",
            supportsFSRead: false, supportsFSWrite: false, supportsTerminal: false
        )
        if case .failure(let err) = resLAN {
            let vErr = err as? AddServerValidationError
            XCTAssertTrue(vErr?.isLocalNetworkPermissionError == true, "SC-AC-023: expected .localNetworkPermissionNeeded, got \(err)")
            XCTAssertFalse(AddServerFormValidation.shouldPresentErrorAlert(for: err), "SC-AC-023: local network error must NOT present alert")
        } else {
            XCTFail("SC-AC-023 [LAN] expected failure")
        }
    }

    // MARK: - SC-AC-024, SC-AC-030, SC-AC-031: Edit skip/revalidation (DEC-30), Token required, Root '/' real-time warning

    func testSCAC024_030_031_FormValidationRootWarningAndEditSkipRules() {
        // SC-AC-030: Token required + whitespace trim
        XCTAssertFalse(AddServerFormValidation.canSave(name: "", host: "127.0.0.1:8765", token: "tok", isSaving: false))
        XCTAssertFalse(AddServerFormValidation.canSave(name: "Mini", host: "   ", token: "tok", isSaving: false))
        XCTAssertFalse(AddServerFormValidation.canSave(name: "Mini", host: "127.0.0.1:8765", token: "", isSaving: false))
        XCTAssertFalse(AddServerFormValidation.canSave(name: "Mini", host: "127.0.0.1:8765", token: "  \n\t ", isSaving: false))
        XCTAssertTrue(AddServerFormValidation.canSave(name: "Mini", host: "127.0.0.1:8765", token: "  valid_tok  ", isSaving: false))
        XCTAssertEqual(AddServerFormValidation.trimmedToken("  valid_tok  "), "valid_tok")

        // SC-AC-031: Real-time '/' root directory warning without disabling Save
        XCTAssertTrue(AddServerFormValidation.shouldShowRootWorkingDirectoryWarning("/"))
        XCTAssertTrue(AddServerFormValidation.shouldShowRootWorkingDirectoryWarning(" / "))
        XCTAssertFalse(AddServerFormValidation.shouldShowRootWorkingDirectoryWarning("~"))
        XCTAssertFalse(AddServerFormValidation.shouldShowRootWorkingDirectoryWarning("/Users/demo"))
        XCTAssertTrue(AddServerFormValidation.canSave(name: "Mini", host: "127.0.0.1:8765", token: "tok", isSaving: false))

        // SC-AC-024: Edit skip vs 3 independent connection-param triggers
        let existing = ACPServerConfiguration(
            id: UUID(),
            name: "S",
            scheme: "ws",
            host: "127.0.0.1:8765",
            token: "tok-abc",
            workingDirectory: "~"
        )
        // ① Unchanged connection params (even with whitespace padding on host/token) -> skip remote validation
        XCTAssertTrue(AddServerView.shouldSkipRemoteValidationOnEdit(
            editingServer: existing,
            scheme: "ws",
            host: "  127.0.0.1:8765  ",
            token: "  tok-abc  "
        ))
        // ② Scheme changed -> must revalidate
        XCTAssertFalse(AddServerView.shouldSkipRemoteValidationOnEdit(
            editingServer: existing,
            scheme: "wss",
            host: "127.0.0.1:8765",
            token: "tok-abc"
        ))
        // ③ Host changed -> must revalidate
        XCTAssertFalse(AddServerView.shouldSkipRemoteValidationOnEdit(
            editingServer: existing,
            scheme: "ws",
            host: "127.0.0.1:9999",
            token: "tok-abc"
        ))
        // ④ trimmedToken changed -> must revalidate
        XCTAssertFalse(AddServerView.shouldSkipRemoteValidationOnEdit(
            editingServer: existing,
            scheme: "ws",
            host: "127.0.0.1:8765",
            token: " tok-new "
        ))

        // Also verify updateServer persists trimmedToken and preserves protocol lockout when only name/cwd change (DEC-30)
        let defaults = makeDefaults("SCAC024")
        let storage = SessionStorage.inMemory()
        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        appVM.addServer(name: "S", scheme: "ws", host: "127.0.0.1:8765", token: "tok-abc", workingDirectory: "~")
        let sid = appVM.servers[0].id
        appVM.connectionPool.markProtocolIncompatible(serverId: sid, message: "Incompatible")
        XCTAssertTrue(appVM.isProtocolIncompatible(for: sid))

        // Name & cwd only edit -> DEC-30 preserves lockout
        appVM.updateServer(sid, with: ValidatedServerConfiguration(
            name: "Renamed",
            scheme: "ws",
            host: "127.0.0.1:8765",
            token: "tok-abc",
            workingDirectory: "/work",
            agentInfo: nil
        ))
        XCTAssertTrue(appVM.isProtocolIncompatible(for: sid), "SC-AC-024/DEC-30: name/cwd-only edit must keep lockout")
        XCTAssertEqual(storage.fetchServers().first?.name, "Renamed")
        XCTAssertEqual(storage.fetchServers().first?.workingDirectory, "/work")

        // Token edit with spaces -> clears lockout & stores trimmedToken
        appVM.updateServer(sid, with: ValidatedServerConfiguration(
            name: "Renamed",
            scheme: "ws",
            host: "127.0.0.1:8765",
            token: " tok-new ",
            workingDirectory: "/work",
            agentInfo: nil
        ))
        XCTAssertFalse(appVM.isProtocolIncompatible(for: sid), "SC-AC-024: token edit must clear lockout")
        XCTAssertEqual(storage.fetchServers().first?.token, "tok-new")
    }

    // MARK: - SC-AC-025: Dual-entry runtime business RPC gating behind nonlocal/sync

    func testSCAC025_DualEntryRuntimeBusinessRPCGatingBehindNonlocalSync() async throws {
        for useAlreadyInitialized in [false, true] {
            let defaults = makeDefaults("SCAC025-\(useAlreadyInitialized)")
            let storage = SessionStorage.inMemory()
            let socket = ScriptedSocket()
            let provider = SocketQueueProvider([socket])

            let appVM = AppViewModel(
                storage: storage,
                defaults: defaults,
                defaultSlotServiceFactory: { config, encoder in
                    let client = ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder)
                    return ACPService(client: client)
                },
                shouldStartNetworkMonitoring: false,
                shouldConnectOnStartup: false
            )
            appVM.addServer(name: "Mini", scheme: "ws", host: "127.0.0.1:18770", token: "tok", workingDirectory: "~")
            let sid = appVM.servers[0].id
            appVM.connectServer(sid)

            try await waitUntil { socket.sentMethods().contains("initialize") }
            let initReq = try XCTUnwrap(socket.sentRequests().first { $0.method == "initialize" })
            if useAlreadyInitialized {
                socket.enqueueError(id: initReq.id, code: -32000, message: "Already initialized")
            } else {
                socket.enqueueResponse(id: initReq.id, result: validInitResult())
            }

            try await waitUntil { socket.sentMethods().contains(NonlocalMethods.sessionSync) }
            try await Task.sleep(nanoseconds: 80_000_000)

            // Before nonlocal/sync resolves: 0 business RPCs allowed!
            let preSyncMethods = socket.sentMethods()
            XCTAssertFalse(preSyncMethods.contains("session/list"), "SC-AC-025: 0 session/list before sync (alreadyInit=\(useAlreadyInitialized))")
            XCTAssertFalse(preSyncMethods.contains(NonlocalMethods.fsList), "SC-AC-025: 0 nonlocal/fs_list before sync")
            XCTAssertFalse(preSyncMethods.contains(NonlocalMethods.usage), "SC-AC-025: 0 nonlocal/usage before sync")

            // Release nonlocal/sync with valid instanceId -> business RPCs fire
            let syncReq = try XCTUnwrap(socket.sentRequests().first { $0.method == NonlocalMethods.sessionSync })
            socket.enqueueResponse(id: syncReq.id, result: .object([
                "instanceId": .string("inst-gate-ok"),
                "materializedSessionIds": .array([]),
                "sessions": .array([])
            ]))

            try await waitUntil {
                let m = socket.sentMethods()
                return m.contains("session/list") && m.contains(NonlocalMethods.fsList) && m.contains(NonlocalMethods.usage)
            }
            appVM.disconnect(serverId: sid)
        }
    }

    // MARK: - SC-AC-071: Pre-sync initialize phase (5 rejects + 1 positive "already initialized")

    func testSCAC071_PreSyncInitializePhaseFiveRejectsAndAlreadyInitPositive() async throws {
        enum InitOutcome {
            case emptyObject
            case codexUA
            case rpcError(Int)
        }
        let rejects: [(String, InitOutcome)] = [
            ("empty {}", .emptyObject),
            ("codex UA", .codexUA),
            ("-32601", .rpcError(-32601)),
            ("-32600", .rpcError(-32600)),
            ("-32602", .rpcError(-32602)),
        ]

        for (label, outcome) in rejects {
            let defaults = makeDefaults("SCAC071-\(label)")
            let storage = SessionStorage.inMemory()
            let socket = ScriptedSocket()
            let provider = SocketQueueProvider([socket])

            let appVM = AppViewModel(
                storage: storage,
                defaults: defaults,
                defaultSlotServiceFactory: { config, encoder in
                    ACPService(client: ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder))
                },
                shouldStartNetworkMonitoring: false,
                shouldConnectOnStartup: false
            )
            appVM.devModeEnabled = false
            appVM.addServer(name: "NonBridge-\(label)", scheme: "ws", host: "127.0.0.1:18771", token: "tok", workingDirectory: "~")
            let sid = appVM.servers[0].id
            appVM.connectServer(sid)

            try await waitUntil { socket.sentMethods().contains("initialize") }
            let initReq = try XCTUnwrap(socket.sentRequests().first { $0.method == "initialize" })
            switch outcome {
            case .emptyObject:
                socket.enqueueResponse(id: initReq.id, result: .object([:]))
            case .codexUA:
                socket.enqueueResponse(id: initReq.id, result: .object(["userAgent": .string("codex/1.0")]))
            case .rpcError(let code):
                socket.enqueueError(id: initReq.id, code: code, message: "Protocol err \(code)")
            }

            try await waitUntil {
                appVM.isProtocolIncompatible(for: sid) && appVM.connectionState(for: sid) == .disconnected
            }

            XCTAssertFalse(socket.sentMethods().contains(NonlocalMethods.sessionSync), "SC-AC-071 [\(label)]: 0 nonlocal/sync")
            XCTAssertFalse(socket.sentMethods().contains("session/list"), "SC-AC-071 [\(label)]: 0 session/list")
            XCTAssertFalse(socket.sentMethods().contains(NonlocalMethods.fsList), "SC-AC-071 [\(label)]: 0 nonlocal/fs_list")
            XCTAssertFalse(socket.sentMethods().contains(NonlocalMethods.usage), "SC-AC-071 [\(label)]: 0 nonlocal/usage")
            XCTAssertFalse(appVM.wasPreempted(for: sid), "SC-AC-071 [\(label)]: wasPreempted must be false")
            XCTAssertEqual(appVM.protocolIncompatibleServersInCurrentMode.map(\.id), [sid])
            XCTAssertTrue(appVM.preemptedServersInCurrentMode.isEmpty)
        }

        // Positive control: "already initialized" does NOT lock and proceeds to nonlocal/sync
        let defaults = makeDefaults("SCAC071-pos")
        let storage = SessionStorage.inMemory()
        let posSocket = ScriptedSocket()
        let posProvider = SocketQueueProvider([posSocket])
        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            defaultSlotServiceFactory: { config, encoder in
                ACPService(client: ACPClient(configuration: config, socketProvider: posProvider, logger: NoOpLogger(), encoder: encoder))
            },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        appVM.addServer(name: "AlreadyInit", scheme: "ws", host: "127.0.0.1:18772", token: "tok", workingDirectory: "~")
        let sid = appVM.servers[0].id
        appVM.connectServer(sid)

        try await waitUntil { posSocket.sentMethods().contains("initialize") }
        let initReq = try XCTUnwrap(posSocket.sentRequests().first { $0.method == "initialize" })
        posSocket.enqueueError(id: initReq.id, code: -32600, message: "Already initialized")

        try await waitUntil { posSocket.sentMethods().contains(NonlocalMethods.sessionSync) }
        XCTAssertFalse(appVM.isProtocolIncompatible(for: sid))
        appVM.disconnect(serverId: sid)
    }

    // MARK: - SC-AC-026: First-round nonlocal/sync 6 rejects drop 4 buffers, never markNonlocalSyncCompleted, 0 business RPCs

    func testSCAC026_NonlocalSyncSixRejectsDropFourBuffersAndLockout() async throws {
        enum SyncFail {
            case rpcError(Int)
            case result(ACP.Value)
        }
        let cases: [(String, Bool, SyncFail)] = [
            ("-32601", false, .rpcError(-32601)),
            ("-32600", false, .rpcError(-32600)),
            ("-32602", false, .rpcError(-32602)),
            ("empty {}", false, .result(.object([:]))),
            ("empty instanceId", false, .result(.object(["instanceId": .string("")]))),
            ("whitespace instanceId (via alreadyInit)", true, .result(.object(["instanceId": .string("   ")]))),
        ]

        for (label, viaAlreadyInit, outcome) in cases {
            let defaults = makeDefaults("SCAC026-\(label)")
            let storage = SessionStorage.inMemory()
            let socket = ScriptedSocket()
            let provider = SocketQueueProvider([socket])

            let appVM = AppViewModel(
                storage: storage,
                defaults: defaults,
                defaultSlotServiceFactory: { config, encoder in
                    ACPService(client: ACPClient(configuration: config, socketProvider: provider, logger: NoOpLogger(), encoder: encoder))
                },
                shouldStartNetworkMonitoring: false,
                shouldConnectOnStartup: false
            )
            appVM.devModeEnabled = false
            appVM.addServer(name: "SyncBad-\(label)", scheme: "ws", host: "127.0.0.1:18773", token: "tok", workingDirectory: "~")
            let sid = appVM.servers[0].id
            let serverVM = try XCTUnwrap(appVM.serverViewModels[sid])
            appVM.connectServer(sid)

            try await waitUntil { socket.sentMethods().contains("initialize") }
            let initReq = try XCTUnwrap(socket.sentRequests().first { $0.method == "initialize" })
            if viaAlreadyInit {
                socket.enqueueError(id: initReq.id, code: -32000, message: "Already initialized")
            } else {
                socket.enqueueResponse(id: initReq.id, result: validInitResult())
            }

            try await waitUntil { socket.sentMethods().contains(NonlocalMethods.sessionSync) && appVM.isSyncingByServer[sid] == true }

            // Populate all 4 buffers while sync barrier is active
            appVM.syncCoordinator.bufferedLiveUpdatesDuringSync[sid] = [.object(["sessionId": .string("S1")])]
            appVM.syncCoordinator.bufferedTurnCompletedDuringSync[sid] = [
                NonlocalTurnCompletedNotification(instanceId: "x", sessionId: "S1", turnId: "t1", status: .completed)
            ]
            appVM.syncCoordinator.bufferedSessionStaleDuringSync[sid] = [
                NonlocalSessionStaleNotification(instanceId: "x", sessionId: "S1", updatedAt: nil)
            ]
            appVM.syncCoordinator.bufferedSessionDeletedDuringSync[sid] = [
                NonlocalSessionDeletedNotification(instanceId: "x", sessionId: "S1")
            ]

            let syncReq = try XCTUnwrap(socket.sentRequests().first { $0.method == NonlocalMethods.sessionSync })
            switch outcome {
            case .rpcError(let code):
                socket.enqueueError(id: syncReq.id, code: code, message: "Not supported \(code)")
            case .result(let val):
                socket.enqueueResponse(id: syncReq.id, result: val)
            }

            try await waitUntil {
                appVM.isProtocolIncompatible(for: sid) && appVM.connectionState(for: sid) == .disconnected
            }

            // 1. All 4 buffers dropped, never marked synced, 0 business RPCs
            XCTAssertTrue(appVM.syncCoordinator.bufferedLiveUpdatesDuringSync[sid]?.isEmpty ?? true, "SC-AC-026 [\(label)]: liveUpdates buffer must be dropped")
            XCTAssertTrue(appVM.syncCoordinator.bufferedTurnCompletedDuringSync[sid]?.isEmpty ?? true, "SC-AC-026 [\(label)]: turnCompleted buffer must be dropped")
            XCTAssertTrue(appVM.syncCoordinator.bufferedSessionStaleDuringSync[sid]?.isEmpty ?? true, "SC-AC-026 [\(label)]: sessionStale buffer must be dropped")
            XCTAssertTrue(appVM.syncCoordinator.bufferedSessionDeletedDuringSync[sid]?.isEmpty ?? true, "SC-AC-026 [\(label)]: sessionDeleted buffer must be dropped")
            XCTAssertFalse(serverVM.hasCompletedNonlocalSync, "SC-AC-026 [\(label)]: must NEVER call markNonlocalSyncCompleted()")
            XCTAssertFalse(socket.sentMethods().contains("session/list"))
            XCTAssertFalse(socket.sentMethods().contains(NonlocalMethods.fsList))
            XCTAssertFalse(socket.sentMethods().contains(NonlocalMethods.usage))

            // 2. Lockout state isolated from 4001 & banner ready even with devModeEnabled == false
            XCTAssertFalse(appVM.wasPreempted(for: sid))
            XCTAssertEqual(appVM.protocolIncompatibleServersInCurrentMode.map(\.id), [sid])
            XCTAssertTrue(appVM.preemptedServersInCurrentMode.isEmpty)
        }
    }

    // MARK: - SC-AC-027 & SC-AC-028: 5-path lockout + healthy server control + manual unlock/re-lock/DEC-30/edit-unlock

    func testSCAC027_028_FivePathLockoutAndManualUnlockLifecycle() async throws {
        let defaults = makeDefaults("SCAC027_028")
        let storage = SessionStorage.inMemory()

        var serverADials = 0
        var serverBDials = 0
        var serverBHealthy = false

        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            defaultSlotServiceFactory: { config, encoder in
                let isA = config.endpoint.port == 18781
                let sock = ScriptedSocket()
                sock.onSend = { text, s in
                    guard let data = text.data(using: .utf8),
                          let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                          case .request(let req) = wire else { return }
                    if req.method == "initialize" {
                        s.enqueueResponse(id: req.id, result: self.validInitResult())
                    } else if req.method == NonlocalMethods.sessionSync {
                        if isA || serverBHealthy {
                            s.enqueueResponse(id: req.id, result: .object(["instanceId": .string(isA ? "inst-A" : "inst-B-ok")]))
                        } else {
                            s.enqueueError(id: req.id, code: -32601, message: "Method not found")
                        }
                    }
                }
                if isA { serverADials += 1 } else { serverBDials += 1 }
                return ACPService(client: ACPClient(configuration: config, socketProvider: SocketQueueProvider([sock]), logger: NoOpLogger(), encoder: encoder))
            },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )

        appVM.addServer(name: "HealthyA", scheme: "ws", host: "127.0.0.1:18781", token: "tokA", workingDirectory: "~")
        appVM.addServer(name: "BadB", scheme: "ws", host: "127.0.0.1:18782", token: "tokB", workingDirectory: "~")
        let idA = appVM.servers[0].id
        let idB = appVM.servers[1].id
        appVM.selectServer(idA)
        // Lower reconnectBaseDelay so waiting 0.25s strictly exceeds > 2x reconnectBaseDelay (0.08s) for Path 1!
        appVM.connectionSlot(for: idB).connectionManager.reconnectBaseDelay = 0.04

        // Connect both -> A succeeds (clearing isInitialAppLaunch), B locks out
        appVM.connectAllServers()
        try await waitUntil {
            appVM.connectionState(for: idA) == .connected
                && !appVM.isInitialAppLaunch
                && appVM.isProtocolIncompatible(for: idB)
                && appVM.connectionState(for: idB) == .disconnected
        }
        let baselineBDials = serverBDials
        XCTAssertEqual(baselineBDials, 1)

        // SC-AC-027: Trigger ALL 5 auto-connect paths
        // Path 1: Wait > 6x reconnectBaseDelay (0.25s >> 2 * 0.04s)
        try await Task.sleep(nanoseconds: 250_000_000)
        // Path 2: Network availability recovery
        appVM.connectionPool.resumeAllEligibleOnNetworkRecovery(servers: appVM.servers)
        try await Task.sleep(nanoseconds: 80_000_000)
        // Path 3: ScenePhase .background -> .inactive -> .active
        appVM.handleScenePhaseChanged(.background)
        appVM.handleScenePhaseChanged(.inactive)
        appVM.handleScenePhaseChanged(.active)
        try await waitUntil { appVM.connectionState(for: idA) == .connected }
        // Path 4: SessionListPage.onAppear gate on selected Server B (confirm isInitialAppLaunch == false so only lockout blocks it!)
        XCTAssertFalse(appVM.isInitialAppLaunch, "SC-AC-027 Path 4 precondition: isInitialAppLaunch must be false")
        appVM.selectServer(idB)
        XCTAssertFalse(appVM.shouldAutoConnectOnSessionListAppear, "SC-AC-027 Path 4: must block auto-connect on locked B")
        // Path 5: connectAllServers()
        appVM.connectAllServers()
        try await Task.sleep(nanoseconds: 80_000_000)

        XCTAssertEqual(serverBDials, baselineBDials, "SC-AC-027: ServerB must have 0 new dials across all 5 auto paths")
        XCTAssertTrue(appVM.isProtocolIncompatible(for: idB))
        XCTAssertEqual(appVM.connectionState(for: idA), .connected, "SC-AC-027: Healthy ServerA must remain connected")

        // SC-AC-028 ①: Explicit manual reconnect while still non-bridge -> dials exactly once and re-locks
        appVM.connectServer(idB)
        try await waitUntil { serverBDials == baselineBDials + 1 && appVM.isProtocolIncompatible(for: idB) && appVM.connectionState(for: idB) == .disconnected }
        XCTAssertEqual(serverBDials, baselineBDials + 1)

        // SC-AC-028 ③: DEC-30 name/cwd-only edit keeps lock & banner, 5 paths still blocked
        appVM.updateServer(idB, with: ValidatedServerConfiguration(
            name: "BadB-Renamed", scheme: "ws", host: "127.0.0.1:18782", token: "tokB", workingDirectory: "/other", agentInfo: nil
        ))
        XCTAssertTrue(appVM.isProtocolIncompatible(for: idB))
        appVM.connectAllServers()
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(serverBDials, baselineBDials + 1, "SC-AC-028/DEC-30: still blocked after name-only edit")

        // SC-AC-028 ②: Switch peer B to healthy bridge + manual reconnect -> unlocks & clears red banner
        serverBHealthy = true
        appVM.connectServer(idB)
        try await waitUntil { appVM.connectionState(for: idB) == .connected && !appVM.isProtocolIncompatible(for: idB) }
        XCTAssertTrue(appVM.protocolIncompatibleServersInCurrentMode.isEmpty)

        // Re-lock B, then SC-AC-028 ④: edit connection param (host) -> clears lock & reconnects cleanly
        appVM.connectionPool.markProtocolIncompatible(serverId: idB, message: "Locked again")
        XCTAssertTrue(appVM.isProtocolIncompatible(for: idB))
        appVM.updateServer(idB, with: ValidatedServerConfiguration(
            name: "BadB-Fixed", scheme: "ws", host: "127.0.0.1:18783", token: "tokB2", workingDirectory: "/other", agentInfo: nil
        ))
        try await waitUntil { appVM.connectionState(for: idB) == .connected && !appVM.isProtocolIncompatible(for: idB) }
        XCTAssertTrue(appVM.protocolIncompatibleServersInCurrentMode.isEmpty)

        appVM.disconnect(serverId: idA)
        appVM.disconnect(serverId: idB)
    }

    // MARK: - SC-AC-029: Non-protocol runtime faults (-32000/-32603/401/1006) vs 4001 isolation

    func testSCAC029_NonProtocolRuntimeFaultsContinueReconnectAndIsolateFrom4001() async throws {
        let defaults = makeDefaults("SCAC029")
        let storage = SessionStorage.inMemory()

        // 1. -32000 & -32603 on initialize must NOT trigger protocol lockout and must keep backoff auto-reconnect alive
        for code in [-32000, -32603] {
            var transientDials = 0
            var firstSock: ScriptedSocket?
            let appVM = AppViewModel(
                storage: storage,
                defaults: defaults,
                defaultSlotServiceFactory: { config, encoder in
                    transientDials += 1
                    let s = ScriptedSocket()
                    if transientDials == 1 { firstSock = s }
                    return ACPService(client: ACPClient(configuration: config, socketProvider: SocketQueueProvider([s]), logger: NoOpLogger(), encoder: encoder))
                },
                shouldStartNetworkMonitoring: false,
                shouldConnectOnStartup: false
            )
            appVM.addServer(name: "T-\(code)", scheme: "ws", host: "127.0.0.1:18784", token: "tok", workingDirectory: "~")
            let sid = appVM.servers.last!.id
            appVM.connectionSlot(for: sid).connectionManager.reconnectBaseDelay = 0.04
            appVM.connectServer(sid)
            try await waitUntil { firstSock?.sentMethods().contains("initialize") == true }
            let sock = try XCTUnwrap(firstSock)
            let initReq = try XCTUnwrap(sock.sentRequests().first { $0.method == "initialize" })
            sock.enqueueError(id: initReq.id, code: code, message: "Transient \(code)")
            try await Task.sleep(nanoseconds: 80_000_000)
            XCTAssertFalse(appVM.isProtocolIncompatible(for: sid), "SC-AC-029 [\(code)] must NOT enter protocol lockout")
            XCTAssertTrue(appVM.protocolIncompatibleServersInCurrentMode.isEmpty)
            // Verify normal transport close after transient RPC error still triggers backoff auto-reconnect!
            sock.push(.closed(WebSocketCloseReason(code: 1006, reason: "transient_drop")))
            try await waitUntil { transientDials >= 2 && appVM.connectionState(for: sid) == .connected }
            XCTAssertFalse(appVM.isProtocolIncompatible(for: sid))
            appVM.disconnect(serverId: sid)
        }

        // 2. HTTP 401 & 1006 keep backoff auto-reconnect (never locked), while 4001 sets wasPreempted orange banner only
        var dialCount401 = 0
        let fastManager401 = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                dialCount401 += 1
                let sock = ScriptedSocket()
                sock.connectError = NSError(
                    domain: "ACPClient.NativeWebSocketError",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "Unexpected WebSocket handshake status code: 401"]
                )
                return ACPService(client: ACPClient(configuration: config, socketProvider: SocketQueueProvider([sock]), logger: NoOpLogger(), encoder: encoder))
            }
        )
        fastManager401.reconnectBaseDelay = 0.04
        fastManager401.maxReconnectAttempts = 3
        let app401 = AppViewModel(
            storage: SessionStorage.inMemory(),
            defaults: defaults,
            connectionManagerFactory: { _ in fastManager401 },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        app401.addServer(name: "S401", scheme: "ws", host: "127.0.0.1:18785", token: "bad", workingDirectory: "~")
        let id401 = app401.servers[0].id
        app401.connectServer(id401)
        try await waitUntil { dialCount401 >= 2 }
        XCTAssertFalse(app401.isProtocolIncompatible(for: id401), "SC-AC-029: HTTP 401 must NOT lock protocol")
        XCTAssertTrue(app401.protocolIncompatibleServersInCurrentMode.isEmpty)
        app401.disconnect(serverId: id401)

        // 3. 1006 reconnects vs 4001 sets orange banner only (not protocol lock)
        var dials1006 = 0
        var activeSock1006: ScriptedSocket?
        let fastManager1006 = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { config, encoder in
                dials1006 += 1
                let s = ScriptedSocket()
                activeSock1006 = s
                return ACPService(client: ACPClient(configuration: config, socketProvider: SocketQueueProvider([s]), logger: NoOpLogger(), encoder: encoder))
            }
        )
        fastManager1006.reconnectBaseDelay = 0.04
        let app1006 = AppViewModel(
            storage: SessionStorage.inMemory(),
            defaults: defaults,
            connectionManagerFactory: { _ in fastManager1006 },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        app1006.addServer(name: "S1006", scheme: "ws", host: "127.0.0.1:18786", token: "tok", workingDirectory: "~")
        let id1006 = app1006.servers[0].id
        app1006.connectServer(id1006)
        try await waitUntil { app1006.connectionState(for: id1006) == .connected }
        activeSock1006?.push(.closed(WebSocketCloseReason(code: 1006, reason: "abnormal")))
        try await waitUntil { dials1006 >= 2 && app1006.connectionState(for: id1006) == .connected }
        XCTAssertFalse(app1006.isProtocolIncompatible(for: id1006))

        // Now close with 4001 -> wasPreempted == true, orange banner only, isProtocolIncompatible == false, AND stops auto-reconnect (> 4x reconnectBaseDelay)
        let dialsBefore4001 = dials1006
        activeSock1006?.push(.closed(WebSocketCloseReason(code: 4001, reason: "preempted")))
        try await waitUntil { app1006.wasPreempted(for: id1006) && app1006.connectionState(for: id1006) == .disconnected }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(dials1006, dialsBefore4001, "SC-AC-029: 4001 close must stop auto-reconnect for > 2x reconnectBaseDelay")
        XCTAssertFalse(app1006.isProtocolIncompatible(for: id1006))
        XCTAssertEqual(app1006.preemptedServersInCurrentMode.map(\.id), [id1006])
        XCTAssertTrue(app1006.protocolIncompatibleServersInCurrentMode.isEmpty)
        app1006.disconnect(serverId: id1006)
    }

    // MARK: - SC-AC-041 (PP-SYNC-ORDER): 4-buffer out-of-order injection + exact 4-step replay order

    func testSCAC041_FourBufferOutOfOrderInjectionAndExactFourStepReplayOrder() async throws {
        let defaults = makeDefaults("SCAC041")
        let storage = SessionStorage.inMemory()

        var syncRequest: ACP.AnyRequest?
        let sock = ScriptedSocket()
        sock.onSend = { text, s in
            guard let data = text.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                  case .request(let req) = wire else { return }
            if req.method == "initialize" {
                s.enqueueResponse(id: req.id, result: self.validInitResult())
            } else if req.method == NonlocalMethods.sessionSync {
                // Hold nonlocal/sync open until we inject all 4 buffered event streams out-of-order!
                syncRequest = req
            }
        }

        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            defaultSlotServiceFactory: { config, encoder in
                ACPService(client: ACPClient(configuration: config, socketProvider: SocketQueueProvider([sock]), logger: NoOpLogger(), encoder: encoder))
            },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        appVM.addServer(name: "SyncOrder", scheme: "ws", host: "127.0.0.1:18799", token: "tok", workingDirectory: "/work")
        let sid = appVM.servers[0].id
        storage.saveSession(StoredSessionInfo(sessionId: "S-live", title: "Live", cwd: "/work", updatedAt: Date()), forServerId: sid)
        storage.saveSession(StoredSessionInfo(sessionId: "S-del", title: "ToDelete", cwd: "/work", updatedAt: Date()), forServerId: sid)
        let serverVM = try XCTUnwrap(appVM.serverViewModels[sid])
        serverVM.loadCachedSessions()

        // Instrument exact replay order across all 4 buffers + sync completion hook
        var replayOrder: [String] = []
        let origDelete = appVM.syncCoordinator.onApplyImmediateSessionDeletion
        appVM.syncCoordinator.onApplyImmediateSessionDeletion = { sessionId, srvId in
            replayOrder.append("sessionDeleted:\(sessionId)")
            origDelete(sessionId, srvId)
        }
        let origSucceeded = appVM.syncCoordinator.onSyncSucceeded
        appVM.syncCoordinator.onSyncSucceeded = { srvId, svc in
            replayOrder.append("onSyncSucceeded")
            origSucceeded(srvId, svc)
        }

        appVM.connectServer(sid)
        try await waitUntil("sync in flight") { syncRequest != nil && appVM.isSyncingByServer[sid] == true }

        // Inject all 4 event types OUT OF ORDER while sync barrier is active:
        // 1) session_deleted, 2) session_stale, 3) turn_completed, 4) live session/update
        let delNotif = ACPWireMessage.notification(.init(
            method: NonlocalMethods.sessionDeleted,
            params: .object(["instanceId": .string("inst-ord"), "sessionId": .string("S-del")])
        ))
        let staleNotif = ACPWireMessage.notification(.init(
            method: NonlocalMethods.sessionStale,
            params: .object(["instanceId": .string("inst-ord"), "sessionId": .string("S-live"), "reason": .string("external_update")])
        ))
        let turnDoneNotif = ACPWireMessage.notification(.init(
            method: NonlocalMethods.turnCompleted,
            params: .object([
                "instanceId": .string("inst-ord"),
                "sessionId": .string("S-live"),
                "turnId": .string("turn-1"),
                "status": .string("completed"),
                "stopReason": .string("end_turn"),
            ])
        ))
        let liveUpdateNotif = ACPWireMessage.notification(.init(
            method: "session/update",
            params: .object([
                "sessionId": .string("S-live"),
                "_meta": .object([
                    NonlocalMethods.turnIdMetaKey: .string("turn-1"),
                    NonlocalMethods.seqMetaKey: .int(2),
                ]),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("BUFFERED_CHUNK")]),
                ]),
            ])
        ))

        // Inject all 4 event types OUT OF ORDER while sync barrier is active, plus a duplicate/regressed seq (seq=1 & dup seq=2):
        // 1) session_deleted, 2) session_stale, 3) turn_completed, 4) live session/update (seq=2, dup seq=2, regressed seq=1)
        let regressedSeqNotif = ACPWireMessage.notification(.init(
            method: "session/update",
            params: .object([
                "sessionId": .string("S-live"),
                "_meta": .object([
                    NonlocalMethods.turnIdMetaKey: .string("turn-1"),
                    NonlocalMethods.seqMetaKey: .int(1),
                ]),
                "update": .object([
                    "sessionUpdate": .string("agent_message_chunk"),
                    "content": .object(["type": .string("text"), "text": .string("SYNC_CHUNK_")]),
                ]),
            ])
        ))

        for wire in [delNotif, staleNotif, turnDoneNotif, liveUpdateNotif, liveUpdateNotif, regressedSeqNotif] {
            let data = try JSONEncoder().encode(wire)
            sock.push(.text(String(decoding: data, as: UTF8.self)))
        }

        try await waitUntil("all 4 buffers populated") {
            (appVM.syncCoordinator.bufferedLiveUpdatesDuringSync[sid]?.count ?? 0) == 3
                && (appVM.syncCoordinator.bufferedTurnCompletedDuringSync[sid]?.count ?? 0) == 1
                && (appVM.syncCoordinator.bufferedSessionStaleDuringSync[sid]?.count ?? 0) == 1
                && (appVM.syncCoordinator.bufferedSessionDeletedDuringSync[sid]?.count ?? 0) == 1
        }

        // Pre-release assertions: ZERO premature UI/session mutations while barrier is active!
        XCTAssertTrue(serverVM.sessionSummaries.contains { $0.id == "S-del" }, "SC-AC-041: S-del must NOT be deleted before sync barrier closes")
        XCTAssertFalse(serverVM.hasCompletedNonlocalSync, "SC-AC-041: hasCompletedNonlocalSync must remain false before barrier closes")
        XCTAssertFalse(
            serverVM.sessionViewModel(for: "S-live").chatMessages.contains { $0.content.contains("BUFFERED_CHUNK") },
            "SC-AC-041: liveUpdate must NOT mutate chat before sync barrier closes"
        )
        XCTAssertEqual(sock.sentMethods().filter { $0 == "session/list" }.count, 0, "SC-AC-041: 0 business RPCs before barrier closes")

        // Release nonlocal/sync with active turn seq=1 + valid instanceId
        let req = try XCTUnwrap(syncRequest)
        sock.enqueueResponse(id: req.id, result: .object([
            "instanceId": .string("inst-ord"),
            "materializedSessionIds": .array([.string("S-live")]),
            "sessions": .array([
                .object([
                    "sessionId": .string("S-live"),
                    "latestTurn": .object([
                        "turnId": .string("turn-1"),
                        "status": .string("active"),
                        "lastSeq": .int(1),
                        "events": .array([
                            .object([
                                "seq": .int(1),
                                "method": .string("session/update"),
                                "params": .object([
                                    "sessionId": .string("S-live"),
                                    "update": .object([
                                        "sessionUpdate": .string("agent_message_chunk"),
                                        "content": .object(["type": .string("text"), "text": .string("SYNC_CHUNK_")]),
                                    ]),
                                ]),
                            ]),
                        ]),
                    ]),
                ]),
            ]),
        ]))

        try await waitUntil("sync barrier completed & replayed") {
            appVM.isSyncingByServer[sid] != true
                && serverVM.hasCompletedNonlocalSync
                && sock.sentMethods().contains("session/list")
        }

        // Post-release assertions:
        // 1) All 4 buffers drained
        XCTAssertTrue(appVM.syncCoordinator.bufferedLiveUpdatesDuringSync[sid]?.isEmpty ?? true)
        XCTAssertTrue(appVM.syncCoordinator.bufferedTurnCompletedDuringSync[sid]?.isEmpty ?? true)
        XCTAssertTrue(appVM.syncCoordinator.bufferedSessionStaleDuringSync[sid]?.isEmpty ?? true)
        XCTAssertTrue(appVM.syncCoordinator.bufferedSessionDeletedDuringSync[sid]?.isEmpty ?? true)
        // 2) Step 1 (liveUpdates) applied after reconcileSyncResult -> combined "SYNC_CHUNK_BUFFERED_CHUNK"
        let liveText = serverVM.sessionViewModel(for: "S-live").chatMessages.map(\.content).joined()
        XCTAssertTrue(liveText.contains("SYNC_CHUNK_"), "SC-AC-041: sync snapshot event must be applied, got '\(liveText)'")
        XCTAssertTrue(liveText.contains("BUFFERED_CHUNK"), "SC-AC-041: buffered liveUpdate (seq=2) must replay after sync snapshot, got '\(liveText)'")
        // 3) Step 2 (turnCompleted) cleared streaming after liveUpdate
        XCTAssertFalse(serverVM.sessionViewModel(for: "S-live").isStreaming, "SC-AC-041: buffered turnCompleted must settle streaming after liveUpdates")
        // 4) Step 4 (sessionDeleted) ran BEFORE onSyncSucceeded (business RPC release)
        XCTAssertFalse(serverVM.sessionSummaries.contains { $0.id == "S-del" }, "SC-AC-041: buffered sessionDeleted must remove S-del")
        XCTAssertEqual(replayOrder, ["sessionDeleted:S-del", "onSyncSucceeded"], "SC-AC-041: sessionDeleted replay must precede onSyncSucceeded/business RPC release")

        // 5) Duplicate seq=2 and regressed seq=1 during replay were idempotently skipped (each chunk appears strictly once!)
        XCTAssertEqual(liveText.components(separatedBy: "SYNC_CHUNK_").count - 1, 1, "SC-AC-041: regressed seq=1 must not duplicate SYNC_CHUNK_")
        XCTAssertEqual(liveText.components(separatedBy: "BUFFERED_CHUNK").count - 1, 1, "SC-AC-041: duplicate seq=2 must not duplicate BUFFERED_CHUNK")

        appVM.disconnect(serverId: sid)
    }

    // MARK: - SC-AC-040: 5-server network recovery with half-open .connected ping() health check

    func testSCAC040_FiveServerNetworkRecoveryAndHalfOpenPingProbe() async throws {
        let defaults = makeDefaults("SCAC040")
        let storage = SessionStorage.inMemory()

        var dialsByPort: [Int: Int] = [:]
        var socketsByPort: [Int: [ScriptedSocket]] = [:]

        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            defaultSlotServiceFactory: { config, encoder in
                let port = config.endpoint.port ?? 0
                dialsByPort[port, default: 0] += 1
                let sock = ScriptedSocket()
                sock.onSend = { text, s in
                    guard let data = text.data(using: .utf8),
                          let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                          case .request(let req) = wire else { return }
                    if req.method == "initialize" {
                        s.enqueueResponse(id: req.id, result: self.validInitResult())
                    } else if req.method == NonlocalMethods.sessionSync {
                        s.enqueueResponse(id: req.id, result: .object(["instanceId": .string("inst-\(port)")]))
                    }
                }
                socketsByPort[port, default: []].append(sock)
                return ACPService(client: ACPClient(configuration: config, socketProvider: SocketQueueProvider([sock]), logger: NoOpLogger(), encoder: encoder))
            },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )

        // S1: selected, disconnected normally; S2: unselected, half-open .connected (ping fails);
        // S3: manually disconnected; S4: 4001 preempted; S5: protocol-locked
        appVM.addServer(name: "S1", scheme: "ws", host: "127.0.0.1:18791", token: "t1", workingDirectory: "~")
        appVM.addServer(name: "S2", scheme: "ws", host: "127.0.0.1:18792", token: "t2", workingDirectory: "~")
        appVM.addServer(name: "S3", scheme: "ws", host: "127.0.0.1:18793", token: "t3", workingDirectory: "~")
        appVM.addServer(name: "S4", scheme: "ws", host: "127.0.0.1:18794", token: "t4", workingDirectory: "~")
        appVM.addServer(name: "S5", scheme: "ws", host: "127.0.0.1:18795", token: "t5", workingDirectory: "~")
        let s1 = appVM.servers[0].id
        let s2 = appVM.servers[1].id
        let s3 = appVM.servers[2].id
        let s4 = appVM.servers[3].id
        let s5 = appVM.servers[4].id
        appVM.selectServer(s1)

        // Setup initial states: let S2 and S4 finish initial connect cleanly first.
        appVM.connectServer(s2)
        appVM.connectServer(s4)
        try await waitUntil("s2+s4 connected (s2=\(appVM.connectionState(for: s2)), s4=\(appVM.connectionState(for: s4)), dials=\(dialsByPort))") {
            appVM.connectionState(for: s2) == .connected && appVM.connectionState(for: s4) == .connected
        }

        // Now turn S2's already-connected socket into a half-open dead socket whose health-check ping() fails!
        let s2FirstSocket = try XCTUnwrap(socketsByPort[18792]?.first)
        let s2PingsBefore = s2FirstSocket.pingCount
        s2FirstSocket.pingError = URLError(.timedOut)

        appVM.disconnect(serverId: s3) // manual disconnect
        socketsByPort[18794]?.first?.push(.closed(WebSocketCloseReason(code: 4001, reason: "preempted")))
        try await waitUntil("s4 preempted (sockets=\(socketsByPort[18794]?.count ?? 0), state=\(appVM.connectionState(for: s4)))") { appVM.wasPreempted(for: s4) }
        appVM.connectionPool.markProtocolIncompatible(serverId: s5, message: "Incompatible")

        let s3Before = dialsByPort[18793] ?? 0
        let s4Before = dialsByPort[18794] ?? 0
        let s5Before = dialsByPort[18795] ?? 0

        // Trigger network availability recovery (Wi-Fi -> 5G)
        appVM.slotManager(appVM.connectionSlot(for: s1).connectionManager, serverId: s1, didChangeNetworkAvailability: true)

        try await waitUntil(timeout: 3.0, "s1+s2 recovered (s1=\(appVM.connectionState(for: s1)), s2=\(appVM.connectionState(for: s2)), dials=\(dialsByPort), pings=\(s2FirstSocket.pingCount))") {
            appVM.connectionState(for: s1) == .connected
                && (dialsByPort[18792] ?? 0) >= 2
                && appVM.connectionState(for: s2) == .connected
        }

        // Verify S1 & S2 recovered (and S2's first socket was probed by ping()), while S3/S4/S5 had 0 new dials
        XCTAssertEqual(appVM.connectionState(for: s1), .connected, "SC-AC-040: S1 must reconnect")
        XCTAssertEqual(dialsByPort[18792], 2, "SC-AC-040: S2 must reconnect once after failed ping(), got \(dialsByPort)")
        XCTAssertEqual(appVM.connectionState(for: s2), .connected, "SC-AC-040: S2 must be connected after health recovery")
        XCTAssertGreaterThan(s2FirstSocket.pingCount, s2PingsBefore, "SC-AC-040: half-open S2 must run verifyConnectionHealth ping()")
        XCTAssertEqual(dialsByPort[18793] ?? 0, s3Before, "SC-AC-040: S3 manual disconnect -> 0 new dials")
        XCTAssertEqual(dialsByPort[18794] ?? 0, s4Before, "SC-AC-040: S4 4001 preempted -> 0 new dials")
        XCTAssertEqual(dialsByPort[18795] ?? 0, s5Before, "SC-AC-040: S5 protocol locked -> 0 new dials")

        for id in [s1, s2, s3, s4, s5] { appVM.disconnect(serverId: id) }
    }

    // MARK: - SC-AC-042: QuotaManager DEC-27 multi-server push ingestion, wrong-binding rejection & cross-server timer migration

    func testSCAC042_QuotaManagerMultiServerPushAndTimerMigration() async throws {
        let defaults = makeDefaults("SCAC042")
        let storage = SessionStorage.inMemory()
        let start = QuotaUsageMerger.parseISO8601("2026-11-22T10:00:00Z")!
        let clock = TestQuotaClock(start: start)

        var usageRequestsA = 0
        var usageRequestsB = 0

        let sockA = ScriptedSocket()
        sockA.onSend = { text, s in
            guard let data = text.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                  case .request(let req) = wire,
                  req.method == NonlocalMethods.usage else { return }
            usageRequestsA += 1
            s.enqueueResponse(id: req.id, result: .object([
                "fetchedAt": .string(ISO8601DateFormatter().string(from: clock.now())),
                "ageSeconds": .int(0),
                "ttlSeconds": .int(180),
                "refreshing": .bool(false),
                "groups": .array([])
            ]))
        }

        let sockB = ScriptedSocket()
        sockB.onSend = { text, s in
            guard let data = text.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                  case .request(let req) = wire,
                  req.method == NonlocalMethods.usage else { return }
            usageRequestsB += 1
            s.enqueueResponse(id: req.id, result: .object([
                "fetchedAt": .string(ISO8601DateFormatter().string(from: clock.now())),
                "ageSeconds": .int(0),
                "ttlSeconds": .int(180),
                "refreshing": .bool(false),
                "groups": .array([])
            ]))
        }

        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false,
            quotaClock: clock
        )
        appVM.addServer(name: "ServerA", scheme: "ws", host: "127.0.0.1:18801", token: "ta", workingDirectory: "~")
        appVM.addServer(name: "ServerB", scheme: "ws", host: "127.0.0.1:18802", token: "tb", workingDirectory: "~")
        let idA = appVM.servers[0].id
        let idB = appVM.servers[1].id
        appVM.selectServer(idA)

        // ⑥ Cold start offline card always visible with nil snapshot ("--% No quota data")
        XCTAssertTrue(appVM.shouldShowQuotaCard(for: idA))
        XCTAssertNil(appVM.quotaSnapshotByServer[idA])

        let serviceA = ACPService(client: ACPClient(configuration: .init(endpoint: URL(string: "ws://127.0.0.1:18801")!, pingInterval: nil), socketProvider: SocketQueueProvider([sockA])))
        let serviceB = ACPService(client: ACPClient(configuration: .init(endpoint: URL(string: "ws://127.0.0.1:18802")!, pingInterval: nil), socketProvider: SocketQueueProvider([sockB])))
        let fakeService = ACPService(client: ACPClient(configuration: .init(endpoint: URL(string: "ws://127.0.0.1:18899")!, pingInterval: nil), socketProvider: SocketQueueProvider([ScriptedSocket()])))
        try await serviceA.connect()
        try await serviceB.connect()
        appVM.setServiceForTesting(serviceA, for: idA)
        appVM.bindService(serviceA, to: idA)
        appVM.setServiceForTesting(serviceB, for: idB)
        appVM.bindService(serviceB, to: idB)

        // ① Background ServerB receives valid push -> MUST be accepted and stored!
        let pushB = NonlocalUsageResult(
            fetchedAt: "2026-11-22T10:00:00Z",
            ageSeconds: 0,
            ttlSeconds: 180,
            refreshing: false,
            tier: .init(name: "Pro-B", id: "pro-b"),
            groups: [],
            lastError: nil
        )
        appVM.handleNonlocalUsageUpdated(pushB, from: serviceB)
        XCTAssertEqual(appVM.quotaSnapshotByServer[idB]?.tier?.name, "Pro-B", "SC-AC-042: background server push must not be dropped")

        // Fake unbound service push -> rejected
        let fakePush = NonlocalUsageResult(
            fetchedAt: "2026-11-22T10:01:00Z",
            ageSeconds: 0,
            ttlSeconds: 180,
            refreshing: false,
            tier: .init(name: "Spoof", id: "spoof"),
            groups: [],
            lastError: nil
        )
        appVM.handleNonlocalUsageUpdated(fakePush, from: fakeService)
        XCTAssertEqual(appVM.quotaSnapshotByServer[idB]?.tier?.name, "Pro-B")
        XCTAssertNil(appVM.quotaSnapshotByServer[idA])

        // Bound service with mismatched endpointSignature -> MUST be rejected (SC-AC-042 ①)!
        let origSigProvider = appVM.quotaManager.endpointSignatureProvider
        appVM.quotaManager.endpointSignatureProvider = { srvId in
            srvId == idB ? "ws://127.0.0.1:99999|mutated" : origSigProvider(srvId)
        }
        let mismatchedPush = NonlocalUsageResult(
            fetchedAt: "2026-11-22T10:02:00Z",
            ageSeconds: 0,
            ttlSeconds: 180,
            refreshing: false,
            tier: .init(name: "WrongEndpoint", id: "wrong-ep"),
            groups: [],
            lastError: nil
        )
        appVM.handleNonlocalUsageUpdated(mismatchedPush, from: serviceB)
        XCTAssertEqual(appVM.quotaSnapshotByServer[idB]?.tier?.name, "Pro-B", "SC-AC-042: mismatched endpointSignature push must be rejected")
        appVM.quotaManager.endpointSignatureProvider = origSigProvider

        // ② Initial fetch on selected A + advance 3 min -> ONLY A polled (B == 0)
        await appVM.performQuotaFetch(for: idA, service: serviceA)
        XCTAssertEqual(usageRequestsA, 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        clock.advance(by: 180)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(usageRequestsA, 2)
        XCTAssertEqual(usageRequestsB, 0, "SC-AC-042: 3-min timer must only poll selected server A")

        // ③ Switch to B while B's push snapshot is still fresh (0s elapsed since 10:00? now is 10:03 -> 180s == TTL -> expired!)
        // First test fresh snapshot on B: inject fresh push at 10:03:00Z before selecting B
        let freshPushB = NonlocalUsageResult(
            fetchedAt: "2026-11-22T10:03:00Z",
            ageSeconds: 0,
            ttlSeconds: 180,
            refreshing: false,
            tier: .init(name: "Fresh-B", id: "fresh-b"),
            groups: [],
            lastError: nil
        )
        appVM.handleNonlocalUsageUpdated(freshPushB, from: serviceB)
        appVM.selectServer(idB)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(usageRequestsB, 0, "SC-AC-042: fresh snapshot on selectServer(B) -> 0 immediate fetch")

        // Advance 3 min while B selected -> B polled once, A polled 0 more times!
        clock.advance(by: 180)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(usageRequestsB, 1, "SC-AC-042: timer migrated to B")
        XCTAssertEqual(usageRequestsA, 2, "SC-AC-042: old timer for A must be stopped (0 fetches)")

        // Switch back to A (A's snapshot from 10:03 is now 180s old = expired) -> immediate fetch on A!
        appVM.selectServer(idA)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(usageRequestsA, 3, "SC-AC-042: expired snapshot on selectServer(A) triggers immediate refresh")

        // ④ .inactive & .background cancel timer -> advancing 3 min issues 0 fetches; returning .active resumes by TTL!
        appVM.handleScenePhaseChanged(.inactive)
        clock.advance(by: 200)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(usageRequestsA, 3, "SC-AC-042: .inactive must cancel quota timer")

        appVM.quotaManager.handleScenePhaseChanged(.background)
        clock.advance(by: 200)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(usageRequestsA, 3, "SC-AC-042: .background must cancel quota timer")

        // Return to .active with expired snapshot -> immediately refreshes selected server A!
        appVM.quotaManager.handleScenePhaseChanged(.active)
        try await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertEqual(usageRequestsA, 4, "SC-AC-042: returning .active with expired TTL must trigger refresh on selected server A")

        // ⑤ updateServer endpoint change & deleteServer clear cache
        appVM.updateServer(idB, with: ValidatedServerConfiguration(
            name: "ServerB", scheme: "ws", host: "127.0.0.1:18899", token: "tb", workingDirectory: "~", agentInfo: nil
        ))
        XCTAssertNil(appVM.quotaSnapshotByServer[idB])
        appVM.deleteServer(idA)
        XCTAssertNil(appVM.quotaSnapshotByServer[idA])

        await serviceA.disconnect()
        await serviceB.disconnect()
    }

    // MARK: - SC-AC-044: ChatMessageCache pure memory + ServerViewModel Core Data separation

    func testSCAC044_ChatMessageCacheAndServerViewModelPersistenceSeparation() {
        let storage = SessionStorage.inMemory()
        let cache = ChatMessageCache()
        let defaults = makeDefaults("SCAC044")
        let serverId = UUID()
        storage.saveServer(ACPServerConfiguration(
            id: serverId, name: "Mini", scheme: "ws", host: "127.0.0.1:18810", token: "tok", workingDirectory: "/work"
        ))
        let manager = ACPClientManager(defaults: defaults, shouldStartNetworkMonitoring: false)
        let serverVM = ServerViewModel(
            id: serverId,
            name: "Mini",
            scheme: "ws",
            host: "127.0.0.1:18810",
            token: "tok",
            workingDirectory: "/work",
            connectionManager: manager,
            getService: { nil },
            append: { _ in },
            logWire: { _, _ in },
            cacheDelegate: cache,
            storage: storage
        )

        let msgS1 = ChatMessage(
            role: .assistant,
            content: "Tool call: [read] foo.swift (completed)\nHello from S1",
            isStreaming: false,
            segments: [
                AssistantSegment(kind: .toolCall, text: "foo.swift", toolCall: ToolCallDisplay(toolCallId: "t1", title: "foo.swift", kind: "read", status: "completed")),
                AssistantSegment(kind: .message, text: "Hello from S1")
            ]
        )
        let msgS2 = ChatMessage(role: .user, content: "Question in S2", isStreaming: false)

        let vmS1 = serverVM.sessionViewModel(for: "S1")
        let vmS2 = serverVM.sessionViewModel(for: "S2")
        vmS1.setChatMessages([msgS1])
        vmS1.saveChatState(persistToStorage: true)
        vmS2.setChatMessages([msgS2])
        vmS2.saveChatState(persistToStorage: true)

        // Verify pure memory cache preview ignores .toolCall / "Tool call:" lines
        cache.saveMessages([msgS1], for: serverId, sessionId: "S1-raw")
        XCTAssertEqual(cache.getLastMessagePreview(for: serverId, sessionId: "S1-raw"), "Hello from S1")
        XCTAssertEqual(cache.getLastMessagePreview(for: serverId, sessionId: "S2"), "You: Question in S2")

        // Clear memory cache -> reload from Core Data via ServerViewModel without cross-talk
        cache.clearCache(for: serverId)
        XCTAssertNil(cache.loadMessages(for: serverId, sessionId: "S1"))
        let restoredS1 = serverVM.loadChatFromStorage(sessionId: "S1")
        let restoredS2 = serverVM.loadChatFromStorage(sessionId: "S2")
        XCTAssertEqual(restoredS1.count, 1)
        XCTAssertEqual(restoredS1[0].segments.last?.text, "Hello from S1")
        XCTAssertEqual(restoredS2.count, 1)
        XCTAssertEqual(restoredS2[0].content, "Question in S2")
    }

    // MARK: - SC-AC-045: Direct PassiveStreamingSettler unidirectional state machine

    func testSCAC045_PassiveStreamingSettlerDirectUnitTest() async throws {
        let fastDelays = PassiveStreamingSettleDelays(
            usageAfterMessageNs: 30_000_000,
            messageNs: 60_000_000,
            thoughtOrCompletedToolNs: 60_000_000,
            activeToolNs: 400_000_000
        )
        let settler = PassiveStreamingSettler(delays: fastDelays)
        var settleCallbacks: [Bool] = []
        settler.onSettle = { notify in
            settleCallbacks.append(notify)
        }

        // ① Active tool keeps hasActiveWork == true and does NOT settle within 100ms
        settler.trackEvent(
            .toolCall(ACPToolCallInfo(toolCallId: "tc-1", title: "Run tests", kind: "execute", status: "in_progress")),
            hasExplicitActiveTurn: false,
            canSchedule: true
        )
        XCTAssertTrue(settler.hasActiveWork)
        XCTAssertTrue(settler.hasUnresolvedPassiveToolCalls)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(settleCallbacks.isEmpty, "SC-AC-045: active tool must delay settle")

        // ② Complete tool + send agent message -> settles exactly once after messageNs
        settler.trackEvent(
            .toolCallUpdate(ACPToolCallUpdate(toolCallId: "tc-1", status: "completed", title: "Run tests", kind: "execute", output: nil)),
            hasExplicitActiveTurn: false,
            canSchedule: true
        )
        settler.trackEvent(.agentMessage(text: "Done!"), hasExplicitActiveTurn: false, canSchedule: true)
        XCTAssertFalse(settler.hasUnresolvedPassiveToolCalls)
        try await waitUntil { settleCallbacks.count == 1 }
        XCTAssertEqual(settleCallbacks, [true])

        // ③ Negative: reset()/cancelTimer() invalidates pending timer so onSettle does NOT fire
        settler.trackEvent(.agentMessage(text: "Another"), hasExplicitActiveTurn: false, canSchedule: true)
        settler.reset()
        XCTAssertFalse(settler.hasActiveWork)
        try await Task.sleep(nanoseconds: 110_000_000)
        XCTAssertEqual(settleCallbacks.count, 1, "SC-AC-045: reset must cancel pending timer with 0 spurious callbacks")
    }

    // MARK: - SC-AC-046: 6-part shadow-state/patch removal & RPC rejection regression

    func testSCAC046_SixPartShadowStateAndPatchRemovalRegression() async throws {
        let defaults = makeDefaults("SCAC046")
        let storage = SessionStorage.inMemory()
        let sockA = ScriptedSocket()
        sockA.onSend = { text, s in
            guard let data = text.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                  case .request(let req) = wire else { return }
            if req.method == "initialize" {
                s.enqueueResponse(id: req.id, result: self.validInitResult())
            } else if req.method == NonlocalMethods.sessionSync {
                s.enqueueResponse(id: req.id, result: .object(["instanceId": .string("inst-46"), "sessions": .array([])]))
            }
        }
        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            defaultSlotServiceFactory: { config, encoder in
                ACPService(client: ACPClient(configuration: config, socketProvider: SocketQueueProvider([sockA]), logger: NoOpLogger(), encoder: encoder))
            },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )

        // ① Switch A -> B -> A must NOT overwrite either server's config
        appVM.addServer(name: "A", scheme: "ws", host: "127.0.0.1:18841", token: "tokA", workingDirectory: "/dirA")
        appVM.addServer(name: "B", scheme: "wss", host: "b.example.test", token: "tokB", workingDirectory: "/dirB")
        let idA = appVM.servers[0].id
        let idB = appVM.servers[1].id
        appVM.selectServer(idA)
        appVM.selectServer(idB)
        appVM.selectServer(idA)
        XCTAssertEqual(appVM.servers[0].host, "127.0.0.1:18841")
        XCTAssertEqual(appVM.servers[0].token, "tokA")
        XCTAssertEqual(appVM.servers[0].workingDirectory, "/dirA")
        XCTAssertEqual(appVM.servers[1].host, "b.example.test")
        XCTAssertEqual(appVM.servers[1].token, "tokB")
        XCTAssertEqual(appVM.servers[1].workingDirectory, "/dirB")

        // ② loadCachedSessions() preserves unsaved pendingLocalSessions draft
        let vmA = try XCTUnwrap(appVM.serverViewModels[idA])
        let draftId = try XCTUnwrap(appVM.sendNewSession(serverId: idA, workingDirectory: "/draft-dir"))
        XCTAssertTrue(vmA.isPendingSessionId(draftId))
        vmA.loadCachedSessions()
        XCTAssertTrue(vmA.sessionSummaries.contains { $0.id == draftId }, "SC-AC-046 ②: loadCachedSessions must preserve pending draft")

        // ③ Placeholder first-prompt resolves via resolvedSessionIds and keeps resolvedSessionIdsByPlaceholder anchor
        appVM.connectServer(idA)
        try await waitUntil { appVM.connectionState(for: idA) == .connected && vmA.hasCompletedNonlocalSync }
        let serviceA = try XCTUnwrap(appVM.service(for: idA))
        let accepted = vmA.submitPrompt(promptText: "First message", images: [], commandName: nil)
        XCTAssertTrue(accepted)
        try await waitUntil { sockA.sentMethods().contains("session/new") }
        let newReq = try XCTUnwrap(sockA.sentRequests().first { $0.method == "session/new" })
        sockA.enqueueResponse(id: newReq.id, result: .object(["sessionId": .string("real-sess-1")]))
        try await waitUntil { sockA.sentMethods().contains("session/prompt") }
        let promptReq = try XCTUnwrap(sockA.sentRequests().first { $0.method == "session/prompt" })
        XCTAssertEqual(promptReq.params.objectValue?["sessionId"]?.stringValue, "real-sess-1")
        XCTAssertEqual(vmA.effectiveSessionId(for: draftId), "real-sess-1", "SC-AC-046 ③: resolvedSessionIdsByPlaceholder anchor must persist")

        // ④ 4 sessions created 5s apart preserve their updatedAt timestamps (no legacy timestamp wipe)
        let baseDate = Date(timeIntervalSince1970: 1_760_100_000)
        for i in 0..<4 {
            storage.saveSession(
                StoredSessionInfo(sessionId: "ts-\(i)", title: "T\(i)", cwd: "/dirA", updatedAt: baseDate.addingTimeInterval(Double(i * 5))),
                forServerId: idA
            )
        }
        let vmReloaded = AppViewModel(storage: storage, defaults: defaults, shouldStartNetworkMonitoring: false, shouldConnectOnStartup: false)
        let loadedDates = (vmReloaded.serverViewModels[idA]?.sessionSummaries ?? []).filter { $0.id.hasPrefix("ts-") }.compactMap(\.updatedAt)
        XCTAssertEqual(loadedDates.count, 4, "SC-AC-046 ④: all 4 closely-spaced updatedAt timestamps must survive cold reload")

        // ⑤ Incoming FS/Terminal server requests reply -32001; unknown RPC replies -32601
        let fsReq = ACP.AnyRequest(id: .int(701), method: "fs/read_text_file", params: .object(["path": .string("/etc/hosts")]))
        let termReq = ACP.AnyRequest(id: .int(702), method: "terminal/create", params: .object([:]))
        let unknownReq = ACP.AnyRequest(id: .int(703), method: "custom/ping", params: .object([:]))
        appVM.acpService(serviceA, didReceiveMessage: .request(fsReq))
        appVM.acpService(serviceA, didReceiveMessage: .request(termReq))
        appVM.acpService(serviceA, didReceiveMessage: .request(unknownReq))
        try await waitUntil {
            let errCodes = sockA.sentRawMessages().compactMap { msg -> (ACP.ID, Int)? in
                guard case .response(let r) = msg, let e = r.errorValue else { return nil }
                return (r.id, e.code)
            }
            return errCodes.count >= 3
        }
        let errById = Dictionary(uniqueKeysWithValues: sockA.sentRawMessages().compactMap { msg -> (ACP.ID, Int)? in
            guard case .response(let r) = msg, let e = r.errorValue else { return nil }
            return (r.id, e.code)
        })
        XCTAssertEqual(errById[.int(701)], -32001)
        XCTAssertEqual(errById[.int(702)], -32001)
        XCTAssertEqual(errById[.int(703)], -32601)

        // ⑥ logWire outputs compact format via ACPMessageFormatter.compact into target server's slot logs
        let compactCountBefore = appVM.connectionPool.updates(for: idA).count
        appVM.logWire("→", message: .request(ACP.AnyRequest(id: .int(999), method: "session/list", params: .object([:]))), serverId: idA)
        let logsAfter = appVM.connectionPool.updates(for: idA)
        XCTAssertEqual(logsAfter.count, compactCountBefore + 1)
        XCTAssertTrue(logsAfter.last?.message.contains("session/list") == true)

        await serviceA.disconnect()
    }

    // MARK: - SC-AC-048 & SC-AC-049: Full TD-2 Cross-Server Isolation (Positive Online + Negative Offline)

    func testSCAC048_049_FullTD2CrossServerIsolationPositiveAndOfflineNegative() async throws {
        let defaults = makeDefaults("SCAC048_049")
        let storage = SessionStorage.inMemory()
        let sockA = ScriptedSocket()
        let sockB = ScriptedSocket()

        sockB.onSend = { text, s in
            guard let data = text.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                  case .request(let req) = wire else { return }
            switch req.method {
            case NonlocalMethods.fsList:
                s.enqueueResponse(id: req.id, result: .object([
                    "path": .string("/b"),
                    "parentPath": .string("/"),
                    "homePath": .string("/b"),
                    "totalCount": .int(0),
                    "truncated": .bool(false),
                    "entries": .array([])
                ]))
            case NonlocalMethods.fsReadFile:
                s.enqueueResponse(id: req.id, result: .object([
                    "path": .string("/b/README.md"),
                    "name": .string("README.md"),
                    "kind": .string("text"),
                    "mimeType": .string("text/markdown"),
                    "content": .string("# B\n"),
                    "size": .int(4),
                    "bytesRead": .int(4),
                    "truncated": .bool(false)
                ]))
            case NonlocalMethods.sessionInfo:
                s.enqueueResponse(id: req.id, result: .object([
                    "sessionId": .string("sess-B"),
                    "cwd": .string("/b")
                ]))
            case "session/set_mode", "session/set_config_option":
                s.enqueueResponse(id: req.id, result: .object([:]))
            default:
                break
            }
        }

        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        appVM.addServer(name: "ServerA", scheme: "ws", host: "127.0.0.1:18851", token: "ta", workingDirectory: "/a")
        appVM.addServer(name: "ServerB", scheme: "ws", host: "127.0.0.1:18852", token: "tb", workingDirectory: "/b")
        let idA = appVM.servers[0].id
        let idB = appVM.servers[1].id
        appVM.selectServer(idA) // Keep A selected throughout!

        storage.addUsedWorkingDirectory("/a", forServerId: idA)
        storage.addUsedWorkingDirectory("/b", forServerId: idB)
        storage.addUsedWorkingDirectory("/b/extra", forServerId: idB)

        let serviceA = ACPService(client: ACPClient(configuration: .init(endpoint: URL(string: "ws://127.0.0.1:18851")!, pingInterval: nil), socketProvider: SocketQueueProvider([sockA])))
        let serviceB = ACPService(client: ACPClient(configuration: .init(endpoint: URL(string: "ws://127.0.0.1:18852")!, pingInterval: nil), socketProvider: SocketQueueProvider([sockB])))
        try await serviceA.connect()
        try await serviceB.connect()
        appVM.setServiceForTesting(serviceA, for: idA)
        appVM.bindService(serviceA, to: idA)
        appVM.setServiceForTesting(serviceB, for: idB)
        appVM.bindService(serviceB, to: idB)

        let vmA = try XCTUnwrap(appVM.serverViewModels[idA])
        let vmB = try XCTUnwrap(appVM.serverViewModels[idB])
        _ = vmB.rememberSession("sess-B", cwd: "/b")
        vmB.setActiveSession("sess-B", cwd: "/b")

        // SC-AC-048 Online: All 6 operations route 100% to ServerB while ServerA receives 0 frames
        let listRes = try await appVM.listRemoteDirectory(serverId: idB, path: "/b", includeFiles: true)
        XCTAssertEqual(listRes?.path, "/b")

        let readRes = try await appVM.readRemoteFile(serverId: idB, path: "/b/README.md")
        XCTAssertEqual(readRes?.path, "/b/README.md")

        appVM.sendSetMode("plan", serverId: idB, sessionId: "sess-B")
        vmB.sessionViewModel(for: "sess-B").sendSetConfigOption(
            configId: ACPModelConfig.configId,
            value: .string("hydrogen"),
            sessionId: "sess-B",
            serverId: idB
        )
        try await waitUntil {
            sockB.sentMethods().contains("session/set_mode")
                && sockB.sentMethods().contains("session/set_config_option")
        }

        XCTAssertTrue(appVM.canViewSessionInfo("sess-B", serverId: idB))
        let infoRes = try await appVM.fetchSessionInfo(serverId: idB, sessionId: "sess-B")
        XCTAssertEqual(infoRes?.sessionId, "sess-B")

        // Relative path resolution uses ServerB's cwd -> "/b/src/app.swift"
        let linkRes = ChatLinkRouter.resolve(
            rawLink: "src/app.swift",
            sessionCwd: appVM.currentSessionCwd(for: idB, sessionId: "sess-B"),
            serverDefaultCwd: vmB.workingDirectory
        )
        if case .remotePath(let resolvedPath, _, _, _) = linkRes {
            XCTAssertEqual(resolvedPath, "/b/src/app.swift")
        } else {
            XCTFail("SC-AC-048: expected .remotePath('/b/src/app.swift'), got \(linkRes)")
        }

        // WorkingDirectoryPickerBinding anchored to ServerB (pending draft update isolates from A)
        let draftB = try XCTUnwrap(appVM.sendNewSession(serverId: idB, workingDirectory: "/b"))
        let pickerBinding = WorkingDirectoryPickerBinding(model: appVM, serverViewModel: vmB)
        XCTAssertTrue(pickerBinding.isPendingSession)
        XCTAssertEqual(pickerBinding.connectionState, .connected)
        XCTAssertEqual(pickerBinding.serverDefaultCwd, "/b")
        XCTAssertTrue(pickerBinding.usedWorkingDirectoryHistory.contains("/b/extra"))
        XCTAssertFalse(pickerBinding.usedWorkingDirectoryHistory.contains("/a"))
        pickerBinding.updatePendingWorkingDirectory("/b/updated")
        XCTAssertEqual(appVM.currentSessionCwd(for: idB, sessionId: draftB), "/b/updated")
        XCTAssertEqual(vmA.workingDirectory, "/a")

        // ServerA received ZERO frames and selectedServerId never changed!
        XCTAssertTrue(sockA.sentMethods().isEmpty, "SC-AC-048: ServerA must receive 0 frames, got \(sockA.sentMethods())")
        XCTAssertEqual(appVM.selectedServerId, idA)

        // SC-AC-049 ①②④⑤: Edit gating, history, migrateSessionCaches, NewSessionDefaults
        let serverBConfig = appVM.servers[1]
        XCTAssertTrue(AddServerDirectoryGating.canShowBrowseButton(
            editingServer: serverBConfig,
            connectionState: appVM.connectionState(for: idB),
            scheme: serverBConfig.scheme,
            host: serverBConfig.host,
            token: serverBConfig.token
        ))
        XCTAssertFalse(AddServerDirectoryGating.canShowBrowseButton(
            editingServer: serverBConfig,
            connectionState: appVM.connectionState(for: idB),
            scheme: serverBConfig.scheme,
            host: "127.0.0.1:19999",
            token: serverBConfig.token
        ))
        XCTAssertFalse(AddServerDirectoryGating.canShowBrowseButton(
            editingServer: serverBConfig,
            connectionState: .disconnected,
            scheme: serverBConfig.scheme,
            host: serverBConfig.host,
            token: serverBConfig.token
        ))
        XCTAssertEqual(
            Set(appVM.usedWorkingDirectoryHistory(for: idB)),
            Set(["/b", "/b/extra", "/b/updated"])
        )

        // migrateSessionCaches(for: B) mutates ONLY B, zero impact on A
        appVM.chatCache.saveMessages([ChatMessage(role: .user, content: "A-msg", isStreaming: false)], for: idA, sessionId: "draft-1")
        appVM.chatCache.saveMessages([ChatMessage(role: .user, content: "B-msg", isStreaming: false)], for: idB, sessionId: "draft-1")
        _ = vmB.sessionViewModel(for: "draft-1")
        appVM.migrateSessionCaches(for: idB, from: "draft-1", to: "real-1")
        XCTAssertEqual(appVM.chatCache.loadMessages(for: idB, sessionId: "real-1")?.first?.content, "B-msg")
        XCTAssertNil(appVM.chatCache.loadMessages(for: idA, sessionId: "real-1"), "SC-AC-049: migrateSessionCaches(B) must not touch A")
        XCTAssertEqual(vmB.effectiveSessionId(for: "draft-1"), "real-1")
        XCTAssertEqual(vmA.effectiveSessionId(for: "draft-1"), "draft-1")

        // presentNewSessionSheet working directory resolution: existing B -> "/b", missing UUID -> "~" (NEVER A's "/a")
        XCTAssertEqual(NewSessionDefaults.resolveWorkingDirectory(preselectedServerId: idB, servers: appVM.servers), "/b")
        XCTAssertEqual(NewSessionDefaults.resolveWorkingDirectory(preselectedServerId: UUID(), servers: appVM.servers), "~")

        // SC-AC-048 Negative: disconnect ServerB while ServerA stays connected -> B operations fail offline, 0 frames to A!
        appVM.disconnect(serverId: idB)
        try await waitUntil { appVM.connectionState(for: idB) == .disconnected }
        XCTAssertEqual(appVM.connectionState(for: idA), .connected)
        XCTAssertEqual(pickerBinding.connectionState, .disconnected)

        do {
            _ = try await appVM.listRemoteDirectory(serverId: idB, path: "/b")
            XCTFail("SC-AC-048 negative: offline ServerB listRemoteDirectory must fail")
        } catch {}
        do {
            _ = try await appVM.readRemoteFile(serverId: idB, path: "/b/README.md")
            XCTFail("SC-AC-048 negative: offline ServerB readRemoteFile must fail")
        } catch {}
        let offlineInfo = try await appVM.fetchSessionInfo(serverId: idB, sessionId: "sess-B")
        XCTAssertNil(offlineInfo, "SC-AC-048 negative: offline ServerB fetchSessionInfo must return nil without borrowing ServerA")

        XCTAssertTrue(sockA.sentMethods().isEmpty, "SC-AC-048 negative: offline B must NEVER borrow online A")
        XCTAssertEqual(appVM.selectedServerId, idA)

        await serviceA.disconnect()
        await serviceB.disconnect()
    }
}
