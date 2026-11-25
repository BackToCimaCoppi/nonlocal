import XCTest
import CoreData
import ACP
@testable import Agmente
import ACPClient

/// CASE-DATA-01: Real on-disk SQLite lightweight migration (v1->v3 & v2->v3), v3 metadata cleanliness,
/// deprecated UserDefaults & dual-root Codex log cleanup, and legacy clientId migration + 0-server defaults.
/// Covers SC-AC-032, SC-AC-033, SC-AC-034, SC-AC-035, SC-AC-036.
@MainActor
final class CoreDataV3MigrationTests: XCTestCase {

    private var tempDirs: [URL] = []
    private var suiteNames: [String] = []

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(at: dir)
        }
        tempDirs.removeAll()
        for suite in suiteNames {
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreDataV3MigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDirs.append(dir)
        return dir
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "CoreDataV3MigrationTests.\(UUID().uuidString)"
        suiteNames.append(suite)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func unloadStores(of container: NSPersistentContainer) throws {
        let coordinator = container.persistentStoreCoordinator
        for store in coordinator.persistentStores {
            try coordinator.remove(store)
        }
    }

    // MARK: - SC-AC-032: Real on-disk SQLite v1 -> v3 lightweight migration (with token == nil & deprecated columns + Item)

    func testSCAC032_RealDiskSQLiteV1ToV3MigrationWithNilToken() throws {
        let dir = try makeTempDir()
        let storeURL = dir.appendingPathComponent("Agmente-v1.sqlite")
        let v1Model = try XCTUnwrap(
            PersistenceController.model(versionName: "Agmente"),
            "SC-AC-032: Agmente.mom (v1) must exist inside Agmente.momd"
        )

        let serverId = UUID()
        let msgId = UUID()
        let sessionUpdated = Date(timeIntervalSince1970: 1_760_001_000)
        let msgCreated = Date(timeIntervalSince1970: 1_760_001_100)

        do {
            let v1Persistence = PersistenceController(storeURL: storeURL, managedObjectModel: v1Model)
            let ctx = v1Persistence.container.viewContext

            let item = NSEntityDescription.insertNewObject(forEntityName: "Item", into: ctx)
            item.setValue(Date(timeIntervalSince1970: 1_760_000_000), forKey: "timestamp")

            let server = NSEntityDescription.insertNewObject(forEntityName: "StoredServer", into: ctx)
            server.setValue(serverId, forKey: "id")
            server.setValue("Legacy V1 Bridge", forKey: "name")
            server.setValue("ws", forKey: "scheme")
            server.setValue("127.0.0.1:8765", forKey: "host")
            server.setValue(nil, forKey: "token")
            server.setValue("acp", forKey: "serverType")
            server.setValue("cid-v1", forKey: "cfAccessClientId")
            server.setValue("sec-v1", forKey: "cfAccessClientSecret")
            server.setValue("/work/v1", forKey: "workingDirectory")

            let session = NSEntityDescription.insertNewObject(forEntityName: "StoredSession", into: ctx)
            session.setValue("sess-v1-1", forKey: "sessionId")
            session.setValue("V1 Session", forKey: "title")
            session.setValue("/work/v1", forKey: "cwd")
            session.setValue(sessionUpdated, forKey: "updatedAt")
            session.setValue(server, forKey: "server")

            let message = NSEntityDescription.insertNewObject(forEntityName: "StoredMessage", into: ctx)
            message.setValue(msgId, forKey: "messageId")
            message.setValue("assistant", forKey: "role")
            message.setValue("Hello from v1", forKey: "content")
            message.setValue(msgCreated, forKey: "createdAt")
            message.setValue(Int32(0), forKey: "orderIndex")
            message.setValue(session, forKey: "session")

            try ctx.save()
            try unloadStores(of: v1Persistence.container)
        }

        // Reopen with default current model (Agmente v3)
        let v3Persistence = PersistenceController(storeURL: storeURL)
        defer { try? unloadStores(of: v3Persistence.container) }
        let storage = SessionStorage(container: v3Persistence.container)

        let servers = storage.fetchServers()
        XCTAssertEqual(servers.count, 1)
        let migrated = try XCTUnwrap(servers.first)
        XCTAssertEqual(migrated.id, serverId)
        XCTAssertEqual(migrated.name, "Legacy V1 Bridge")
        XCTAssertEqual(migrated.scheme, "ws")
        XCTAssertEqual(migrated.host, "127.0.0.1:8765")
        XCTAssertEqual(migrated.workingDirectory, "/work/v1")
        XCTAssertEqual(migrated.token, "")

        // Verify raw Core Data StoredServer.token remained nil without crashing
        let rawReq = NSFetchRequest<NSManagedObject>(entityName: "StoredServer")
        let rawServers = try v3Persistence.container.viewContext.fetch(rawReq)
        XCTAssertEqual(rawServers.count, 1)
        XCTAssertNil(rawServers.first?.value(forKey: "token"))

        let sessions = storage.fetchSessions(forServerId: serverId)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.sessionId, "sess-v1-1")
        XCTAssertEqual(sessions.first?.title, "V1 Session")
        XCTAssertEqual(sessions.first?.cwd, "/work/v1")
        XCTAssertEqual(sessions.first?.updatedAt, sessionUpdated)

        let messages = storage.fetchMessages(forSessionId: "sess-v1-1", serverId: serverId)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.messageId, msgId)
        XCTAssertEqual(messages.first?.role, "assistant")
        XCTAssertEqual(messages.first?.content, "Hello from v1")
    }

    // MARK: - SC-AC-033: Real on-disk SQLite v2 -> v3 column-by-column migration & UserDefaults UUID identity

    func testSCAC033_RealDiskSQLiteV2ToV3ColumnByColumnAndAssociatedDefaults() throws {
        let dir = try makeTempDir()
        let storeURL = dir.appendingPathComponent("Agmente-v2.sqlite")
        let defaults = makeIsolatedDefaults()
        let v2Model = try XCTUnwrap(
            PersistenceController.model(versionName: "Agmente v2"),
            "SC-AC-033: Agmente v2.mom must exist inside Agmente.momd"
        )

        let serverIdA = UUID()
        let serverIdB = UUID()
        let msgIdA = UUID()
        let sessionUpdated = Date(timeIntervalSince1970: 1_760_010_000)
        let lastSeenDate = Date(timeIntervalSince1970: 1_760_009_000)
        let msgCreated = Date(timeIntervalSince1970: 1_760_010_050)
        let segData = Data("{\"kind\":\"message\"}".utf8)
        let usedDirsArray: NSArray = ["/repo", "/work/b"]

        // Pre-seed UserDefaults associated stores keyed by serverIdA
        let projectStoreBefore = ProjectStore(defaults: defaults)
        _ = try projectStoreBefore.createProject(name: "Nonlocal", serverId: serverIdA, initialDirectory: "/repo")

        let modelPrefsBefore = DefaultModelPreferences(defaults: defaults)
        modelPrefsBefore.save(modelId: "claude-opus-5-5", thoughtLevel: "high", for: serverIdA)

        let quotaStoreBefore = QuotaUsageStore(defaults: defaults)
        let quotaSnap = NonlocalUsageResult(
            fetchedAt: "2026-11-21T00:00:00Z",
            ageSeconds: 0,
            ttlSeconds: 180,
            refreshing: false,
            tier: NonlocalUsageTier(name: "Pro", id: "pro"),
            groups: [
                NonlocalUsageGroup(
                    name: "Claude",
                    buckets: [
                        NonlocalUsageBucket(
                            id: "b1",
                            name: "5h",
                            window: "5h",
                            remainingFraction: 0.85,
                            resetTime: nil
                        )
                    ]
                )
            ],
            lastError: nil
        )
        quotaStoreBefore.save(PersistedQuotaUsageRecord(hasConfirmedQuotaSupport: true, snapshot: quotaSnap), for: serverIdA)

        do {
            let v2Persistence = PersistenceController(storeURL: storeURL, managedObjectModel: v2Model)
            let ctx = v2Persistence.container.viewContext

            let item = NSEntityDescription.insertNewObject(forEntityName: "Item", into: ctx)
            item.setValue(Date(timeIntervalSince1970: 1_760_000_000), forKey: "timestamp")

            let sA = NSEntityDescription.insertNewObject(forEntityName: "StoredServer", into: ctx)
            sA.setValue(serverIdA, forKey: "id")
            sA.setValue("Mac Mini", forKey: "name")
            sA.setValue("wss", forKey: "scheme")
            sA.setValue("mini.example.test", forKey: "host")
            sA.setValue("tok-v2", forKey: "token")
            sA.setValue("acp", forKey: "serverType")
            sA.setValue("cf-id-a", forKey: "cfAccessClientId")
            sA.setValue("cf-sec-a", forKey: "cfAccessClientSecret")
            sA.setValue("/repo", forKey: "workingDirectory")
            sA.setValue(usedDirsArray, forKey: "usedWorkingDirectories")
            sA.setValue(true, forKey: "hasInitializedUnreadBaseline")

            let sB = NSEntityDescription.insertNewObject(forEntityName: "StoredServer", into: ctx)
            sB.setValue(serverIdB, forKey: "id")
            sB.setValue("Office", forKey: "name")
            sB.setValue("ws", forKey: "scheme")
            sB.setValue("127.0.0.1:8765", forKey: "host")
            sB.setValue("tok-b", forKey: "token")
            sB.setValue("acp", forKey: "serverType")
            sB.setValue("", forKey: "cfAccessClientId")
            sB.setValue("", forKey: "cfAccessClientSecret")
            sB.setValue("~", forKey: "workingDirectory")
            sB.setValue(false, forKey: "hasInitializedUnreadBaseline")

            let sess = NSEntityDescription.insertNewObject(forEntityName: "StoredSession", into: ctx)
            sess.setValue("sess-v2-full", forKey: "sessionId")
            sess.setValue("Full 7 Cols", forKey: "title")
            sess.setValue("/repo", forKey: "cwd")
            sess.setValue(sessionUpdated, forKey: "updatedAt")
            sess.setValue(true, forKey: "hasUnread")
            sess.setValue(lastSeenDate, forKey: "lastSeenServerUpdatedAt")
            sess.setValue(true, forKey: "absorbNextServerUpdatedAt")
            sess.setValue(sA, forKey: "server")

            let msg = NSEntityDescription.insertNewObject(forEntityName: "StoredMessage", into: ctx)
            msg.setValue(msgIdA, forKey: "messageId")
            msg.setValue("assistant", forKey: "role")
            msg.setValue("Migrated reply", forKey: "content")
            msg.setValue(msgCreated, forKey: "createdAt")
            msg.setValue(Int32(3), forKey: "orderIndex")
            msg.setValue(true, forKey: "isError")
            msg.setValue(segData, forKey: "segmentsData")
            msg.setValue(sess, forKey: "session")

            try ctx.save()
            try unloadStores(of: v2Persistence.container)
        }

        // Open with default Agmente v3 model
        let v3Persistence = PersistenceController(storeURL: storeURL)
        defer { try? unloadStores(of: v3Persistence.container) }
        let storage = SessionStorage(container: v3Persistence.container)

        let servers = storage.fetchServers()
        XCTAssertEqual(servers.count, 2)
        let migratedA = try XCTUnwrap(servers.first(where: { $0.id == serverIdA }))
        let migratedB = try XCTUnwrap(servers.first(where: { $0.id == serverIdB }))
        XCTAssertEqual(migratedA.name, "Mac Mini")
        XCTAssertEqual(migratedA.scheme, "wss")
        XCTAssertEqual(migratedA.host, "mini.example.test")
        XCTAssertEqual(migratedA.token, "tok-v2")
        XCTAssertEqual(migratedA.workingDirectory, "/repo")
        XCTAssertEqual(storage.fetchUsedWorkingDirectories(forServerId: migratedA.id), ["/repo", "/work/b"])
        XCTAssertTrue(storage.isUnreadBaselineInitialized(forServerId: migratedA.id))

        XCTAssertEqual(migratedB.name, "Office")
        XCTAssertEqual(migratedB.token, "tok-b")
        XCTAssertFalse(storage.isUnreadBaselineInitialized(forServerId: migratedB.id))

        // Verify all 7 StoredSession columns
        let sessions = storage.fetchSessions(forServerId: migratedA.id)
        XCTAssertEqual(sessions.count, 1)
        let migratedSess = try XCTUnwrap(sessions.first)
        XCTAssertEqual(migratedSess.sessionId, "sess-v2-full")
        XCTAssertEqual(migratedSess.title, "Full 7 Cols")
        XCTAssertEqual(migratedSess.cwd, "/repo")
        XCTAssertEqual(migratedSess.updatedAt, sessionUpdated)
        XCTAssertEqual(migratedSess.hasUnread, true)
        XCTAssertEqual(migratedSess.lastSeenServerUpdatedAt, lastSeenDate)
        XCTAssertEqual(migratedSess.absorbNextServerUpdatedAt, true)

        // Verify all 7 StoredMessage columns (including orderIndex via raw NSManagedObject)
        let messages = storage.fetchMessages(forSessionId: "sess-v2-full", serverId: migratedA.id)
        XCTAssertEqual(messages.count, 1)
        let migratedMsg = try XCTUnwrap(messages.first)
        XCTAssertEqual(migratedMsg.messageId, msgIdA)
        XCTAssertEqual(migratedMsg.role, "assistant")
        XCTAssertEqual(migratedMsg.content, "Migrated reply")
        XCTAssertEqual(migratedMsg.createdAt, msgCreated)
        XCTAssertEqual(migratedMsg.isError, true)
        XCTAssertEqual(migratedMsg.segmentsData, segData)

        let rawMsgReq = NSFetchRequest<NSManagedObject>(entityName: "StoredMessage")
        let rawMsg = try XCTUnwrap(try v3Persistence.container.viewContext.fetch(rawMsgReq).first)
        XCTAssertEqual(rawMsg.value(forKey: "orderIndex") as? Int32, 3)

        // Verify associated UserDefaults stores resolve identically using migrated serverIdA
        let projectStoreAfter = ProjectStore(defaults: defaults)
        let projects = projectStoreAfter.projects(for: migratedA.id)
        XCTAssertEqual(projects.count, 1)
        XCTAssertEqual(projects.first?.name, "Nonlocal")
        XCTAssertEqual(projects.first?.directories, ["/repo"])

        let modelPrefsAfter = DefaultModelPreferences(defaults: defaults)
        let choice = modelPrefsAfter.selection(for: migratedA.id)
        XCTAssertEqual(choice.modelId, "claude-opus-5-5")
        XCTAssertEqual(choice.thoughtLevel, "high")

        let quotaStoreAfter = QuotaUsageStore(defaults: defaults)
        let record = try XCTUnwrap(quotaStoreAfter.load(for: migratedA.id))
        XCTAssertTrue(record.hasConfirmedQuotaSupport)
        XCTAssertEqual(record.snapshot?.groups.first?.buckets.first?.remainingFraction, 0.85)
    }

    // MARK: - SC-AC-034: Agmente v3 schema metadata cleanliness & v1/v2 .mom preservation

    func testSCAC034_V3SchemaMetadataAndLegacyMomPresence() throws {
        let model = PersistenceController.managedObjectModel

        XCTAssertNil(model.entitiesByName["Item"], "SC-AC-034: Item entity must be removed from v3")

        let storedServer = try XCTUnwrap(model.entitiesByName["StoredServer"])
        let attrs = storedServer.attributesByName
        XCTAssertNil(attrs["serverType"], "SC-AC-034: serverType must be removed from v3")
        XCTAssertNil(attrs["cfAccessClientId"], "SC-AC-034: cfAccessClientId must be removed from v3")
        XCTAssertNil(attrs["cfAccessClientSecret"], "SC-AC-034: cfAccessClientSecret must be removed from v3")
        let tokenAttr = try XCTUnwrap(attrs["token"])
        XCTAssertTrue(tokenAttr.isOptional, "SC-AC-034: StoredServer.token must remain optional=YES for v1 migration")

        XCTAssertNotNil(PersistenceController.model(versionName: "Agmente"), "SC-AC-034: Agmente.mom (v1) must be preserved")
        XCTAssertNotNil(PersistenceController.model(versionName: "Agmente v2"), "SC-AC-034: Agmente v2.mom must be preserved")

        let inMem = PersistenceController(inMemory: true)
        XCTAssertEqual(inMem.container.name, "Agmente", "SC-AC-034: Core Data container name must remain 'Agmente'")
    }

    // MARK: - SC-AC-035: One-time cleanup of 4 deprecated UserDefaults keys + dual-root Codex logs (with protected controls)

    func testSCAC035_StartupCleanupRemovesDeprecatedKeysAndDualRootCodexLogsOnly() throws {
        let defaults = makeIsolatedDefaults()
        let rootDir = try makeTempDir()
        let fakeAppSupport = rootDir.appendingPathComponent("AppSupport", isDirectory: true)
        let fakeTemp = rootDir.appendingPathComponent("Temp", isDirectory: true)
        let fm = FileManager.default

        // Deprecated keys
        defaults.set(true, forKey: "Agmente.codexSessionLoggingEnabled")
        defaults.set(true, forKey: "Agmente.useHighPerformanceChatRenderer")
        defaults.set(true, forKey: "summaryCardCollapsed")
        let presetKey = "Agmente.codexPermissionPreset.\(UUID().uuidString)"
        defaults.set("full-auto", forKey: presetKey)

        // Protected keys
        let lastServerId = UUID().uuidString
        defaults.set(lastServerId, forKey: "Agmente.lastServerId")
        defaults.set(true, forKey: "Agmente.devModeEnabled")
        defaults.set("[]", forKey: "nonlocal.serverProjects.v1")
        defaults.set(true, forKey: "antigravityQuotaCardCollapsed")

        // Deprecated & protected files in simulated applicationSupportDirectory
        let codexLogDir = fakeAppSupport
            .appendingPathComponent("Agmente/logs/codex", isDirectory: true)
        try fm.createDirectory(at: codexLogDir, withIntermediateDirectories: true)
        let codexLogFile = codexLogDir.appendingPathComponent("a.log")
        try Data("codex-log".utf8).write(to: codexLogFile)

        let protectedAppSupportFile = fakeAppSupport
            .appendingPathComponent("Agmente/other.txt")
        try Data("keep".utf8).write(to: protectedAppSupportFile)

        // Deprecated & protected files in simulated temporaryDirectory
        let stagingDir = fakeTemp.appendingPathComponent("codex-logs-staging-1", isDirectory: true)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        let stagingZip = stagingDir.appendingPathComponent("b.zip")
        try Data("zip".utf8).write(to: stagingZip)

        let protectedTempFile = fakeTemp.appendingPathComponent("keep.tmp")
        try Data("keep-tmp".utf8).write(to: protectedTempFile)

        AppViewModel.cleanupLegacyArtifactsIfNeeded(
            defaults: defaults,
            applicationSupportURL: fakeAppSupport,
            temporaryDirectoryURL: fakeTemp,
            fileManager: fm
        )

        // Deprecated keys gone
        XCTAssertNil(defaults.object(forKey: "Agmente.codexSessionLoggingEnabled"))
        XCTAssertNil(defaults.object(forKey: "Agmente.useHighPerformanceChatRenderer"))
        XCTAssertNil(defaults.object(forKey: "summaryCardCollapsed"))
        XCTAssertNil(defaults.object(forKey: presetKey))

        // Protected keys intact
        XCTAssertEqual(defaults.string(forKey: "Agmente.lastServerId"), lastServerId)
        XCTAssertEqual(defaults.bool(forKey: "Agmente.devModeEnabled"), true)
        XCTAssertEqual(defaults.string(forKey: "nonlocal.serverProjects.v1"), "[]")
        XCTAssertEqual(defaults.bool(forKey: "antigravityQuotaCardCollapsed"), true)

        // Both deprecated directories removed; both protected files intact
        XCTAssertFalse(fm.fileExists(atPath: codexLogDir.path))
        XCTAssertTrue(fm.fileExists(atPath: protectedAppSupportFile.path))
        XCTAssertFalse(fm.fileExists(atPath: stagingDir.path))
        XCTAssertTrue(fm.fileExists(atPath: protectedTempFile.path))
    }

    // MARK: - SC-AC-036: Legacy Agmente.clientId migration + 0-server safe default connection properties + first-add X-Client-Id

    func testSCAC036_LegacyClientIdMigrationAndZeroServerDefaults() async throws {
        let defaults = makeIsolatedDefaults()
        let legacyTimestamp: TimeInterval = 1_760_050_000
        defaults.set("legacy-cid-99", forKey: "Agmente.clientId")
        defaults.set(legacyTimestamp, forKey: "Agmente.lastConnectedAt")

        let storage = SessionStorage.inMemory()
        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )

        // 1. Legacy clientId & lastConnectedAt migrated
        XCTAssertEqual(defaults.string(forKey: "ACPClientManager.clientId"), "legacy-cid-99")
        XCTAssertEqual(defaults.double(forKey: "ACPClientManager.lastConnectedAt"), legacyTimestamp)

        // 2. Zero-server safe default properties
        XCTAssertTrue(appVM.servers.isEmpty)
        XCTAssertNil(appVM.selectedServerId)
        XCTAssertEqual(appVM.connectionState, .disconnected)
        XCTAssertFalse(appVM.isConnecting)
        XCTAssertTrue(appVM.isNetworkAvailable)
        XCTAssertNil(appVM.lastConnectedAt)
        XCTAssertFalse(appVM.wasPreempted)
        XCTAssertNil(appVM.service)

        // 3. First-time add with 0 servers sends X-Client-Id: legacy-cid-99
        final class HeaderCapturingSocket: WebSocketConnection, @unchecked Sendable {
            private let lock = NSLock()
            private(set) var capturedHeaders: [String: String] = [:]
            private var incoming: [WebSocketEvent] = []
            private var cont: CheckedContinuation<WebSocketEvent, Error>?

            func connect(headers: [String: String]) async throws {
                lock.lock()
                capturedHeaders = headers
                lock.unlock()
            }

            func send(text: String) async throws {
                guard let data = text.data(using: .utf8),
                      let wire = try? JSONDecoder().decode(ACPWireMessage.self, from: data),
                      case .request(let req) = wire else { return }
                let result: ACP.Value
                if req.method == "initialize" {
                    result = .object([
                        "protocolVersion": .int(1),
                        "agentInfo": .object(["name": .string("agy"), "version": .string("1.0")]),
                        "agentCapabilities": .object(["loadSession": .bool(true), "listSessions": .bool(true)])
                    ])
                } else {
                    result = .object(["instanceId": .string("inst-first"), "activeTurns": .array([])])
                }
                let resp = ACPWireMessage.response(.init(id: req.id, result: result))
                let encoded = try JSONEncoder().encode(resp)
                let event = WebSocketEvent.text(String(decoding: encoded, as: UTF8.self))
                lock.lock()
                if let c = cont {
                    cont = nil
                    lock.unlock()
                    c.resume(returning: event)
                } else {
                    incoming.append(event)
                    lock.unlock()
                }
            }

            func receive() async throws -> WebSocketEvent {
                try await withCheckedThrowingContinuation { c in
                    lock.lock()
                    if !incoming.isEmpty {
                        let ev = incoming.removeFirst()
                        lock.unlock()
                        c.resume(returning: ev)
                    } else {
                        cont = c
                        lock.unlock()
                    }
                }
            }

            func close() async {
                lock.lock()
                let c = cont
                cont = nil
                lock.unlock()
                c?.resume(returning: .closed(WebSocketCloseReason(code: 1000)))
            }

            func ping() async throws {}
        }

        final class SingleProvider: WebSocketProviding {
            let conn: HeaderCapturingSocket
            init(_ conn: HeaderCapturingSocket) { self.conn = conn }
            func makeConnection(url: URL) -> WebSocketConnection { conn }
        }

        let socket = HeaderCapturingSocket()
        let validator = BridgeServerValidator(defaults: defaults) { config in
            ACPService(client: ACPClient(configuration: config, socketProvider: SingleProvider(socket)))
        }
        let result = await validator.validate(
            name: "First Bridge",
            scheme: "ws",
            host: "127.0.0.1:18765",
            token: "tok-first",
            workingDirectory: "~",
            clientName: "Agmente iOS",
            clientVersion: "0.1.0",
            supportsFSRead: false,
            supportsFSWrite: false,
            supportsTerminal: false
        )
        switch result {
        case .success(let validated):
            XCTAssertEqual(validated.token, "tok-first")
        case .failure(let error):
            XCTFail("Expected validation success on 0-server first add, got: \(error)")
        }
        XCTAssertEqual(socket.capturedHeaders["X-Client-Id"], "legacy-cid-99")
    }
}
