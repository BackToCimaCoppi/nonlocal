import ACP
import Foundation

public struct NonlocalSubagentInfo: Codable, Equatable, Sendable {
    public let sessionId: String
    public let upstreamTitle: String?
    public let depth: Int

    public init(sessionId: String, upstreamTitle: String? = nil, depth: Int) {
        self.sessionId = sessionId
        self.upstreamTitle = upstreamTitle
        self.depth = depth
    }
}

public struct NonlocalSessionInfoResult: Codable, Equatable, Sendable {
    public let sessionId: String
    public let displayTitle: String?
    public let upstreamTitle: String?
    public let cwd: String?
    public let subagents: [NonlocalSubagentInfo]

    public init(
        sessionId: String,
        displayTitle: String? = nil,
        upstreamTitle: String? = nil,
        cwd: String? = nil,
        subagents: [NonlocalSubagentInfo] = []
    ) {
        self.sessionId = sessionId
        self.displayTitle = displayTitle
        self.upstreamTitle = upstreamTitle
        self.cwd = cwd
        self.subagents = subagents
    }
}

public struct NonlocalSessionDeletedNotification: Codable, Equatable, Sendable {
    public let instanceId: String?
    public let sessionId: String

    public init(instanceId: String? = nil, sessionId: String) {
        self.instanceId = instanceId
        self.sessionId = sessionId
    }
}

public enum NonlocalSessionInfoParser {
    public static func parseSessionInfo(from value: ACP.Value?) -> NonlocalSessionInfoResult? {
        guard let object = value?.objectValue,
              let sessionId = nonEmptyString(object["sessionId"]) else {
            return nil
        }

        let displayTitle = nonEmptyString(object["displayTitle"])
        let upstreamTitle = nonEmptyString(object["upstreamTitle"])
        let cwd = nonEmptyString(object["cwd"])

        let subagents: [NonlocalSubagentInfo]
        if case let .array(rawSubagents)? = object["subagents"] {
            subagents = rawSubagents.compactMap(parseSubagent(from:))
        } else {
            subagents = []
        }

        return NonlocalSessionInfoResult(
            sessionId: sessionId,
            displayTitle: displayTitle,
            upstreamTitle: upstreamTitle,
            cwd: cwd,
            subagents: subagents
        )
    }

    public static func parseSessionDeleted(from value: ACP.Value?) -> NonlocalSessionDeletedNotification? {
        guard let object = value?.objectValue,
              let sessionId = nonEmptyString(object["sessionId"]) else {
            return nil
        }

        let instanceId = nonEmptyString(object["instanceId"])
        return NonlocalSessionDeletedNotification(
            instanceId: instanceId,
            sessionId: sessionId
        )
    }

    private static func parseSubagent(from value: ACP.Value) -> NonlocalSubagentInfo? {
        guard let object = value.objectValue,
              let sessionId = nonEmptyString(object["sessionId"]),
              let depth = parseInt(object["depth"]) else {
            return nil
        }
        let upstreamTitle = nonEmptyString(object["upstreamTitle"])
        return NonlocalSubagentInfo(
            sessionId: sessionId,
            upstreamTitle: upstreamTitle,
            depth: depth
        )
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
