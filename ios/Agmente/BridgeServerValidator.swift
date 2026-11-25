import Foundation
import ACP
import ACPClient

enum AddServerValidationError: LocalizedError, Equatable {
    case incompatibleBridge(String)
    case networkError(String)
    case localNetworkPermissionNeeded(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .incompatibleBridge(let message),
             .networkError(let message),
             .localNetworkPermissionNeeded(let message),
             .other(let message):
            return message
        }
    }

    var isLocalNetworkPermissionError: Bool {
        if case .localNetworkPermissionNeeded = self {
            return true
        }
        return false
    }

    var isIncompatibleBridgeError: Bool {
        if case .incompatibleBridge = self {
            return true
        }
        return false
    }
}

/// Single source of truth for endpoint normalization, local-network detection, and
/// Nonlocal Bridge admission validation (`initialize` + `nonlocal/sync` non-empty `instanceId`) (SD-1.1 / SD-2.1 / SD-2.4).
@MainActor
final class BridgeServerValidator {
    static let defaultScheme = "ws"
    static let clientIdDefaultsKey = "ACPClientManager.clientId"
    static let protocolIncompatibilityCodes: Set<Int> = [-32601, -32600, -32602]

    private let defaults: UserDefaults
    private let serviceFactory: (ACPClientConfiguration) -> ACPService

    init(
        defaults: UserDefaults = .standard,
        serviceFactory: ((ACPClientConfiguration) -> ACPService)? = nil
    ) {
        self.defaults = defaults
        self.serviceFactory = serviceFactory ?? { config in
            let client = ACPClient(configuration: config, logger: PrintLogger())
            return ACPService(client: client)
        }
    }

    static func normalizeEndpoint(scheme: String, host: String) -> (scheme: String, host: String) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseScheme = scheme.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? defaultScheme
            : scheme.trimmingCharacters(in: .whitespacesAndNewlines)

        func normalize(from components: URLComponents) -> (scheme: String, host: String)? {
            guard let parsedHost = components.host else { return nil }

            let portString = components.port.map { ":\($0)" } ?? ""
            let path = components.percentEncodedPath
            let query = components.percentEncodedQuery.map { "?\($0)" } ?? ""
            let fragment = components.percentEncodedFragment.map { "#\($0)" } ?? ""

            let normalizedScheme = components.scheme ?? baseScheme
            let normalizedHost = parsedHost + portString + path + query + fragment

            return (normalizedScheme.isEmpty ? defaultScheme : normalizedScheme, normalizedHost)
        }

        if let components = URLComponents(string: trimmedHost),
           let normalized = normalize(from: components) {
            return normalized
        }

        if let components = URLComponents(string: "\(baseScheme)://\(trimmedHost)"),
           let normalized = normalize(from: components) {
            return (normalized.scheme, normalized.host)
        }

