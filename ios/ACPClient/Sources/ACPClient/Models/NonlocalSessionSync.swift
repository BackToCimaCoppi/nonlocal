import ACP
import Foundation

public enum NonlocalTurnStatus: String, Sendable, Equatable {
    case active
    case completed
    case error
}

public struct NonlocalRPCError: Sendable, Equatable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct NonlocalBufferedEvent: Sendable, Equatable {
    public let seq: Int
    public let method: String
    public let params: ACP.Value

    public init(seq: Int, method: String, params: ACP.Value) {
        self.seq = seq
        self.method = method
        self.params = params
    }
}

public struct NonlocalPendingPermission: Sendable, Equatable {
    public let requestId: ACP.ID
    public let params: ACP.Value

    public init(requestId: ACP.ID, params: ACP.Value) {
        self.requestId = requestId
        self.params = params
    }
}

public struct NonlocalTurnSnapshot: Sendable, Equatable {
    public let turnId: String
    public let clientTurnId: String?
    public let status: NonlocalTurnStatus
    public let lastSeq: Int
    public let truncated: Bool
    public let events: [NonlocalBufferedEvent]
    public let pendingPermissions: [NonlocalPendingPermission]
    public let stopReason: String?
    public let error: NonlocalRPCError?
    public let hasUnresolvedToolCalls: Bool?

    public init(
        turnId: String,
        clientTurnId: String? = nil,
        status: NonlocalTurnStatus,
        lastSeq: Int,
        truncated: Bool = false,
        events: [NonlocalBufferedEvent] = [],
        pendingPermissions: [NonlocalPendingPermission] = [],
        stopReason: String? = nil,
        error: NonlocalRPCError? = nil,
        hasUnresolvedToolCalls: Bool? = nil
    ) {
        self.turnId = turnId
        self.clientTurnId = clientTurnId
        self.status = status
        self.lastSeq = lastSeq
        self.truncated = truncated
        self.events = events
        self.pendingPermissions = pendingPermissions
        self.stopReason = stopReason
        self.error = error
        self.hasUnresolvedToolCalls = hasUnresolvedToolCalls
    }
}

public struct NonlocalSessionSnapshot: Sendable, Equatable {
    public let sessionId: String
    public let lastActivityAt: String?
    public let modes: ACPModesInfo?
    public let configOptions: [ACPSessionConfigOption]
    public let latestTurn: NonlocalTurnSnapshot?
    public let availableCommands: [SessionCommand]

    public var lastActivityDate: Date? {
        guard let lastActivityAt else { return nil }
        return NonlocalISO8601Parser.parse(lastActivityAt)
    }

    public init(
        sessionId: String,
        lastActivityAt: String? = nil,
        modes: ACPModesInfo? = nil,
        configOptions: [ACPSessionConfigOption] = [],
        latestTurn: NonlocalTurnSnapshot? = nil,
        availableCommands: [SessionCommand] = []
    ) {
        self.sessionId = sessionId
        self.lastActivityAt = lastActivityAt
        self.modes = modes
        self.configOptions = configOptions
        self.latestTurn = latestTurn
        self.availableCommands = availableCommands
    }
}

public struct NonlocalSyncResult: Sendable, Equatable {
    public let instanceId: String
    public let materializedSessionIds: [String]
    public let staleSessionIds: [String]
    public let sessions: [NonlocalSessionSnapshot]

    public init(
        instanceId: String,
        materializedSessionIds: [String],
        staleSessionIds: [String] = [],
        sessions: [NonlocalSessionSnapshot]
    ) {
        self.instanceId = instanceId
        self.materializedSessionIds = materializedSessionIds
        self.staleSessionIds = staleSessionIds
        self.sessions = sessions
    }
}

public struct NonlocalRenameResult: Sendable, Equatable {
    public let sessionId: String
    public let title: String?

    public init(sessionId: String, title: String?) {
        self.sessionId = sessionId
        self.title = title
    }
}

public struct NonlocalSessionStaleNotification: Sendable, Equatable {
    public let instanceId: String
    public let sessionId: String
    public let updatedAt: String?
    public let reason: String?

