import XCTest
import ACP
import ACPClient
@testable import Agmente

@MainActor
final class DefaultModelPreferencesTests: XCTestCase {
    private func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "com.nonlocal.tests.default-model.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func makeConfigOptions(
        currentModel: String,
        modelChoices: [(String, String)],
        currentThought: String? = nil,
        thoughtChoices: [(String, String)]? = nil
    ) -> [ACPSessionConfigOption] {
        var options: [ACPSessionConfigOption] = [
            ACPSessionConfigOption(
                id: ACPModelConfig.configId,
                name: "Model",
                description: nil,
                category: "model",
                kind: .select(options: modelChoices.map { ACPSessionConfigOptionChoice(id: $0.0, name: $0.1, description: nil) }),
                currentValue: .string(currentModel)
            )
        ]
        if let currentThought, let thoughtChoices {
            options.append(
                ACPSessionConfigOption(
                    id: "thought_level",
                    name: "Thinking Level",
                    description: nil,
                    category: "thought_level",
                    kind: .select(options: thoughtChoices.map { ACPSessionConfigOptionChoice(id: $0.0, name: $0.1, description: nil) }),
                    currentValue: .string(currentThought)
                )
            )
        }
        return options
    }

    // MARK: - AC-6: Factory Defaults, Per-Server Isolation, Catalog & Thought-Level Filtering

    func testFactoryDefaultsAndPerServerIsolation() {
        let defaults = makeIsolatedDefaults()
        let prefs = DefaultModelPreferences(defaults: defaults)
        let serverA = UUID()
        let serverB = UUID()

        // Factory defaults for unconfigured servers: Gemini 4 Neon + Medium
        XCTAssertEqual(prefs.selection(for: serverA), DefaultModelSelection(modelId: "gemini-4-neon", thoughtLevel: "medium"))
        XCTAssertEqual(prefs.selection(for: serverB), DefaultModelSelection(modelId: "gemini-4-neon", thoughtLevel: "medium"))

        // Mutating server B must NOT affect server A
        prefs.save(modelId: "claude-opus-5-5", thoughtLevel: "high", for: serverB)
        XCTAssertEqual(prefs.selection(for: serverA), DefaultModelSelection(modelId: "gemini-4-neon", thoughtLevel: "medium"))
        XCTAssertEqual(prefs.selection(for: serverB), DefaultModelSelection(modelId: "claude-opus-5-5", thoughtLevel: "high"))

        // Reload with fresh wrapper over same UserDefaults
        let reloaded = DefaultModelPreferences(defaults: defaults)
        XCTAssertEqual(reloaded.selection(for: serverB), DefaultModelSelection(modelId: "claude-opus-5-5", thoughtLevel: "high"))
    }

    func testServerCatalogPreferenceAndThoughtLevelFiltering() {
        let defaults = makeIsolatedDefaults()
        let prefs = DefaultModelPreferences(defaults: defaults)
        let serverId = UUID()

        // Without server cache -> falls back to builtInModels
        let fallbackCatalog = DefaultModelPreferences.catalog(fromServerConfigOptions: nil)
        XCTAssertTrue(fallbackCatalog.contains(where: { $0.id == "gemini-4-neon" }))

        // With server cache -> prefers that server's models and never borrows thought_level across models
        let serverOptions = makeConfigOptions(
            currentModel: "gemini-4-hydrogen",
            modelChoices: [
                ("gemini-4-hydrogen", "Gemini 4 Hydrogen"),
                ("gemini-4-carbon", "Gemini 4 Carbon"),
                ("gemini-pro-orchestrator-neon", "Orchestrator (Neon)"),
                ("brand-new-model-x", "Brand New Model X"),
            ],
            currentThought: "xhigh",
            thoughtChoices: [
                ("low", "Low"),
                ("medium", "Medium"),
                ("high", "High"),
                ("xhigh", "XHigh"),
            ]
        )
        let catalog = DefaultModelPreferences.catalog(fromServerConfigOptions: serverOptions)
        XCTAssertEqual(catalog.map(\.id), ["gemini-4-hydrogen", "gemini-4-carbon", "gemini-pro-orchestrator-neon", "brand-new-model-x"])

        // Carbon must NOT inherit xhigh from active Hydrogen; xhigh falls back to medium
        let carbonLevels = catalog.first(where: { $0.id == "gemini-4-carbon" })?.thoughtLevels.map(\.id) ?? []
        XCTAssertEqual(carbonLevels, ["low", "medium", "high"])
        XCTAssertEqual(
            DefaultModelPreferences.resolvedThoughtLevel(preferred: "xhigh", forModelId: "gemini-4-carbon", in: catalog),
            "medium"
        )

        // No-thought-level model and unknown new model have empty thought levels and omit thought key in _meta
        XCTAssertTrue((catalog.first(where: { $0.id == "gemini-pro-orchestrator-neon" })?.thoughtLevels ?? []).isEmpty)
        XCTAssertTrue((catalog.first(where: { $0.id == "brand-new-model-x" })?.thoughtLevels ?? []).isEmpty)

        prefs.save(modelId: "gemini-pro-orchestrator-neon", thoughtLevel: nil, for: serverId)
        let orchestratorMeta = prefs.sessionCreateMeta(for: serverId, serverConfigOptions: serverOptions)
        XCTAssertEqual(orchestratorMeta[NonlocalMethods.defaultModelMetaKey]?.stringValue, "gemini-pro-orchestrator-neon")
        XCTAssertNil(orchestratorMeta[NonlocalMethods.defaultThoughtLevelMetaKey])

        prefs.save(modelId: "brand-new-model-x", thoughtLevel: "high", for: serverId)
        let unknownMeta = prefs.sessionCreateMeta(for: serverId, serverConfigOptions: serverOptions)
        XCTAssertEqual(unknownMeta[NonlocalMethods.defaultModelMetaKey]?.stringValue, "brand-new-model-x")
        XCTAssertNil(unknownMeta[NonlocalMethods.defaultThoughtLevelMetaKey])
    }

    // MARK: - SC-AC-047: Per-Server _meta Isolation & Pure _meta Lazy Creation (0 set_config_option fallback)

    func testSCAC047_PerServerMetaIsolation() {
        let defaults = makeIsolatedDefaults()
        let prefs = DefaultModelPreferences(defaults: defaults)
        let serverA = UUID()
        let serverB = UUID()

        prefs.save(modelId: "gemini-4-neon", thoughtLevel: "medium", for: serverA)
        prefs.save(modelId: "claude-opus-5-5", thoughtLevel: "high", for: serverB)

        // Server B _meta must carry B's settings, never A's
        let metaA = prefs.sessionCreateMeta(for: serverA)
        let metaB = prefs.sessionCreateMeta(for: serverB)
        XCTAssertEqual(metaA[NonlocalMethods.defaultModelMetaKey]?.stringValue, "gemini-4-neon")
        XCTAssertEqual(metaA[NonlocalMethods.defaultThoughtLevelMetaKey]?.stringValue, "medium")
        XCTAssertEqual(metaB[NonlocalMethods.defaultModelMetaKey]?.stringValue, "claude-opus-5-5")
        XCTAssertEqual(metaB[NonlocalMethods.defaultThoughtLevelMetaKey]?.stringValue, "high")
    }

    func testSCAC047_SendPromptLazyCreateUsesPureMetaWithoutFallbackAndLoadNeverOverrides() async throws {
        let defaults = makeIsolatedDefaults()
        let serverA = UUID()
        let serverB = UUID()
        let prefs = DefaultModelPreferences(defaults: defaults)
        prefs.save(modelId: "gemini-4-neon", thoughtLevel: "medium", for: serverA)
        prefs.save(modelId: "claude-opus-5-5", thoughtLevel: "high", for: serverB)

        // Fake WebSocket transport recording exact RPC order for serverB lazy session creation + prompt.
        let transport = RecordingACPTransport { request in
            switch request.method {
            case "session/new":
                return ACP.AnyResponse(
                    id: request.id,
                    result: .object([
                        "sessionId": .string("srvB-sess-1"),
                        "cwd": .string("/tmp"),
                        "configOptions": .array([
                            .object([
                                "id": .string("model"),
                                "name": .string("Model"),
                                "type": .string("select"),
                                "currentValue": .string("gemini-4-argon"),
                                "options": .array([
                                    .object(["value": .string("gemini-4-argon"), "name": .string("Argon")]),
                                    .object(["value": .string("claude-opus-5-5"), "name": .string("Claude Opus 5.5")]),
                                ]),
                            ]),
                            .object([
                                "id": .string("thought_level"),
                                "name": .string("Thinking Level"),
                                "type": .string("select"),
                                "currentValue": .string("low"),
                                "options": .array([
                                    .object(["value": .string("low"), "name": .string("Low")]),
                                    .object(["value": .string("medium"), "name": .string("Medium")]),
                                    .object(["value": .string("high"), "name": .string("High")]),
                                ]),
                            ]),
                        ]),
                    ])
                )
            case "session/set_config_option":
                return ACP.AnyResponse(id: request.id, result: .object([:]))
            case "session/prompt":
                return ACP.AnyResponse(id: request.id, result: .object(["stopReason": .string("end_turn")]))
            default:
                return ACP.AnyResponse(id: request.id, result: .object([:]))
            }
        }

        let client = ACPClient(
            configuration: ACPClientConfiguration(endpoint: URL(string: "ws://127.0.0.1:1")!),
            socketProvider: transport
        )
        let service = ACPService(client: client)
        let manager = ACPClientManager(
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            serviceFactory: { _, _ in service }
        )
        let connected = await manager.connectAndWait(
            config: ACPConnectionConfig(endpoint: URL(string: "ws://127.0.0.1:1")!)
        )
        XCTAssertTrue(connected)
        let initialized = await manager.initializeAndWait(
            payload: ACPInitializationPayload(protocolVersion: 1, clientName: "Test", clientVersion: "1.0")
        )
        XCTAssertTrue(initialized)

        let serverVM = ServerViewModel(
            id: serverB,
            name: "Server B",
            scheme: "ws",
            host: "127.0.0.1:1",
            token: "",
            workingDirectory: "/tmp",
            connectionManager: manager,
            getService: { manager.service },
            append: { _ in },
            logWire: { _, _ in }
        )
        serverVM.defaultModelPreferences = prefs

        // sendNewSession starts creatingSessionTasks[placeholderId] asynchronously;
        // calling sendPrompt immediately must await session/new + fallback config updates BEFORE session/prompt.
        serverVM.sendNewSession(workingDirectory: "/tmp")
        let placeholderId = serverVM.selectedSessionId ?? serverVM.sessionId
        XCTAssertFalse(placeholderId.isEmpty)
        let sessionVM = serverVM.sessionViewModel(for: placeholderId)
        sessionVM.promptText = "hello"

        serverVM.sendPrompt(promptText: "hello", images: [], commandName: nil)

        // Wait until session/prompt has been dispatched
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            if transport.recordedRequests.contains(where: { $0.method == "session/prompt" }) {
                break
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        let postInitRequests = transport.recordedRequests.filter { $0.method != "initialize" }
        let methods = postInitRequests.map(\.method)
        XCTAssertEqual(
            methods,
            [
                "session/new",
                "session/prompt",
            ],
            "SC-AC-047: Single-bridge lazy session creation sends _meta on session/new and 0 fallback session/set_config_option requests before session/prompt"
        )
        guard !postInitRequests.isEmpty else {
            await manager.disconnect()
            return
        }

        // Verify session/new carried serverB's _meta (not serverA's)
        let newParams = postInitRequests[0].params.objectValue
        let newMeta = newParams?["_meta"]?.objectValue
        XCTAssertEqual(newMeta?[NonlocalMethods.defaultModelMetaKey]?.stringValue, "claude-opus-5-5")
        XCTAssertEqual(newMeta?[NonlocalMethods.defaultThoughtLevelMetaKey]?.stringValue, "high")

        // Opening an existing historical session via session/load must NEVER emit set_config_option
        let countBeforeLoad = transport.recordedRequests.count
        _ = try await service.loadSession(ACPSessionLoadPayload(sessionId: "old-hist-1", workingDirectory: "/tmp"))
        let afterLoadMethods = transport.recordedRequests.dropFirst(countBeforeLoad).map(\.method)
        XCTAssertEqual(afterLoadMethods, ["session/load"])

        await manager.disconnect()
    }
}

