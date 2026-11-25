import Foundation

struct ChatEntryMapper {
    private static let standaloneLiveIndicatorMessageId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    func entries(
        from messages: [ChatMessage],
        liveStatusText: String? = nil,
        failedDeliveryMessageIds: Set<UUID> = []
    ) -> [ChatEntry] {
        var entries: [ChatEntry] = []
        entries.reserveCapacity(messages.count * 2)

        for (index, message) in messages.enumerated() {
            let isLastStreamingAssistant = message.role == .assistant && message.isStreaming && index == messages.indices.last
            switch message.role {
            case .user:
                mapUserMessage(message, failedDeliveryMessageIds: failedDeliveryMessageIds, into: &entries)
            case .assistant:
                mapAssistantMessage(
                    message,
                    liveStatusText: isLastStreamingAssistant ? liveStatusText : nil,
                    into: &entries
                )
            case .system:
                mapSystemMessage(message, into: &entries)
            }
        }

        if let liveStatus = liveStatusText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !liveStatus.isEmpty,
           !entries.contains(where: { $0.kind == .streamingIndicator }) {
            entries.append(
                .streamingIndicator(
                    messageId: Self.standaloneLiveIndicatorMessageId,
                    text: liveStatus,
                    suffix: "live"
                )
            )
        }

        return entries
    }

    private func mapUserMessage(
        _ message: ChatMessage,
        failedDeliveryMessageIds: Set<UUID>,
        into entries: inout [ChatEntry]
    ) {
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let isFailed = failedDeliveryMessageIds.contains(message.id)
        let hasText = !text.isEmpty

        if !message.images.isEmpty {
            entries.append(
                .userImages(
                    messageId: message.id,
                    images: message.images,
                    showsRetryButton: isFailed && !hasText
                )
            )
        }

        if hasText {
            entries.append(
                .userText(
                    messageId: message.id,
                    text: text,
                    showsRetryButton: isFailed
                )
            )
        }
    }

    private func mapAssistantMessage(_ message: ChatMessage, liveStatusText: String?, into entries: inout [ChatEntry]) {
        let segments = resolvedSegments(for: message)
        let fileChangeSegments = segments.filter { FileChangeSummary.isFileChangeSegment($0) }
        let contentSegments = segments.filter { !FileChangeSummary.isFileChangeSegment($0) }

        var hasVisibleContent = false

        for segment in contentSegments {
            switch segment.kind {
            case .message:
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let chunks = Self.splitMermaidBlocks(text)
                if chunks.count == 1, case .markdown(let md) = chunks[0] {
                    entries.append(.assistantMarkdown(messageId: message.id, segmentId: segment.id, text: md))
                } else {
                    for (chunkIdx, chunk) in chunks.enumerated() {
                        switch chunk {
                        case .markdown(let md):
                            entries.append(.assistantMarkdown(messageId: message.id, segmentId: segment.id, text: md, suffix: "p\(chunkIdx)"))
                        case .mermaid(let src):
                            entries.append(.assistantMermaid(messageId: message.id, segmentId: segment.id, sourceKind: "message", index: chunkIdx, source: src))
                        }
                    }
                }
                hasVisibleContent = true
            case .thought:
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let chunks = Self.splitMermaidBlocks(text)
                if chunks.count == 1, case .markdown(let md) = chunks[0] {
                    entries.append(.assistantThought(messageId: message.id, segmentId: segment.id, text: md, isStreaming: message.isStreaming))
                } else {
                    for (chunkIdx, chunk) in chunks.enumerated() {
                        switch chunk {
                        case .markdown(let md):
                            entries.append(.assistantThought(messageId: message.id, segmentId: segment.id, text: md, isStreaming: message.isStreaming, suffix: "p\(chunkIdx)"))
                        case .mermaid(let src):
                            entries.append(.assistantMermaid(messageId: message.id, segmentId: segment.id, sourceKind: "thought", index: chunkIdx, source: src))
                        }
                    }
                }
                hasVisibleContent = true
            case .plan:
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                let chunks = Self.splitMermaidBlocks(text)
                if chunks.count == 1, case .markdown(let md) = chunks[0] {
                    entries.append(.assistantPlan(messageId: message.id, segmentId: segment.id, text: md, isStreaming: message.isStreaming))
                } else {
                    for (chunkIdx, chunk) in chunks.enumerated() {
                        switch chunk {
                        case .markdown(let md):
                            entries.append(.assistantPlan(messageId: message.id, segmentId: segment.id, text: md, isStreaming: message.isStreaming, suffix: "p\(chunkIdx)"))
                        case .mermaid(let src):
                            entries.append(.assistantMermaid(messageId: message.id, segmentId: segment.id, sourceKind: "plan", index: chunkIdx, source: src))
                        }
                    }
                }
                hasVisibleContent = true
            case .toolCall:
                entries.append(.toolCall(messageId: message.id, segment: segment, isStreaming: message.isStreaming))
                hasVisibleContent = true
            }
        }

        let fileChangeItems = FileChangeSummary.items(from: fileChangeSegments)
        if !fileChangeItems.isEmpty {
            entries.append(.fileChanges(messageId: message.id, items: fileChangeItems))
            hasVisibleContent = true
        }

        if message.isStreaming {
            entries.append(
                .streamingIndicator(
                    messageId: message.id,
                    text: liveStatusText,
                    suffix: hasVisibleContent ? "tail" : "solo"
                )
            )
        }
    }