    public init(
        instanceId: String,
        sessionId: String,
        updatedAt: String? = nil,
        reason: String? = nil
    ) {
        self.instanceId = instanceId
        self.sessionId = sessionId
        self.updatedAt = updatedAt
        self.reason = reason
    }
}

public struct NonlocalTurnCompletedNotification: Sendable, Equatable {
    public let instanceId: String
    public let sessionId: String
    public let turnId: String
    public let clientTurnId: String?
    public let status: NonlocalTurnStatus
    public let stopReason: String?
    public let error: NonlocalRPCError?

    public init(
        instanceId: String,
        sessionId: String,
        turnId: String,
        clientTurnId: String? = nil,
        status: NonlocalTurnStatus,
        stopReason: String? = nil,
        error: NonlocalRPCError? = nil
    ) {
        self.instanceId = instanceId
        self.sessionId = sessionId
        self.turnId = turnId
        self.clientTurnId = clientTurnId
        self.status = status
        self.stopReason = stopReason
        self.error = error
    }
}

public enum NonlocalSessionSyncParser {
    public static func parseSyncResult(from result: ACP.Value?) -> NonlocalSyncResult? {
        guard let object = result?.objectValue,
              let rawInstanceId = object["instanceId"]?.stringValue else {
            return nil
        }
        let instanceId = rawInstanceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instanceId.isEmpty else {
            return nil
        }

        let materializedIds: [String]
        if case let .array(items)? = object["materializedSessionIds"] {
            materializedIds = items.compactMap(\.stringValue).filter { !$0.isEmpty }
        } else {
            materializedIds = []
        }

        let staleIds: [String]
        if case let .array(items)? = object["staleSessionIds"] {
            staleIds = items.compactMap(\.stringValue).filter { !$0.isEmpty }
        } else {
            staleIds = []
        }

        let sessions: [NonlocalSessionSnapshot]
        if case let .array(sessionItems)? = object["sessions"] {
            sessions = sessionItems.compactMap(parseSessionSnapshot(from:))
        } else {
            sessions = []
        }

        return NonlocalSyncResult(
            instanceId: instanceId,
            materializedSessionIds: materializedIds,
            staleSessionIds: staleIds,
            sessions: sessions
        )
    }

    public static func parseSessionStale(from params: ACP.Value?) -> NonlocalSessionStaleNotification? {
        guard let object = params?.objectValue,
              let instanceId = nonEmptyString(object["instanceId"]),
              let sessionId = nonEmptyString(object["sessionId"]) else {
            return nil
        }
        return NonlocalSessionStaleNotification(
            instanceId: instanceId,
            sessionId: sessionId,
            updatedAt: nonEmptyString(object["updatedAt"]),
            reason: nonEmptyString(object["reason"])
        )
    }

    public static func parseTurnCompleted(from params: ACP.Value?) -> NonlocalTurnCompletedNotification? {
        guard let object = params?.objectValue,
              let instanceId = object["instanceId"]?.stringValue,
              let sessionId = object["sessionId"]?.stringValue,
              let turnId = object["turnId"]?.stringValue,
              let statusRaw = object["status"]?.stringValue,
              let status = NonlocalTurnStatus(rawValue: statusRaw) else {
            return nil
        }

        let clientTurnId = nonEmptyString(object["clientTurnId"])
        let stopReason = nonEmptyString(object["stopReason"])
        let error = parseError(from: object["error"])

        return NonlocalTurnCompletedNotification(
            instanceId: instanceId,
            sessionId: sessionId,
            turnId: turnId,
            clientTurnId: clientTurnId,
            status: status,
            stopReason: stopReason,
            error: error
        )
    }

    public static func parseSeq(from params: ACP.Value?) -> Int? {
        guard let meta = params?.objectValue?["_meta"]?.objectValue else { return nil }
        return parseInt(meta[NonlocalMethods.seqMetaKey])
    }

    public static func parseTurnId(from params: ACP.Value?) -> String? {
        guard let meta = params?.objectValue?["_meta"]?.objectValue else { return nil }
        return nonEmptyString(meta[NonlocalMethods.turnIdMetaKey])
    }

