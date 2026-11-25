import ACP
import Testing
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ACPClient
import ACPClientMocks

final class CapturingServiceDelegate: ACPServiceDelegate {
    var notifications: [ACP.AnyMessage] = []
    var states: [ACPConnectionState] = []
    var errors: [Error] = []
    var messages: [ACPWireMessage] = []
    var sentRequests: [ACP.AnyRequest] = []

    func acpService(_ service: ACPService, didReceiveNotification notification: ACP.AnyMessage) {
        notifications.append(notification)
    }

    func acpService(_ service: ACPService, didReceiveMessage message: ACPWireMessage) {
        messages.append(message)
    }

    func acpService(_ service: ACPService, willSend request: ACP.AnyRequest) {
        sentRequests.append(request)
    }

    func acpService(_ service: ACPService, didChangeState state: ACPConnectionState) {
        states.append(state)
    }

    func acpService(_ service: ACPService, didEncounterError error: any Error) {
        errors.append(error)
    }
}

// SC-AC-018: ACPService in-flight continuation wakeups on .disconnected/.failed & Nonlocal* error mappings.
struct ACPServiceTests {
    @Test func initializesAndResolvesResponse() async throws {
        let provider = MockWebSocketProvider()
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "wss://example.com/socket")!),
            socketProvider: provider
        )
        let delegate = CapturingServiceDelegate()
        let service = ACPService(client: client)
        service.delegate = delegate

        try await service.connect()

        Task {
            let response = ACPWireMessage.response(.init(id: .int(1), result: .object(["status": .string("ok")]) ))
            let encoded = try JSONEncoder().encode(response)
            let text = String(decoding: encoded, as: UTF8.self)
            provider.connection.enqueue(.text(text))
        }

        let payload = ACPInitializationPayload(clientName: "Agmente iOS", clientVersion: "0.1.0")
        let response = try await service.initialize(payload)

        #expect(response.resultValue == .object(["status": .string("ok")]))
        let states = await MainActor.run { delegate.states }
        let notifications = await MainActor.run { delegate.notifications }
        #expect(states.contains(.connected))
        #expect(notifications.isEmpty)
    }

    @Test func surfacesRPCErrorForRequests() async throws {
        let provider = MockWebSocketProvider()
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "wss://example.com/socket")!),
            socketProvider: provider
        )
        let delegate = CapturingServiceDelegate()
        let service = ACPService(client: client)
        service.delegate = delegate

        try await service.connect()

        Task {
            let error = ACPWireMessage.response(.init(id: .int(1), error: .serverError(code: -32001, message: "failed")))
            let encoded = try JSONEncoder().encode(error)
            let text = String(decoding: encoded, as: UTF8.self)
            provider.connection.enqueue(.text(text))
        }

        do {
            let payload = ACPSessionCreatePayload(workingDirectory: "/tmp", agent: "demo")
            _ = try await service.createSession(payload)
            Issue.record("Expected error to be thrown")
        } catch let error as ACPServiceError {
            #expect(error == .rpc(id: .int(1), error: .serverError(code: -32001, message: "failed")))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        let errors = await MainActor.run { delegate.errors }
        #expect(errors.isEmpty)
    }

    @Test func loadSessionSendsRequestAndResolvesResponse() async throws {
        let provider = MockWebSocketProvider()
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "wss://example.com/socket")!),
            socketProvider: provider
        )
        let delegate = CapturingServiceDelegate()
        let service = ACPService(client: client)
        service.delegate = delegate

        try await service.connect()

        Task {
            let response = ACPWireMessage.response(.init(id: .int(1), result: .object(["status": .string("ok")]) ))
            let encoded = try JSONEncoder().encode(response)
            let text = String(decoding: encoded, as: UTF8.self)
            provider.connection.enqueue(.text(text))
        }

        let payload = ACPSessionLoadPayload(sessionId: "session-1", workingDirectory: "/tmp")
        let response = try await service.loadSession(payload)

        #expect(response.resultValue == .object(["status": .string("ok")]))
        let requests = await MainActor.run { delegate.sentRequests }
        #expect(requests.last?.method == "session/load")
    }

    @Test func setSessionConfigOptionSendsRequestAndResolvesResponse() async throws {
        let provider = MockWebSocketProvider()
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "wss://example.com/socket")!),
            socketProvider: provider
        )
        let delegate = CapturingServiceDelegate()
        let service = ACPService(client: client)
        service.delegate = delegate

        try await service.connect()

        Task {
            let response = ACPWireMessage.response(.init(id: .int(1), result: .object(["status": .string("ok")])))
            let encoded = try JSONEncoder().encode(response)
            let text = String(decoding: encoded, as: UTF8.self)
            provider.connection.enqueue(.text(text))
        }

        let payload = ACPSessionSetConfigOptionPayload(
            sessionId: "session-1",
            configId: "mode",
            value: .string("code")
        )
        let response = try await service.setSessionConfigOption(payload)

        #expect(response.resultValue == .object(["status": .string("ok")]))
        let requests = await MainActor.run { delegate.sentRequests }
        #expect(requests.last?.method == "session/set_config_option")
    }

    @Test func renameSessionSendsRequestAndHandlesClearAndRPCError() async throws {
        let provider = MockWebSocketProvider()
        let client = ACPClient(
            configuration: .init(endpoint: URL(string: "wss://example.com/socket")!),
            socketProvider: provider
        )
        let delegate = CapturingServiceDelegate()
        let service = ACPService(client: client)
        service.delegate = delegate

        try await service.connect()

        // 1. Set non-empty custom title
        _ = Task {
            let response = ACPWireMessage.response(.init(
                id: .int(1),
                result: .object([
                    "sessionId": .string("s-1"),
                    "title": .string("中文会话"),
                ])
            ))
            let encoded = try JSONEncoder().encode(response)
            provider.connection.enqueue(.text(String(decoding: encoded, as: UTF8.self)))
        }
        let setResult = try await service.renameSession(sessionId: "s-1", title: "中文会话")
        #expect(setResult == NonlocalRenameResult(sessionId: "s-1", title: "中文会话"))

        // 2. Empty string clears custom title (sends .null) and decodes restored nil/fallback title
        _ = Task {
            let response = ACPWireMessage.response(.init(
                id: .int(2),
                result: .object([
                    "sessionId": .string("s-1"),
                    "title": .null,
                ])
            ))
            let encoded = try JSONEncoder().encode(response)
            provider.connection.enqueue(.text(String(decoding: encoded, as: UTF8.self)))
        }
        let clearResult = try await service.renameSession(sessionId: "s-1", title: "")
        #expect(clearResult == NonlocalRenameResult(sessionId: "s-1", title: nil))

        // 3. Method not found (-32601) throws ACPServiceError.rpc
        _ = Task {
            let response = ACPWireMessage.response(.init(
                id: .int(3),
                error: .serverError(code: -32601, message: "Method not found")
            ))
            let encoded = try JSONEncoder().encode(response)
            provider.connection.enqueue(.text(String(decoding: encoded, as: UTF8.self)))
        }
        do {
            _ = try await service.renameSession(sessionId: "s-1", title: "ShouldFail")
            Issue.record("Expected renameSession to throw ACPServiceError.rpc(-32601)")
        } catch let err as ACPServiceError {
            #expect(err.rpcCode == -32601)
        }

        let requests = await MainActor.run { delegate.sentRequests }
        #expect(requests.count == 3)
        #expect(requests[0].method == NonlocalMethods.renameSession)
        #expect(requests[0].params == .object(["sessionId": .string("s-1"), "title": .string("中文会话")]))
        #expect(requests[1].params == .object(["sessionId": .string("s-1"), "title": .null]))
    }
}
