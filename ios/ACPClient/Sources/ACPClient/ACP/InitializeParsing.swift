import Foundation
import ACP

public struct ACPAuthMethod: Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String?) {
        self.id = id
        self.name = name
        self.description = description
    }
}

public struct ACPInitializeResult: Equatable, Sendable {
    public let agentInfo: AgentProfile?
    public let authMethods: [ACPAuthMethod]
    public let currentModeId: String?
    public let promptCapabilitiesDeclared: Bool

    public init(
        agentInfo: AgentProfile?,
        authMethods: [ACPAuthMethod] = [],
        currentModeId: String? = nil,
        promptCapabilitiesDeclared: Bool = false
    ) {
        self.agentInfo = agentInfo
        self.authMethods = authMethods
        self.currentModeId = currentModeId
        self.promptCapabilitiesDeclared = promptCapabilitiesDeclared
    }
}

public enum ACPInitializeParser {
    public static func parse(result: ACP.Value?) -> ACPInitializeResult? {
        guard let resultObject = result?.objectValue else { return nil }
        return parse(result: resultObject)
    }

    public static func parse(result: [String: ACP.Value]) -> ACPInitializeResult? {
        let hasAcpMarkers = result["protocolVersion"] != nil
            || result["agentCapabilities"] != nil
            || result["agentInfo"] != nil
            || result["agent"] != nil

        guard hasAcpMarkers else {
            return nil
        }

        let authMethods: [ACPAuthMethod]
        if case let .array(items)? = result["authMethods"] {
            authMethods = items.compactMap { item in
                guard let obj = item.objectValue,
                      let id = obj["id"]?.stringValue,
                      let name = obj["name"]?.stringValue else {
                    return nil
                }
                let description = obj["description"]?.stringValue
                return ACPAuthMethod(id: id, name: name, description: description)
            }
        } else {
            authMethods = []
        }

        let currentModeId = result["modes"]?.objectValue?["currentModeId"]?.stringValue

        let capabilitiesObj = result["agentCapabilities"]?.objectValue
            ?? result["capabilities"]?.objectValue
        let promptCapabilitiesDeclared = capabilitiesObj?["promptCapabilities"]?.objectValue != nil

        let agentInfo = AgentProfile.parse(from: result)

        return ACPInitializeResult(
            agentInfo: agentInfo,
            authMethods: authMethods,
            currentModeId: currentModeId,
            promptCapabilitiesDeclared: promptCapabilitiesDeclared
        )
    }
}
