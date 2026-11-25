import Foundation
import ACP

// MARK: - Agent Info

/// Parsed agent information from the initialize response.
public struct AgentProfile: Equatable, Sendable {
    public let id: String?
    public let name: String
    public let title: String?
    public let version: String?
    public let description: String?
    public let modes: [AgentModeOption]
    public var capabilities: AgentCapabilityState

    public init(
        id: String?,
        name: String,
        title: String? = nil,
        version: String? = nil,
        description: String? = nil,
        modes: [AgentModeOption] = [],
        capabilities: AgentCapabilityState = AgentCapabilityState()
    ) {
        self.id = id
        self.name = name
        self.title = title
        self.version = version
        self.description = description
        self.modes = modes
        self.capabilities = capabilities
    }

    /// Display name for the agent (prefers title over name).
    public var displayName: String {
        title ?? name
    }

    /// Full display string including version.
    public var displayNameWithVersion: String {
        if let version, !version.isEmpty {
            return "\(displayName) v\(version)"
        }
        return displayName
    }
}

/// An agent mode (e.g., "plan", "default", "auto-edit", "yolo").
public struct AgentModeOption: Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String?

    public init(id: String, name: String, description: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// A slash command advertised by the agent.
public struct SessionCommand: Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String
    public let inputHint: String?

    public init(id: String, name: String, description: String, inputHint: String? = nil) {
        self.id = id
        self.name = name
        self.description = description
        self.inputHint = inputHint
    }
}

/// Parsed agent capabilities from the initialize response.
public struct AgentCapabilityState: Equatable, Sendable {
    /// Whether the agent supports session/load.
    public var loadSession: Bool

    /// Whether the agent supports session/list.
    public var listSessions: Bool

    /// Prompt capabilities (image, audio, embedded context).
    public var promptCapabilities: PromptCapabilityState

    public init(
        loadSession: Bool = false,
        listSessions: Bool = true,
        promptCapabilities: PromptCapabilityState = PromptCapabilityState()
    ) {
        self.loadSession = loadSession
        self.listSessions = listSessions
        self.promptCapabilities = promptCapabilities
    }
}

/// Prompt capabilities extracted from agentCapabilities.promptCapabilities.
public struct PromptCapabilityState: Equatable, Sendable {
    public var audio: Bool
    public var image: Bool
    public var embeddedContext: Bool

    public init(audio: Bool = false, image: Bool = false, embeddedContext: Bool = false) {
        self.audio = audio
        self.image = image
        self.embeddedContext = embeddedContext
    }
}

// MARK: - Parsing

public extension AgentProfile {
    /// Parse AgentProfile from an initialize response result.
    /// - Parameter result: The "result" object from the initialize response.
    static func parse(from result: [String: ACP.Value]) -> AgentProfile {
        let agentObj = result["agentInfo"]?.objectValue
            ?? result["agent"]?.objectValue
            ?? [:]

        let name = agentObj["name"]?.stringValue ?? "Agent"
        let id = agentObj["id"]?.stringValue
        let title = agentObj["title"]?.stringValue
        let version = agentObj["version"]?.stringValue
        let description = agentObj["description"]?.stringValue

        var modes: [AgentModeOption] = []
        if let modesObj = result["modes"]?.objectValue,
           case let .array(availableModes)? = modesObj["availableModes"] {
            modes = availableModes.compactMap { modeValue -> AgentModeOption? in
                guard let modeObj = modeValue.objectValue,
                      let modeId = modeObj["id"]?.stringValue,
                      let modeName = modeObj["name"]?.stringValue else { return nil }
                return AgentModeOption(
                    id: modeId,
                    name: modeName,
                    description: modeObj["description"]?.stringValue
                )
            }
        }

        var capabilities = AgentCapabilityState()
        let capabilitiesObj = result["agentCapabilities"]?.objectValue
            ?? result["capabilities"]?.objectValue
            ?? [:]

        if let loadSession = capabilitiesObj["loadSession"]?.boolValue {
            capabilities.loadSession = loadSession
        }

        if let listSessions = capabilitiesObj["listSessions"]?.boolValue {
            capabilities.listSessions = listSessions
        }

        if let promptCaps = capabilitiesObj["promptCapabilities"]?.objectValue {
            capabilities.promptCapabilities.audio = promptCaps["audio"]?.boolValue ?? false
            capabilities.promptCapabilities.image = promptCaps["image"]?.boolValue ?? false
            capabilities.promptCapabilities.embeddedContext = promptCaps["embeddedContext"]?.boolValue ?? false
        }

        return AgentProfile(
            id: id,
            name: name,
            title: title,
            version: version,
            description: description,
            modes: modes,
            capabilities: capabilities
        )
    }
}

public extension SessionCommand {
    static func parse(from update: [String: ACP.Value]) -> [SessionCommand] {
        guard case let .array(commandValues)? = update["availableCommands"] else { return [] }

        return commandValues.compactMap { value in
            guard let commandObj = value.objectValue,
                  let name = commandObj["name"]?.stringValue,
                  let description = commandObj["description"]?.stringValue else { return nil }
            let inputHint = commandObj["input"]?.objectValue?["hint"]?.stringValue

            return SessionCommand(id: name, name: name, description: description, inputHint: inputHint)
        }
    }
}
