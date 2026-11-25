import ACP
import Foundation

@MainActor
public protocol ACPServiceDelegate: AnyObject {
    func acpService(_ service: ACPService, didReceiveNotification notification: ACP.AnyMessage)
    func acpService(_ service: ACPService, didReceiveMessage message: ACPWireMessage)
    func acpService(_ service: ACPService, willSend request: ACP.AnyRequest)
    func acpService(_ service: ACPService, didChangeState state: ACPConnectionState)
    func acpService(_ service: ACPService, didEncounterError error: Error)
}

public final class ACPService {
    private let client: ACPClient
    private let idSequence = RequestIDSequence()
    private let pendingRequests = PendingRequestStore()

    public weak var delegate: ACPServiceDelegate?

    /// The close reason reported by the underlying WebSocket's most recent `.closed` frame, if any.
    public var lastCloseReason: WebSocketCloseReason? {
        client.lastCloseReason
    }

    public init(client: ACPClient) {
        self.client = client
        self.client.delegate = self
    }

    public func connect() async throws {
        try await client.connect()
    }

    public func disconnect() async {
        await pendingRequests.failAll(with: ACPServiceError.disconnected)
        await client.disconnect()
    }

    public func sendMessage(_ message: ACPWireMessage) async throws {
        try await client.send(message)
    }

    public func initialize(_ payload: ACPInitializationPayload) async throws -> ACP.AnyResponse {
        try await sendRequest(method: ACPMethods.initialize, params: payload.params())
    }

    public func createSession(_ payload: ACPSessionCreatePayload) async throws -> ACP.AnyResponse {
        try await sendRequest(method: ACPMethods.sessionNew, params: payload.params())
    }

    public func loadSession(_ payload: ACPSessionLoadPayload) async throws -> ACP.AnyResponse {
        try await sendRequest(method: ACPMethods.sessionLoad, params: payload.params())
    }

    /// Sends a WebSocket ping frame to validate the underlying connection.
    public func ping() async throws {
        try await client.ping()
    }

    public func sendPrompt(_ payload: ACPSessionPromptPayload) async throws -> ACP.AnyResponse {
        try await sendRequest(method: ACPMethods.sessionPrompt, params: payload.params())
    }

    public func cancelSession(_ payload: ACPSessionCancelPayload) async throws -> ACP.AnyResponse {
        try await sendRequest(method: ACPMethods.sessionCancel, params: payload.params())
    }

    public func listSessions(_ payload: ACPSessionListPayload = .init()) async throws -> ACP.AnyResponse {
        try await sendRequest(method: ACPMethods.sessionList, params: payload.params())
    }

    public func setSessionMode(_ payload: ACPSessionSetModePayload) async throws -> ACP.AnyResponse {
        try await sendRequest(method: ACPMethods.sessionSetMode, params: payload.params())
    }

    public func setSessionConfigOption(_ payload: ACPSessionSetConfigOptionPayload) async throws -> ACP.AnyResponse {
        try await sendRequest(method: ACPMethods.sessionSetConfigOption, params: payload.params())
    }

    /// Sends an arbitrary JSON-RPC request and awaits the response.
    /// Useful for optional ACP methods that don't yet have typed wrappers.
    public func call(method: String, params: ACP.Value? = nil) async throws -> ACP.AnyResponse {
        try await sendRequest(method: method, params: params)
    }

    /// Queries the Nonlocal bridge's `nonlocal/sync` snapshot without triggering
    /// destructive `session/load` replays. Standard ACP agents throw RPC `-32601`.
    public func syncNonlocalSessions() async throws -> NonlocalSyncResult? {
        let response = try await call(method: NonlocalMethods.sessionSync, params: .object([:]))
        return NonlocalSessionSyncParser.parseSyncResult(from: response.resultValue)
    }

