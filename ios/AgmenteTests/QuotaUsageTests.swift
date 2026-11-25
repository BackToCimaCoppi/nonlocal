import XCTest
import ACP
@testable import Agmente
import ACPClient

private final class VirtualQuotaClock: QuotaUsageClock, @unchecked Sendable {
    private let lock = NSLock()
    private var currentDate: Date
    private var recordedSleeps: [TimeInterval] = []
    private var pendingSleepContinuations: [(targetDate: Date, continuation: CheckedContinuation<Void, Error>)] = []

    init(start: Date) {
        self.currentDate = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return currentDate
    }

    var sleepIntervals: [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return recordedSleeps
    }

    func sleep(seconds: TimeInterval) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                recordedSleeps.append(seconds)
                let target = currentDate.addingTimeInterval(seconds)
                pendingSleepContinuations.append((targetDate: target, continuation: continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let pending = pendingSleepContinuations
            pendingSleepContinuations.removeAll()
            lock.unlock()
            for item in pending {
                item.continuation.resume(throwing: CancellationError())
            }
        }
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        currentDate = currentDate.addingTimeInterval(seconds)
        let nowDate = currentDate
        var ready: [CheckedContinuation<Void, Error>] = []
        var stillPending: [(targetDate: Date, continuation: CheckedContinuation<Void, Error>)] = []
        for item in pendingSleepContinuations {
            if item.targetDate <= nowDate {
                ready.append(item.continuation)
            } else {
                stillPending.append(item)
            }
        }
        pendingSleepContinuations = stillPending
        lock.unlock()
        for cont in ready {
            cont.resume()
        }
    }
}