private final class RecordingACPTransport: WebSocketProviding, @unchecked Sendable {
    final class Connection: WebSocketConnection, @unchecked Sendable {
        private let handler: (ACP.AnyRequest) -> ACP.AnyResponse
        private let onRequest: (ACP.AnyRequest) -> Void
        private let lock = NSLock()
        private var queue: [WebSocketEvent] = []
        private var waiter: CheckedContinuation<WebSocketEvent, Error>?
        private var closed = false

        init(handler: @escaping (ACP.AnyRequest) -> ACP.AnyResponse, onRequest: @escaping (ACP.AnyRequest) -> Void) {
            self.handler = handler
            self.onRequest = onRequest
        }

        private func enqueue(_ event: WebSocketEvent) {
            lock.lock()
            if let cont = waiter {
                waiter = nil
                lock.unlock()
                cont.resume(returning: event)
            } else {
                queue.append(event)
                lock.unlock()
            }
        }

        func connect(headers: [String: String]) async throws {
            enqueue(.connected)
        }

        func send(text: String) async throws {
            guard let data = text.data(using: .utf8),
                  let req = try? JSONDecoder().decode(ACP.AnyRequest.self, from: data) else {
                return
            }
            onRequest(req)
            let resp = handler(req)
            let encoded = try JSONEncoder().encode(resp)
            if let str = String(data: encoded, encoding: .utf8) {
                enqueue(.text(str))
            }
        }