    /// Updates or clears a session's user-defined title via `nonlocal/rename_session`.
    /// Standard ACP agents throw RPC `-32601` (Method not found).
    @discardableResult
    public func renameSession(sessionId: String, title: String?) async throws -> NonlocalRenameResult {
        let titleValue: ACP.Value
        if let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            titleValue = .string(trimmed)
        } else {
            titleValue = .null
        }
        let response = try await call(
            method: NonlocalMethods.renameSession,
            params: .object([
                "sessionId": .string(sessionId),
                "title": titleValue,
            ])
        )
        let obj = response.resultValue?.objectValue
        let resolvedSessionId = obj?["sessionId"]?.stringValue ?? sessionId
        let resolvedTitle = obj?["title"]?.stringValue
        return NonlocalRenameResult(sessionId: resolvedSessionId, title: resolvedTitle)
    }

    /// Queries the Nonlocal bridge's cached/single-flight Antigravity usage snapshot via `nonlocal/usage`.
    /// Standard ACP agents throw RPC `-32601` (Method not found).
    public func fetchNonlocalUsage() async throws -> NonlocalUsageResult? {
        let response = try await call(method: NonlocalMethods.usage, params: .object([:]))
        return NonlocalUsageParser.parse(from: response.resultValue)
    }

    /// Queries read-only session metadata and recursively discovered subagents via `nonlocal/session_info`.
    /// Standard ACP agents throw RPC `-32601` (Method not found).
    public func fetchSessionInfo(sessionId: String) async throws -> NonlocalSessionInfoResult? {
        let response = try await call(
            method: NonlocalMethods.sessionInfo,
            params: .object(["sessionId": .string(sessionId)])
        )
        return NonlocalSessionInfoParser.parseSessionInfo(from: response.resultValue)
    }

    /// Lists directories (and optionally files) on the bridge host via `nonlocal/fs_list`.
    /// Reserved error codes (`-32011`..`-32013`, `-32602`, `-32601`) are thrown as `ACPServiceError.rpc`.
    public func listDirectory(_ params: NonlocalFsListParams = .init()) async throws -> NonlocalFsListResult? {
        let response = try await call(method: NonlocalMethods.fsList, params: params.acpValue())
        return NonlocalFileSystemParser.parseFsList(from: response.resultValue)
    }

    /// Reads a bounded slice of a remote text or image file on the bridge host via `nonlocal/fs_read_file`.
    /// Reserved error codes (`-32011`, `-32013`..`-32016`, `-32602`, `-32601`) are thrown as `ACPServiceError.rpc`.
    public func readFile(path: String) async throws -> NonlocalFsReadFileResult? {
        let response = try await call(
            method: NonlocalMethods.fsReadFile,
            params: .object(["path": .string(path)])
        )
        return NonlocalFileSystemParser.parseFsReadFile(from: response.resultValue)
    }

    /// Deletes a persisted session (and any child subagents) on the bridge host via `nonlocal/delete_session`.
    /// Reserved error codes (`-32021`..`-32024`) and `-32601` are thrown as `ACPServiceError.rpc`.
    public func deleteSession(sessionId: String) async throws -> NonlocalDeleteSessionResult? {
        let response = try await call(
            method: NonlocalMethods.deleteSession,
            params: .object(["sessionId": .string(sessionId)])
        )
        return NonlocalDeleteSessionResult.parse(from: response.resultValue)
    }

    private func sendRequest(method: String, params: ACP.Value?) async throws -> ACP.AnyResponse {
        switch client.state {
        case .disconnected, .failed:
            throw ACPServiceError.disconnected
        case .connecting, .connected:
            return try await sendPreparedRequest(method: method, params: params)
        }
    }

    private func sendPreparedRequest(method: String, params: ACP.Value?) async throws -> ACP.AnyResponse {
        let id = await idSequence.next()
        let request = ACP.AnyRequest(id: id, method: method, params: params ?? .null)
        await MainActor.run { delegate?.acpService(self, willSend: request) }
        let message = ACPWireMessage.request(request)
        return try await withCheckedThrowingContinuation { continuation in
            Task {
                await pendingRequests.storeContinuation(continuation, for: id)
                do {
                    try await client.send(message)
                } catch {
                    await pendingRequests.resume(id: id, with: .failure(error))
                }
            }
        }
    }
}

extension ACPService: @unchecked Sendable {}

extension ACPService: ACPClientDelegate {
    public func acpClient(_ client: ACPClient, didChangeState state: ACPConnectionState) {
        Task { @MainActor in delegate?.acpService(self, didChangeState: state) }
        switch state {
        case .disconnected, .failed:
            Task { await pendingRequests.failAll(with: ACPServiceError.disconnected) }
        case .connecting, .connected:
            break
        }
    }

    public func acpClient(_ client: ACPClient, didReceiveMessage message: ACPWireMessage) {
        Task { @MainActor in delegate?.acpService(self, didReceiveMessage: message) }
        switch message {
        case .notification(let notification):
            Task { @MainActor in delegate?.acpService(self, didReceiveNotification: notification) }
        case .response(let response):
            if let error = response.errorValue {
                Task { await pendingRequests.resume(id: response.id, with: .failure(ACPServiceError.rpc(id: response.id, error: error))) }
            } else {
                Task { await pendingRequests.resume(id: response.id, with: .success(response)) }
            }
        case .request:
            // Requests are valid JSON-RPC messages (used by some servers for permission prompts,
            // filesystem/terminal RPCs, etc.). The delegate already receives the raw message in
            // `didReceiveMessage`, so we do not treat this as an error here.
            break
        }
    }

    public func acpClient(_ client: ACPClient, didEncounterError error: Error) {
        Task { @MainActor in delegate?.acpService(self, didEncounterError: error) }
    }
}

public enum ACPServiceError: Error, Equatable {
    case disconnected
    case rpc(id: ACP.ID, error: ACPError)
    case unsupportedMessage
}

public extension ACPServiceError {
    var rpcMessage: String? {
        switch self {
        case .rpc(_, let error):
            return error.message
        default:
            return nil
        }
    }

    var rpcCode: Int? {
        switch self {
        case .rpc(_, let error):
            return error.code
        default:
            return nil
        }
    }
}

private actor RequestIDSequence {
    private var counter: Int = 0

    func next() -> ACP.ID {
        counter += 1
        return .int(counter)
    }
}

private actor PendingRequestStore {
    private var continuations: [ACP.ID: CheckedContinuation<ACP.AnyResponse, Error>] = [:]

    func storeContinuation(_ continuation: CheckedContinuation<ACP.AnyResponse, Error>, for id: ACP.ID) {
        continuations[id] = continuation
    }

    func resume(id: ACP.ID, with result: Result<ACP.AnyResponse, Error>) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    func failAll(with error: Error) {
        let pending = continuations
        continuations.removeAll()
        pending.values.forEach { $0.resume(throwing: error) }
    }
}
