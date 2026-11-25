import Foundation

struct ChatEntry: Identifiable, Hashable {
    enum Kind: String {
        case userText
        case userImages
        case assistantMarkdown
        case assistantThought
        case assistantPlan
        case assistantMermaid
        case toolCall
        case fileChanges
        case system
        case error
        case streamingIndicator
    }

    let id: String
    let kind: Kind
    let text: String
    let images: [ChatImageData]
    let segment: AssistantSegment?
    let fileChanges: [FileChangeSummaryItem]
    let isStreaming: Bool
    let showsRetryButton: Bool
    let messageId: UUID
    let contentHash: Int

    private init(
        id: String,
        kind: Kind,
        text: String,
        images: [ChatImageData] = [],
        segment: AssistantSegment? = nil,
        fileChanges: [FileChangeSummaryItem] = [],
        isStreaming: Bool = false,
        showsRetryButton: Bool = false,
        messageId: UUID,
        contentHash: Int
    ) {
        self.id = id
        self.kind = kind
        self.text = text
        self.images = images
        self.segment = segment
        self.fileChanges = fileChanges
        self.isStreaming = isStreaming
        self.showsRetryButton = showsRetryButton
        self.messageId = messageId
        self.contentHash = contentHash
    }

    static func userText(messageId: UUID, text: String, showsRetryButton: Bool = false) -> ChatEntry {
        ChatEntry(
            id: "message.\(messageId.uuidString).userText",
            kind: .userText,
            text: text,
            showsRetryButton: showsRetryButton,
            messageId: messageId,
            contentHash: (text + ".\(showsRetryButton)").hashValue
        )
    }

    static func userImages(messageId: UUID, images: [ChatImageData], showsRetryButton: Bool = false) -> ChatEntry {
        let imageSignature = images.map { $0.id.uuidString }.joined(separator: ",")
        return ChatEntry(
            id: "message.\(messageId.uuidString).userImages",
            kind: .userImages,
            text: "",
            images: images,
            showsRetryButton: showsRetryButton,
            messageId: messageId,
            contentHash: (imageSignature + ".\(showsRetryButton)").hashValue
        )
    }

    static func assistantMarkdown(messageId: UUID, segmentId: UUID, text: String, suffix: String = "") -> ChatEntry {
        let idSuffix = suffix.isEmpty ? "" : ".\(suffix)"
        return ChatEntry(
            id: "message.\(messageId.uuidString).assistantMarkdown.\(segmentId.uuidString)\(idSuffix)",
            kind: .assistantMarkdown,
            text: text,
            messageId: messageId,
            contentHash: text.hashValue
        )
    }

    static func assistantMermaid(messageId: UUID, segmentId: UUID, sourceKind: String, index: Int, source: String) -> ChatEntry {
        ChatEntry(
            id: "message.\(messageId.uuidString).assistantMermaid.\(sourceKind).\(segmentId.uuidString).\(index)",
            kind: .assistantMermaid,
            text: source,
            messageId: messageId,
            contentHash: source.hashValue
        )
    }

    static func assistantThought(messageId: UUID, segmentId: UUID, text: String, isStreaming: Bool, suffix: String = "") -> ChatEntry {
        let idSuffix = suffix.isEmpty ? "" : ".\(suffix)"
        return ChatEntry(
            id: "message.\(messageId.uuidString).assistantThought.\(segmentId.uuidString)\(idSuffix)",
            kind: .assistantThought,
            text: text,
            isStreaming: isStreaming,
            messageId: messageId,
            contentHash: (text + ".\(isStreaming)").hashValue
        )
    }

    static func assistantPlan(messageId: UUID, segmentId: UUID, text: String, isStreaming: Bool, suffix: String = "") -> ChatEntry {
        let idSuffix = suffix.isEmpty ? "" : ".\(suffix)"
        return ChatEntry(
            id: "message.\(messageId.uuidString).assistantPlan.\(segmentId.uuidString)\(idSuffix)",
            kind: .assistantPlan,
            text: text,
            isStreaming: isStreaming,
            messageId: messageId,
            contentHash: (text + ".\(isStreaming)").hashValue
        )
    }

    static func toolCall(messageId: UUID, segment: AssistantSegment, isStreaming: Bool) -> ChatEntry {
        let signature = toolCallSignature(segment: segment, isStreaming: isStreaming)
        return ChatEntry(
            id: "message.\(messageId.uuidString).toolCall.\(segment.id.uuidString)",
            kind: .toolCall,
            text: segment.text,
            segment: segment,
            isStreaming: isStreaming,
            messageId: messageId,
            contentHash: signature.hashValue
        )
    }

    static func fileChanges(messageId: UUID, items: [FileChangeSummaryItem]) -> ChatEntry {
        let signature = items.map { "\($0.id):\($0.path):\($0.status ?? "")" }.joined(separator: "|")
        return ChatEntry(
            id: "message.\(messageId.uuidString).fileChanges",
            kind: .fileChanges,
            text: "",
            fileChanges: items,
            messageId: messageId,
            contentHash: signature.hashValue
        )
    }

    static func system(messageId: UUID, text: String, isError: Bool) -> ChatEntry {
        ChatEntry(
            id: "message.\(messageId.uuidString).system",
            kind: isError ? .error : .system,
            text: text,
            messageId: messageId,
            contentHash: (text + ".\(isError)").hashValue
        )
    }

    static func streamingIndicator(messageId: UUID, text: String? = nil, suffix: String = "") -> ChatEntry {
        let resolvedText: String
        if let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            resolvedText = trimmed
        } else {
            resolvedText = String(localized: "Thinking…")
        }
        return ChatEntry(
            id: "message.\(messageId.uuidString).streaming\(suffix.isEmpty ? "" : ".\(suffix)")",
            kind: .streamingIndicator,
            text: resolvedText,
            isStreaming: true,
            messageId: messageId,
            contentHash: resolvedText.hashValue
        )
    }

    static func == (lhs: ChatEntry, rhs: ChatEntry) -> Bool {
        lhs.id == rhs.id && lhs.contentHash == rhs.contentHash
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(contentHash)
    }

    private static func toolCallSignature(segment: AssistantSegment, isStreaming: Bool) -> String {
        let tool = segment.toolCall
        let optionSignature = tool?.permissionOptions?.map { "\($0.optionId):\($0.name)" }.joined(separator: ",") ?? ""

        var signatureParts: [String] = []
        signatureParts.reserveCapacity(11)
        signatureParts.append(segment.id.uuidString)
        signatureParts.append(segment.kind.rawValue)
        signatureParts.append(segment.text)
        signatureParts.append(tool?.toolCallId ?? "")
        signatureParts.append(tool?.title ?? "")
        signatureParts.append(tool?.kind ?? "")
        signatureParts.append(tool?.status ?? "")
        signatureParts.append(tool?.output ?? "")
        signatureParts.append(optionSignature)
        signatureParts.append(tool?.acpPermissionRequestId?.description ?? "")
        signatureParts.append(String(isStreaming))
        return signatureParts.joined(separator: "|")
    }

    func withContentHashSalt(_ salt: Int) -> ChatEntry {
        ChatEntry(
            id: id,
            kind: kind,
            text: text,
            images: images,
            segment: segment,
            fileChanges: fileChanges,
            isStreaming: isStreaming,
            showsRetryButton: showsRetryButton,
            messageId: messageId,
            contentHash: contentHash ^ salt
        )
    }
}