        return (baseScheme, trimmedHost)
    }

    static func isLocalNetworkHost(_ host: String) -> Bool {
        let lowercasedHost = host.lowercased()

        if lowercasedHost.hasPrefix("localhost") || lowercasedHost.contains("//localhost") {
            return true
        }
        if lowercasedHost.contains("127.0.0.1") || lowercasedHost.contains("::1") {
            return true
        }
        if lowercasedHost.contains(".local") {
            return true
        }

        let components = host.split(separator: ":").first.map(String.init) ?? host
        let ipComponents = components.split(separator: ".").map(String.init)

        if ipComponents.count == 4,
           let first = Int(ipComponents[0]),
           let second = Int(ipComponents[1]) {
            if first == 192 && second == 168 { return true }
            if first == 10 { return true }
            if first == 172 && (16...31).contains(second) { return true }
        }

        return false
    }

    func persistentClientId() -> String {
        if let existing = defaults.string(forKey: Self.clientIdDefaultsKey), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString
        defaults.set(generated, forKey: Self.clientIdDefaultsKey)
        return generated
    }

    static func incompatibleBridgeMessage(for label: String) -> String {
        String(
            format: AppLocalization.localized("%@ is not a compatible Nonlocal Bridge server. Please check the server address and bridge version."),
            label
        )
    }

    static func isAlreadyInitializedRPCError(_ rpcError: ACPError) -> Bool {
        rpcError.message.lowercased().contains("already initialized")
    }

    static func isProtocolIncompatibilityRPCError(_ rpcError: ACPError, allowAlreadyInitialized: Bool) -> Bool {
        if allowAlreadyInitialized && isAlreadyInitializedRPCError(rpcError) {
            return false
        }
        return protocolIncompatibilityCodes.contains(rpcError.code)
    }

    func validate(
        name: String,
        scheme: String,
        host: String,
        token: String,
        workingDirectory: String,
        clientName: String,
        clientVersion: String,
        supportsFSRead: Bool,
        supportsFSWrite: Bool,
        supportsTerminal: Bool
    ) async -> Result<ValidatedServerConfiguration, Error> {
        let normalized = Self.normalizeEndpoint(scheme: scheme, host: host)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmedName.isEmpty ? "\(normalized.scheme)://\(normalized.host)" : trimmedName
        let urlString = "\(normalized.scheme)://\(normalized.host)"
        guard let url = URL(string: urlString) else {
            return .failure(AddServerValidationError.other("Invalid endpoint: \(urlString)"))
        }

        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = ACPClientConfiguration(
            endpoint: url,
            authTokenProvider: trimmedToken.isEmpty ? nil : { trimmedToken },
            additionalHeaders: ["X-Client-Id": persistentClientId()],
            pingInterval: 15
        )
        let service = serviceFactory(config)

        let clientCapabilities: [String: ACP.Value] = [
            "fs": .object([
                "readTextFile": .bool(supportsFSRead),
                "writeTextFile": .bool(supportsFSWrite)
            ]),
            "terminal": .bool(supportsTerminal),
        ]
        let initPayload = ACPInitializationPayload(
            protocolVersion: 1,
            clientName: clientName,
            clientVersion: clientVersion,
            clientCapabilities: clientCapabilities
        )

        var agentInfo: AgentProfile?
        var connected = false
        do {
            try await service.connect()
            connected = true

            // 1. Validate ACP initialize response (reject non-ACP / empty {} / -32601/-32600/-32602; allow "already initialized")
            do {
                let initResponse = try await service.initialize(initPayload)
                guard let parsed = ACPInitializeParser.parse(result: initResponse.resultValue) else {
                    await service.disconnect()
                    return .failure(AddServerValidationError.incompatibleBridge(Self.incompatibleBridgeMessage(for: label)))
                }
                agentInfo = parsed.agentInfo
            } catch let serviceError as ACPServiceError {
                if case .rpc(_, let rpcError) = serviceError {
                    if Self.isAlreadyInitializedRPCError(rpcError) {
                        // Already initialized on bridge; continue to nonlocal/sync identity verification.
                    } else if Self.isProtocolIncompatibilityRPCError(rpcError, allowAlreadyInitialized: true) {
                        await service.disconnect()
                        return .failure(AddServerValidationError.incompatibleBridge(Self.incompatibleBridgeMessage(for: label)))
                    } else {
                        throw serviceError
                    }
                } else {
                    throw serviceError
                }
            }

            // 2. Validate Nonlocal Bridge identity via nonlocal/sync (must return non-empty instanceId)
            do {
                let syncResult = try await service.syncNonlocalSessions()
                guard syncResult != nil else {
                    await service.disconnect()
                    return .failure(AddServerValidationError.incompatibleBridge(Self.incompatibleBridgeMessage(for: label)))
                }
            } catch let serviceError as ACPServiceError {
                if case .rpc(_, let rpcError) = serviceError,
                   Self.isProtocolIncompatibilityRPCError(rpcError, allowAlreadyInitialized: false) {
                    await service.disconnect()
                    return .failure(AddServerValidationError.incompatibleBridge(Self.incompatibleBridgeMessage(for: label)))
                }
                throw serviceError
            }

            await service.disconnect()
        } catch let validationError as AddServerValidationError {
            if connected { await service.disconnect() }
            return .failure(validationError)
        } catch {
            if connected { await service.disconnect() }
            let nsError = error as NSError
            let isLocalNetworkPermissionError = nsError.domain == NSURLErrorDomain
                && (-1200 ... -1001).contains(nsError.code)
                && Self.isLocalNetworkHost(normalized.host)

            if isLocalNetworkPermissionError {
                return .failure(AddServerValidationError.localNetworkPermissionNeeded(
                    "Local network access is required. Please grant access when prompted by iOS and try again."
                ))
            }

            return .failure(AddServerValidationError.networkError("Unable to reach \(label): \(error.localizedDescription)"))
        }

        return .success(ValidatedServerConfiguration(
            name: name,
            scheme: normalized.scheme,
            host: normalized.host,
            token: trimmedToken,
            workingDirectory: workingDirectory,
            agentInfo: agentInfo
        ))
    }
}