    private static func parseSessionSnapshot(from value: ACP.Value) -> NonlocalSessionSnapshot? {
        guard let object = value.objectValue,
              let sessionId = nonEmptyString(object["sessionId"]) else {
            return nil
        }

        let lastActivityAt = nonEmptyString(object["lastActivityAt"])
        let modes = ACPSessionResponseParser.parseModes(from: object)
        let configOptions = ACPSessionConfigOptionParser.parse(from: object["configOptions"])
        let availableCommands = SessionCommand.parse(from: object)
        let latestTurn = parseTurnSnapshot(from: object["latestTurn"])

        return NonlocalSessionSnapshot(
            sessionId: sessionId,
            lastActivityAt: lastActivityAt,
            modes: modes,
            configOptions: configOptions,
            latestTurn: latestTurn,
            availableCommands: availableCommands
        )
    }

    private static func parseTurnSnapshot(from value: ACP.Value?) -> NonlocalTurnSnapshot? {
        guard let object = value?.objectValue,
              let turnId = nonEmptyString(object["turnId"]),
              let statusRaw = object["status"]?.stringValue,
              let status = NonlocalTurnStatus(rawValue: statusRaw) else {
            return nil
        }

        let clientTurnId = nonEmptyString(object["clientTurnId"])
        let lastSeq = parseInt(object["lastSeq"]) ?? 0
        let truncated = object["truncated"]?.boolValue ?? false

        let events: [NonlocalBufferedEvent]
        if case let .array(rawEvents)? = object["events"] {
            events = rawEvents.compactMap(parseBufferedEvent(from:))
        } else {
            events = []
        }

        let pendingPermissions: [NonlocalPendingPermission]
        if case let .array(rawPerms)? = object["pendingPermissions"] {
            pendingPermissions = rawPerms.compactMap(parsePendingPermission(from:))
        } else {
            pendingPermissions = []
        }

        let stopReason = nonEmptyString(object["stopReason"])
        let error = parseError(from: object["error"])
        let hasUnresolvedToolCalls = object["hasUnresolvedToolCalls"]?.boolValue

        return NonlocalTurnSnapshot(
            turnId: turnId,
            clientTurnId: clientTurnId,
            status: status,
            lastSeq: lastSeq,
            truncated: truncated,
            events: events,
            pendingPermissions: pendingPermissions,
            stopReason: stopReason,
            error: error,
            hasUnresolvedToolCalls: hasUnresolvedToolCalls
        )
    }

    private static func parseBufferedEvent(from value: ACP.Value) -> NonlocalBufferedEvent? {
        guard let object = value.objectValue,
              let seq = parseInt(object["seq"]),
              let method = nonEmptyString(object["method"]) else {
            return nil
        }
        let params = object["params"] ?? .null
        return NonlocalBufferedEvent(seq: seq, method: method, params: params)
    }

    private static func parsePendingPermission(from value: ACP.Value) -> NonlocalPendingPermission? {
        guard let object = value.objectValue,
              let requestId = parseID(object["requestId"]) else {
            return nil
        }
        let params = object["params"] ?? .null
        return NonlocalPendingPermission(requestId: requestId, params: params)
    }

    private static func parseError(from value: ACP.Value?) -> NonlocalRPCError? {
        guard let object = value?.objectValue else { return nil }
        let code = parseInt(object["code"]) ?? -32000
        let message = object["message"]?.stringValue ?? "Unknown error"
        return NonlocalRPCError(code: code, message: message)
    }

    private static func parseID(_ value: ACP.Value?) -> ACP.ID? {
        guard let value else { return nil }
        switch value {
        case .string(let text):
            return .string(text)
        case .int(let intVal):
            return .number(intVal)
        case .double(let doubleVal):
            if let exact = Int(exactly: doubleVal) {
                return .number(exact)
            }
            return nil
        default:
            return nil
        }
    }

    private static func parseInt(_ value: ACP.Value?) -> Int? {
        guard let value else { return nil }
        switch value {
        case .int(let intVal):
            return intVal
        case .double(let doubleVal):
            return Int(exactly: doubleVal)
        default:
            return nil
        }
    }

    private static func nonEmptyString(_ value: ACP.Value?) -> String? {
        guard let text = value?.stringValue, !text.isEmpty else { return nil }
        return text
    }
}

private enum NonlocalISO8601Parser {
    static func parse(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
