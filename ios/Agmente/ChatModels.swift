import Foundation
import ACP
import ACPClient

struct ChatMessage: Identifiable, Equatable {
    enum Role: String, Codable {
        case user
        case assistant
        case system
    }

    let id: UUID
    let role: Role
    var content: String
    var isStreaming: Bool
    var segments: [AssistantSegment]
    var images: [ChatImageData]
    var isError: Bool

    init(
        role: Role,
        content: String,
        isStreaming: Bool,
        segments: [AssistantSegment] = [],
        images: [ChatImageData] = [],
        isError: Bool = false
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.isStreaming = isStreaming
        self.segments = segments
        self.images = images
        self.isError = isError
    }

    /// Initialize from stored message info (for restoring from Core Data).
    init(from stored: StoredMessageInfo) {
        self.id = stored.messageId
        self.role = Role(rawValue: stored.role) ?? .user
        self.content = stored.content
        self.isStreaming = false
        self.images = []
        self.segments = []
        self.isError = stored.isError

        if let segmentsData = stored.segmentsData,
           let decoded = try? JSONDecoder().decode([CodableSegment].self, from: segmentsData) {
            self.segments = decoded.map { $0.toSegment() }
        }
    }

    /// Convert to storable message info.
    func toStoredInfo(createdAt: Date = Date()) -> StoredMessageInfo {
        let segmentsData: Data?
        if !segments.isEmpty {
            let codableSegments = segments.map { CodableSegment(from: $0) }
            segmentsData = try? JSONEncoder().encode(codableSegments)
        } else {
            segmentsData = nil
        }

        return StoredMessageInfo(
            messageId: id,
            role: role.rawValue,
            content: content,
            createdAt: createdAt,
            segmentsData: segmentsData,
            isError: isError
        )
    }
}

/// Codable version of AssistantSegment for persistence.
struct CodableSegment: Codable {
    let id: UUID
    let kind: String
    let text: String
    let toolCall: CodableToolCall?

    init(from segment: AssistantSegment) {
        self.id = segment.id
        self.kind = segment.kind.rawValue
        self.text = segment.text
        self.toolCall = segment.toolCall.map { CodableToolCall(from: $0) }
    }

    func toSegment() -> AssistantSegment {
        AssistantSegment(
            kind: AssistantSegment.Kind(rawValue: kind) ?? .message,
            text: text,
            toolCall: toolCall?.toToolCall()
        )
    }
}

/// Codable version of ToolCallDisplay for persistence.
struct CodableToolCall: Codable {
    let toolCallId: String?
    let title: String
    let kind: String?
    let status: String?
    let output: String?
    let diffs: [ACPToolCallDiff]?

    init(from display: ToolCallDisplay) {
        self.toolCallId = display.toolCallId
        self.title = display.title
        self.kind = display.kind
        self.status = display.status
        self.output = display.output
        self.diffs = display.diffs.isEmpty ? nil : display.diffs
    }

    func toToolCall() -> ToolCallDisplay {
        ToolCallDisplay(
            toolCallId: toolCallId,
            title: title,
            kind: kind,
            status: status,
            output: output,
            diffs: diffs ?? [],
            permissionOptions: nil,
            acpPermissionRequestId: nil
        )
    }
}

struct AssistantSegment: Identifiable, Equatable {
    enum Kind: String, Codable {
        case message
        case thought
        case toolCall
        case plan
    }

    let id: UUID
    var kind: Kind
    var text: String
    var toolCall: ToolCallDisplay?

    init(kind: Kind, text: String = "", toolCall: ToolCallDisplay? = nil) {
        self.id = UUID()
        self.kind = kind
        self.text = text
        self.toolCall = toolCall
    }
}

struct ToolCallDisplay: Equatable {
    var toolCallId: String?
    var title: String
    var kind: String?
    var status: String?
    var output: String?
    var diffs: [ACPToolCallDiff] = []
    var permissionOptions: [ACPPermissionOption]?
    var acpPermissionRequestId: ACP.ID?
}

extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool {
        self?.isEmpty ?? true
    }
}