        func receive() async throws -> WebSocketEvent {
            try await withCheckedThrowingContinuation { cont in
                lock.lock()
                if !queue.isEmpty {
                    let next = queue.removeFirst()
                    lock.unlock()
                    cont.resume(returning: next)
                } else if closed {
                    lock.unlock()
                    cont.resume(returning: .closed(WebSocketCloseReason(code: 1000, reason: nil)))
                } else {
                    waiter = cont
                    lock.unlock()
                }
            }
        }

        func ping() async throws {}

        func close() async {
            lock.lock()
            closed = true
            let cont = waiter
            waiter = nil
            lock.unlock()
            cont?.resume(returning: .closed(WebSocketCloseReason(code: 1000, reason: nil)))
        }
    }

    private let handler: (ACP.AnyRequest) -> ACP.AnyResponse
    private let lock = NSLock()
    private var _recorded: [ACP.AnyRequest] = []

    var recordedRequests: [ACP.AnyRequest] {
        lock.lock()
        defer { lock.unlock() }
        return _recorded
    }

    init(handler: @escaping (ACP.AnyRequest) -> ACP.AnyResponse) {
        self.handler = handler
    }

    func makeConnection(url: URL) -> WebSocketConnection {
        Connection(handler: handler) { [weak self] req in
            guard let self else { return }
            self.lock.lock()
            self._recorded.append(req)
            self.lock.unlock()
        }
    }
}