    private func mapSystemMessage(_ message: ChatMessage, into entries: inout [ChatEntry]) {
        let text = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        entries.append(.system(messageId: message.id, text: text, isError: message.isError))
    }

    private func resolvedSegments(for message: ChatMessage) -> [AssistantSegment] {
        if !message.segments.isEmpty {
            return message.segments
        }

        let parsed = parseAssistantContent(message.content)
        return parsed.compactMap { segment in
            if segment.isToolCall {
                let parsed = parseToolCallDisplay(from: segment.text)
                return AssistantSegment(kind: .toolCall, text: parsed.title, toolCall: parsed)
            }

            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return AssistantSegment(kind: .message, text: text)
        }
    }

    private struct ContentSegment {
        let text: String
        let isToolCall: Bool
    }

    private func parseAssistantContent(_ content: String) -> [ContentSegment] {
        var segments: [ContentSegment] = []
        var currentText = ""

        let lines = content.components(separatedBy: "\n")
        for line in lines {
            if line.hasPrefix("Tool call:") {
                if !currentText.isEmpty {
                    segments.append(ContentSegment(text: currentText.trimmingCharacters(in: .whitespacesAndNewlines), isToolCall: false))
                    currentText = ""
                }
                segments.append(ContentSegment(text: line, isToolCall: true))
            } else {
                if !currentText.isEmpty {
                    currentText += "\n"
                }
                currentText += line
            }
        }

        if !currentText.isEmpty {
            segments.append(ContentSegment(text: currentText.trimmingCharacters(in: .whitespacesAndNewlines), isToolCall: false))
        }

        return segments
    }

    private func parseToolCallDisplay(from text: String) -> ToolCallDisplay {
        var displayContent = text
        if displayContent.hasPrefix("Tool call: ") {
            displayContent = String(displayContent.dropFirst("Tool call: ".count))
        }

        var toolKind: String? = nil
        if displayContent.hasPrefix("["), let endBracket = displayContent.firstIndex(of: "]") {
            toolKind = String(displayContent[displayContent.index(after: displayContent.startIndex)..<endBracket])
            displayContent = String(displayContent[displayContent.index(after: endBracket)...]).trimmingCharacters(in: .whitespaces)
        }

        var status: String? = nil
        if let statusStart = displayContent.lastIndex(of: "("),
           let statusEnd = displayContent.lastIndex(of: ")"),
           statusStart < statusEnd {
            status = String(displayContent[displayContent.index(after: statusStart)..<statusEnd])
            displayContent = String(displayContent[..<statusStart]).trimmingCharacters(in: .whitespaces)
        }

        return ToolCallDisplay(toolCallId: nil, title: displayContent, kind: toolKind, status: status)
    }

    // MARK: - Top-Level Closed Non-Empty Mermaid Block Splitter (T10 / SD-6.2 / AC-601 & AC-602)

    enum MermaidSplitChunk: Equatable {
        case markdown(String)
        case mermaid(String)
    }

    static func splitMermaidBlocks(_ text: String) -> [MermaidSplitChunk] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var chunks: [MermaidSplitChunk] = []
        var markdownBuffer: [String] = []

        func flushMarkdown() {
            let joined = markdownBuffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                chunks.append(.markdown(joined))
            }
            markdownBuffer.removeAll()
        }

        var i = 0
        while i < lines.count {
            let line = lines[i]
            if let open = parseFenceOpen(line) {
                let isMermaid = open.language.lowercased() == "mermaid"
                var blockLines: [String] = []
                var closed = false
                var j = i + 1
                while j < lines.count {
                    if isFenceClose(lines[j], char: open.char, minLength: open.length) {
                        closed = true
                        j += 1
                        break
                    }
                    blockLines.append(lines[j])
                    j += 1
                }

                if isMermaid && closed {
                    let body = blockLines.joined(separator: "\n")
                    if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        flushMarkdown()
                        chunks.append(.mermaid(body))
                    } else {
                        // Empty / whitespace-only mermaid block stays as plain markdown code block (AC-602)
                        markdownBuffer.append(contentsOf: lines[i..<j])
                    }
                } else {
                    // Non-mermaid outer fence (e.g. ````markdown with nested ```mermaid) OR unclosed streaming tail stays intact
                    markdownBuffer.append(contentsOf: lines[i..<j])
                }
                i = j
                continue
            }

            markdownBuffer.append(line)
            i += 1
        }

        flushMarkdown()
        return chunks
    }

    private static func parseFenceOpen(_ line: String) -> (char: Character, length: Int, language: String)? {
        var idx = line.startIndex
        var spaces = 0
        while idx < line.endIndex && line[idx] == " " && spaces < 3 {
            spaces += 1
            idx = line.index(after: idx)
        }
        guard idx < line.endIndex else { return nil }
        let ch = line[idx]
        guard ch == "`" || ch == "~" else { return nil }
        var count = 0
        while idx < line.endIndex && line[idx] == ch {
            count += 1
            idx = line.index(after: idx)
        }
        guard count >= 3 else { return nil }
        let rest = String(line[idx...]).trimmingCharacters(in: .whitespaces)
        if ch == "`" && rest.contains("`") { return nil }
        let lang = rest.split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        return (ch, count, lang)
    }

    private static func isFenceClose(_ line: String, char: Character, minLength: Int) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= minLength else { return false }
        return trimmed.allSatisfy { $0 == char }
    }
}