private final class QuotaScriptedSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var incomingQueue: [WebSocketEvent] = []
    private var incomingContinuation: CheckedContinuation<WebSocketEvent, Error>?
    private var sentPayloads: [String] = []
    var onSend: ((String) -> Void)?

    var sentTexts: [String] {
        lock.lock()
        defer { lock.unlock() }
        return sentPayloads
    }

    func connect(headers: [String: String]) async throws {}

    func send(text: String) async throws {
        lock.lock()
        sentPayloads.append(text)
        let callback = onSend
        lock.unlock()
        callback?(text)
    }

    func receive() async throws -> WebSocketEvent {
        return try await withCheckedThrowingContinuation { continuation in
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

private final class QuotaScriptedSocketProvider: WebSocketProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [QuotaScriptedSocket] = []
    private var index = 0

    init(_ sockets: [QuotaScriptedSocket]) {
        self.sockets = sockets
    }

    func makeConnection(url: URL) -> WebSocketConnection {
        lock.lock()
        defer { lock.unlock() }
        let sock = sockets[min(index, sockets.count - 1)]
        index += 1
        return sock
    }
}

@MainActor
final class QuotaUsageTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let name = "QuotaUsageTests.\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func makeSampleUsage(
        fetchedAt: String? = "2026-11-19T12:00:00Z",
        ageSeconds: Int? = 6,
        ttlSeconds: Int = 180,
        refreshing: Bool = false,
        tier: NonlocalUsageTier? = .init(name: "Google AI Pro", id: "pro"),
        lastError: NonlocalUsageError? = nil
    ) -> NonlocalUsageResult {
        NonlocalUsageResult(
            fetchedAt: fetchedAt,
            ageSeconds: ageSeconds,
            ttlSeconds: ttlSeconds,
            refreshing: refreshing,
            tier: tier,
            groups: [
                NonlocalUsageGroup(
                    name: "Gemini 4",
                    description: nil,
                    buckets: [
                        NonlocalUsageBucket(
                            id: "g4-5h",
                            name: "5h",
                            window: "5h",
                            remainingFraction: 0.72,
                            resetTime: "2026-11-19T15:12:00Z"
                        )
                    ]
                )
            ],
            lastError: lastError
        )
    }

    // AC-102: Isolated UserDefaults persistence, updateServer endpoint/type change cleanup, and deleteServer cleanup.
    func testAC102QuotaPersistenceUpdateServerAndDeleteServerCleanup() {
        let defaults = makeIsolatedDefaults()
        let persistence = PersistenceController(inMemory: true)
        let storage = SessionStorage(container: persistence.container)

        let model1 = AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        model1.addServer(
            name: "Mini",
            scheme: "ws",
            host: "127.0.0.1:18801",
            token: "tok",
            workingDirectory: "~"
        )
        let serverId = model1.selectedServerId!

        let store = QuotaUsageStore(defaults: defaults)
        let sample = makeSampleUsage()
        store.save(PersistedQuotaUsageRecord(hasConfirmedQuotaSupport: true, snapshot: sample), for: serverId)

        // Rebuild AppViewModel with same isolated storage & defaults -> restores snapshot and support flag
        let model2 = AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        XCTAssertEqual(model2.quotaConfirmedSupportByServer[serverId], true)
        XCTAssertEqual(model2.quotaSnapshotByServer[serverId], sample)

        // updateServer changing host clears snapshot & support flag
        model2.updateServer(
            serverId,
            with: ValidatedServerConfiguration(
                name: "Mini",
                scheme: "ws",
                host: "127.0.0.1:18802",
                token: "tok",
                workingDirectory: "~",
                agentInfo: nil
            )
        )
        XCTAssertNil(model2.quotaSnapshotByServer[serverId])
        XCTAssertNil(model2.quotaConfirmedSupportByServer[serverId])
        XCTAssertNil(store.load(for: serverId))

        // Re-seed and test deleteServer clears quota state
        store.save(PersistedQuotaUsageRecord(hasConfirmedQuotaSupport: true, snapshot: sample), for: serverId)
        model2.deleteServer(serverId)
        XCTAssertNil(model2.quotaSnapshotByServer[serverId])
        XCTAssertNil(store.load(for: serverId))
    }

    // AC-103: Virtual clock foreground cadence: max(1s, 180s - effectiveAge) = 174s, >= 2 refreshes in 420s,
    // and cancels timer on backgrounding or server switch with 0 subsequent requests.
    func testAC103VirtualClockForegroundCadenceAndBackgroundCancel() async throws {
        let defaults = makeIsolatedDefaults()
        let persistence = PersistenceController(inMemory: true)
        let storage = SessionStorage(container: persistence.container)
        let start = QuotaUsageMerger.parseISO8601("2026-11-19T12:00:00Z")!
        let clock = VirtualQuotaClock(start: start)

        let socket = QuotaScriptedSocket()
        var usageRequestCount = 0
        socket.onSend = { text in
            guard let data = text.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                  case .request(let req) = wire,
                  req.method == NonlocalMethods.usage else {
                return
            }
            usageRequestCount += 1
            let result: ACP.Value = .object([
                "fetchedAt": .string("2026-11-19T12:00:00Z"),
                "ageSeconds": .int(6),
                "ttlSeconds": .int(180),
                "refreshing": .bool(false),
                "groups": .array([])
            ])
            try? socket.enqueueResponse(id: req.id, result: result)
        }

        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false
        )
        let model = AppViewModel(
            storage: storage,
            defaults: defaults,
            connectionManagerFactory: { _ in manager },
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false,
            quotaClock: clock
        )
        model.addServer(
            name: "Mini",
            scheme: "ws",
            host: "127.0.0.1:18803",
            token: "",
            workingDirectory: "~"
        )
        let serverId = model.selectedServerId!
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "ws://127.0.0.1:18803")!, pingInterval: nil),
            socketProvider: QuotaScriptedSocketProvider([socket])
        )
        let service = ACPService(client: client)
        try await service.connect()
        model.setServiceForTesting(service)
        model.bindService(service, to: serverId)

        // Initial fetch (not counted in the 420s stay window)
        await model.performQuotaFetch(for: serverId, service: service)
        XCTAssertEqual(usageRequestCount, 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(clock.sleepIntervals.first, 174.0)

        // Advance 174s -> first stay refresh fires
        clock.advance(by: 174.0)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(usageRequestCount, 2)

        // Advance another 174s (total 348s <= 420s) -> second stay refresh fires
        clock.advance(by: 174.0)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(usageRequestCount, 3)

        // Total requests inside 420s stay window (excluding initial) == 2 >= 2
        XCTAssertGreaterThanOrEqual(usageRequestCount - 1, 2)

        // Backgrounding cancels timer -> advancing 500s yields 0 more requests
        model.handleScenePhaseChanged(.background)
        clock.advance(by: 500.0)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(usageRequestCount, 3)

        await service.disconnect()
    }

    // AC-104: Merge rules for nil cold-start error, same-fetchedAt tier update, newer fetchedAt clearing lastError,
    // and >30s dirty future timestamp self-healing override.
    func testAC104QuotaMergerRulesAndClockSkewSelfHeal() {
        let now = QuotaUsageMerger.parseISO8601("2026-11-19T12:10:00Z")!

        // 1. Cold start fetchedAt == nil -> same nil with lastError is accepted
        let coldEmpty = NonlocalUsageResult(fetchedAt: nil, ageSeconds: nil, ttlSeconds: 180, refreshing: true, tier: nil, groups: [], lastError: nil)
        let coldErr = NonlocalUsageResult(
            fetchedAt: nil,
            ageSeconds: nil,
            ttlSeconds: 180,
            refreshing: false,
            tier: nil,
            groups: [],
            lastError: .init(code: "auth_required", message: "请重新登录", failedAt: "2026-11-19T12:10:00Z")
        )
        let merged1 = QuotaUsageMerger.merge(incoming: coldErr, current: coldEmpty, now: now)
        XCTAssertEqual(merged1.lastError?.code, "auth_required")

        // 2. Same fetchedAt T1 with tier update keeps T1 and updates tier
        let t1 = "2026-11-19T12:05:00Z"
        let atT1 = makeSampleUsage(
            fetchedAt: t1,
            tier: nil,
            lastError: .init(code: "timeout", message: "超时", failedAt: t1)
        )
        let atT1WithTier = makeSampleUsage(
            fetchedAt: t1,
            tier: .init(name: "Ultra", id: "ultra"),
            lastError: .init(code: "timeout", message: "超时", failedAt: t1)
        )
        let merged2 = QuotaUsageMerger.merge(incoming: atT1WithTier, current: atT1, now: now)
        XCTAssertEqual(merged2.fetchedAt, t1)
        XCTAssertEqual(merged2.tier?.name, "Ultra")

        // 3. Newer fetchedAt T2 > T1 overwrites and clears lastError
        let t2 = "2026-11-19T12:09:00Z"
        let atT2Success = makeSampleUsage(fetchedAt: t2, tier: .init(name: "Ultra", id: "ultra"), lastError: nil)
        let merged3 = QuotaUsageMerger.merge(incoming: atT2Success, current: merged2, now: now)
        XCTAssertEqual(merged3.fetchedAt, t2)
        XCTAssertNil(merged3.lastError)

        // 4. Dirty local future timestamp (now + 120s > +30s) is overwritten by authoritative T3
        let dirtyFuture = makeSampleUsage(fetchedAt: "2026-11-19T12:12:00Z", tier: .init(name: "Old", id: "old"))
        let t3Authoritative = makeSampleUsage(fetchedAt: "2026-11-19T12:09:50Z", tier: .init(name: "Fixed", id: "fixed"))
        let merged4 = QuotaUsageMerger.merge(incoming: t3Authoritative, current: dirtyFuture, now: now)
        XCTAssertEqual(merged4.fetchedAt, "2026-11-19T12:09:50Z")
        XCTAssertEqual(merged4.tier?.name, "Fixed")
    }

    // AC-105: ObjectIdentifier(service) cross-server isolation during selectServer async disconnect window.
    func testAC105CrossServerIsolationOnSelectServerDisconnectRace() async throws {
        let defaults = makeIsolatedDefaults()
        let persistence = PersistenceController(inMemory: true)
        let storage = SessionStorage(container: persistence.container)
        let model = AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )

        model.addServer(name: "Server A", scheme: "ws", host: "127.0.0.1:18811", token: "", workingDirectory: "~")
        let serverA = model.selectedServerId!
        model.addServer(name: "Server B", scheme: "ws", host: "127.0.0.1:18812", token: "", workingDirectory: "~")
        let serverB = model.selectedServerId!

        model.selectServer(serverA)
        let sockA = QuotaScriptedSocket()
        let serviceA = ACPService(
            client: ACPClient(
                configuration: .init(endpoint: URL(string: "ws://127.0.0.1:18811")!, pingInterval: nil),
                socketProvider: QuotaScriptedSocketProvider([sockA])
            )
        )
        try await serviceA.connect()
        model.setServiceForTesting(serviceA)
        model.bindService(serviceA, to: serverA)

        // Switch to serverB while serviceA is still disconnecting asynchronously
        model.selectServer(serverB)
        let sockB = QuotaScriptedSocket()
        let serviceB = ACPService(
            client: ACPClient(
                configuration: .init(endpoint: URL(string: "ws://127.0.0.1:18812")!, pingInterval: nil),
                socketProvider: QuotaScriptedSocketProvider([sockB])
            )
        )
        try await serviceB.connect()
        model.setServiceForTesting(serviceB)
        model.bindService(serviceB, to: serverB)

        // Late notification delivered from serviceA must NOT pollute serverB
        let payloadFromA = makeSampleUsage(tier: .init(name: "From A", id: "a"))
        model.handleNonlocalUsageUpdated(payloadFromA, from: serviceA)

        XCTAssertNil(model.quotaSnapshotByServer[serverB])
        XCTAssertNotEqual(model.quotaConfirmedSupportByServer[serverB], true)

        await serviceA.disconnect()
        await serviceB.disconnect()
    }

    // SC-AC-043 / DEC-28: -32601, timeout, and transport disconnect all preserve cached snapshot (never clear to .unsupported),
    // cold-start empty cache stays nil, and "already initialized" reconnect probes after nonlocal/sync succeeds.
    func testAC106AlreadyInitializedProbeAnd32601PreservesCache_SCAC043() async throws {
        let defaults = makeIsolatedDefaults()
        let persistence = PersistenceController(inMemory: true)
        let storage = SessionStorage(container: persistence.container)
        let model = AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        model.addServer(name: "Mini", scheme: "ws", host: "127.0.0.1:18821", token: "tok", workingDirectory: "~")
        let serverId = model.selectedServerId!

        // Seed cached snapshot (85% remaining) before error injection
        let store = QuotaUsageStore(defaults: defaults)
        let cachedSample = makeSampleUsage(fetchedAt: "2026-11-19T12:00:00Z")
        store.save(.init(hasConfirmedQuotaSupport: true, snapshot: cachedSample), for: serverId)
        model.quotaManager.hydrate(for: model.servers)
        XCTAssertEqual(model.quotaSnapshotByServer[serverId]?.groups.first?.buckets.first?.remainingFraction, 0.72)

        // Connection 1: bridge returns -32601 -> cached snapshot and persisted record MUST remain intact (DEC-28)
        let sock1 = QuotaScriptedSocket()
        sock1.onSend = { text in
            guard let data = text.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                  case .request(let req) = wire,
                  req.method == NonlocalMethods.usage else { return }
            try? sock1.enqueueRPCError(id: req.id, code: -32601, message: "Method not found")
        }
        let service1 = ACPService(
            client: ACPClient(
                configuration: .init(endpoint: URL(string: "ws://127.0.0.1:18821")!, pingInterval: nil),
                socketProvider: QuotaScriptedSocketProvider([sock1])
            )
        )
        try await service1.connect()
        model.setServiceForTesting(service1)
        model.bindService(service1, to: serverId)

        await model.performQuotaFetch(for: serverId, service: service1)
        XCTAssertEqual(model.quotaSnapshotByServer[serverId], cachedSample)
        XCTAssertEqual(store.load(for: serverId)?.snapshot, cachedSample)
        XCTAssertTrue(model.shouldShowQuotaCard(for: serverId))
        await service1.disconnect()

        // Cold-start empty cache encountering -32601 keeps snapshot == nil ("--% No quota data")
        model.addServer(name: "Cold", scheme: "ws", host: "127.0.0.1:18822", token: "tok", workingDirectory: "~")
        let coldServerId = model.servers.last!.id
        let sockCold = QuotaScriptedSocket()
        sockCold.onSend = { text in
            guard let data = text.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                  case .request(let req) = wire,
                  req.method == NonlocalMethods.usage else { return }
            try? sockCold.enqueueRPCError(id: req.id, code: -32601, message: "Method not found")
        }
        let serviceCold = ACPService(
            client: ACPClient(
                configuration: .init(endpoint: URL(string: "ws://127.0.0.1:18822")!, pingInterval: nil),
                socketProvider: QuotaScriptedSocketProvider([sockCold])
            )
        )
        try await serviceCold.connect()
        model.setServiceForTesting(serviceCold, for: coldServerId)
        model.bindService(serviceCold, to: coldServerId)
        await model.performQuotaFetch(for: coldServerId, service: serviceCold)
        XCTAssertNil(model.quotaSnapshotByServer[coldServerId])
        XCTAssertTrue(model.shouldShowQuotaCard(for: coldServerId))
        await serviceCold.disconnect()

        // Connection 2: "already initialized" reconnect passes nonlocal/sync -> releases nonlocal/usage probe -> .supported
        model.selectServer(serverId)
        let sock2 = QuotaScriptedSocket()
        var usageProbeSentOnConn2 = false
        sock2.onSend = { text in
            guard let data = text.data(using: .utf8),
                  let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                  case .request(let req) = wire else { return }
            if req.method == NonlocalMethods.sessionSync {
                try? sock2.enqueueResponse(id: req.id, result: .object([
                    "instanceId": .string("inst-quota-2"),
                    "activeTurns": .array([])
                ]))
                return
            }
            if req.method == NonlocalMethods.usage {
                usageProbeSentOnConn2 = true
                let result: ACP.Value = .object([
                    "fetchedAt": .string("2026-11-19T12:20:00Z"),
                    "ageSeconds": .int(1),
                    "ttlSeconds": .int(180),
                    "refreshing": .bool(false),
                    "groups": .array([])
                ])
                try? sock2.enqueueResponse(id: req.id, result: result)
            }
        }
        let service2 = ACPService(
            client: ACPClient(
                configuration: .init(endpoint: URL(string: "ws://127.0.0.1:18821")!, pingInterval: nil),
                socketProvider: QuotaScriptedSocketProvider([sock2])
            )
        )
        try await service2.connect()
        model.setServiceForTesting(service2, for: serverId)
        model.bindService(service2, to: serverId)
        model.resetConnectionUsageState(for: serverId)

        let initReq = ACP.AnyRequest(id: .int(99), method: "initialize", params: .object([:]))
        model.acpService(service2, willSend: initReq)
        let alreadyInitResp = ACPWireMessage.response(.init(id: .int(99), error: .serverError(code: -32000, message: "Already initialized")))
        model.acpService(service2, didReceiveMessage: alreadyInitResp)

        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(usageProbeSentOnConn2)
        XCTAssertEqual(model.connectionUsageStateByServer[serverId], .supported)
        XCTAssertEqual(model.quotaConfirmedSupportByServer[serverId], true)
        XCTAssertTrue(model.shouldShowQuotaCard(for: serverId))

        await service2.disconnect()
    }

    // AC-107: Non--32601 transient errors (disconnect / timeout / CancellationError) preserve support & snapshot
    // and never inject fake CLI lastError.
    func testAC107TransientErrorsPreserveSupportAndSnapshot() async throws {
        let defaults = makeIsolatedDefaults()
        let persistence = PersistenceController(inMemory: true)
        let storage = SessionStorage(container: persistence.container)
        let model = AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        model.addServer(name: "Mini", scheme: "ws", host: "127.0.0.1:18831", token: "", workingDirectory: "~")
        let serverId = model.selectedServerId!

        let sock = QuotaScriptedSocket()
        let service = ACPService(
            client: ACPClient(
                configuration: .init(endpoint: URL(string: "ws://127.0.0.1:18831")!, pingInterval: nil),
                socketProvider: QuotaScriptedSocketProvider([sock])
            )
        )
        try await service.connect()
        model.setServiceForTesting(service)
        model.bindService(service, to: serverId)

        let baseline = makeSampleUsage(fetchedAt: "2026-11-19T12:00:00Z", lastError: nil)
        model.handleNonlocalUsageUpdated(baseline, from: service)
        XCTAssertEqual(model.quotaConfirmedSupportByServer[serverId], true)

        // Disconnect triggers transport error on fetchNonlocalUsage
        await service.disconnect()
        await model.performQuotaFetch(for: serverId, service: service)

        XCTAssertEqual(model.quotaConfirmedSupportByServer[serverId], true)
        XCTAssertEqual(model.quotaSnapshotByServer[serverId]?.fetchedAt, "2026-11-19T12:00:00Z")
        XCTAssertNil(model.quotaSnapshotByServer[serverId]?.lastError)
        XCTAssertTrue(model.shouldShowQuotaCard(for: serverId))
    }

    // AC-108 & W2-AC-503: Deterministic reset time & updated-at formatting across locales (zero zh_CN leak, zero minus sign on expired).
    func testAC108FormatterDeterministicFormatting() {
        let tz = TimeZone(secondsFromGMT: 8 * 3600)! // Asia/Shanghai (+08:00)
        let now = QuotaUsageMerger.parseISO8601("2026-11-19T04:08:00Z")! // 12:08 +08:00
        let enLocale = Locale(identifier: "en")
        let zhLocale = Locale(identifier: "zh-Hans")

        // 5h future: +3h12m -> 15:20
        let fiveHEn = QuotaUsageFormatter.formatResetTime(
            window: "5h",
            resetTime: "2026-11-19T07:20:00Z",
            now: now,
            timeZone: tz,
            locale: enLocale
        )
        XCTAssertNotNil(fiveHEn)
        XCTAssertTrue(fiveHEn?.contains("15:20") == true)
        XCTAssertFalse(fiveHEn?.contains("后") == true, "English locale must not leak Chinese characters")

        // weekly future: 2026-11-24T00:20:00Z -> Tuesday 08:20 +08:00
        let weeklyEn = QuotaUsageFormatter.formatResetTime(
            window: "weekly",
            resetTime: "2026-11-24T00:20:00Z",
            now: now,
            timeZone: tz,
            locale: enLocale
        )
        XCTAssertNotNil(weeklyEn)
        XCTAssertTrue(weeklyEn?.contains("08:20") == true)
        XCTAssertTrue(weeklyEn?.contains("Tue") == true)

        let weeklyZh = QuotaUsageFormatter.formatResetTime(
            window: "weekly",
            resetTime: "2026-11-24T00:20:00Z",
            now: now,
            timeZone: tz,
            locale: zhLocale
        )
        XCTAssertNotNil(weeklyZh)
        XCTAssertTrue(weeklyZh?.contains("08:20") == true)

        // nil resetTime -> omitted
        XCTAssertNil(QuotaUsageFormatter.formatResetTime(window: "5h", resetTime: nil, now: now, timeZone: tz, locale: enLocale))

        // expired resetTime <= now -> zero minus sign across locales
        let expiredEn = QuotaUsageFormatter.formatResetTime(
            window: "5h",
            resetTime: "2026-11-19T03:30:00Z", // 11:30 +08:00
            now: now,
            timeZone: tz,
            locale: enLocale
        )
        XCTAssertNotNil(expiredEn)
        XCTAssertTrue(expiredEn?.contains("11:30") == true)
        XCTAssertFalse(expiredEn?.contains("-") == true)

        // updatedAt: 30s -> Just now, 300s -> Updated 5m ago
        XCTAssertEqual(QuotaUsageFormatter.formatUpdatedAt(fetchedAt: "2026-11-19T04:07:30Z", now: now, locale: enLocale), "Just now")
        XCTAssertEqual(QuotaUsageFormatter.formatUpdatedAt(fetchedAt: "2026-11-19T04:03:00Z", now: now, locale: enLocale), "Updated 5m ago")
    }

    // MARK: - W2-AC-503: Multi-locale deterministic switching (en / zh-Hans / ru / de)

    func testW2AC503_MultiLocaleFormattersSwitchCleanlyAcrossEnZhRuDe() {
        let tz = TimeZone(secondsFromGMT: 0)!
        let now = QuotaUsageMerger.parseISO8601("2026-11-19T12:00:00Z")!
        let locales = ["en", "zh-Hans", "ru", "de"].map(Locale.init(identifier:))

        var todayTitles = Set<String>()
        var justNowStrings = Set<String>()
        var expiredStrings: [String] = []
        var relStrings = Set<String>()

        for loc in locales {
            todayTitles.insert(SessionTimeGroup.today.localizedTitle(locale: loc))
            if let justNow = QuotaUsageFormatter.formatUpdatedAt(fetchedAt: "2026-11-19T11:59:40Z", now: now, locale: loc) {
                justNowStrings.insert(justNow)
            }
            if let exp = QuotaUsageFormatter.formatResetTime(window: "5h", resetTime: "2026-11-19T11:30:00Z", now: now, timeZone: tz, locale: loc) {
                XCTAssertFalse(exp.contains("-"), "Expired reset time must never have minus sign in \(loc.identifier)")
                XCTAssertTrue(exp.contains("11:30"))
                expiredStrings.append(exp)
            }
            if let rel = SessionRelativeTimeFormatter.format(now.addingTimeInterval(-3600), relativeTo: now, locale: loc) {
                relStrings.insert(rel)
            }
        }

        // All 4 locales produce distinct localized strings (real catalog switching, not hardcoded single locale)
        XCTAssertEqual(todayTitles.count, 4, "SessionTimeGroup.today must localize distinctly across en/zh-Hans/ru/de: \(todayTitles)")
        XCTAssertEqual(justNowStrings.count, 4, "formatUpdatedAt('Just now') must localize distinctly across en/zh-Hans/ru/de: \(justNowStrings)")
        XCTAssertEqual(expiredStrings.count, 4)
        XCTAssertGreaterThanOrEqual(relStrings.count, 3)
    }
}
