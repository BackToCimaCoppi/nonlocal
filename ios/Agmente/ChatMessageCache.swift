import Foundation

/// Pure in-memory cache for per-server, per-session chat messages and stop reasons (SD-2.4).
/// Strictly decoupled from Core Data persistence and view models.
@MainActor
final class ChatMessageCache: ACPSessionCacheDelegate {
    private(set) var chatCache: [UUID: [String: [ChatMessage]]] = [:]
    private(set) var stopReasonCache: [UUID: [String: String]] = [:]

    func saveMessages(_ messages: [ChatMessage], for serverId: UUID, sessionId: String) {
        var serverChats = chatCache[serverId] ?? [:]
        serverChats[sessionId] = messages
        chatCache[serverId] = serverChats
    }

    func loadMessages(for serverId: UUID, sessionId: String) -> [ChatMessage]? {
        chatCache[serverId]?[sessionId]
    }

    func saveStopReason(_ reason: String, for serverId: UUID, sessionId: String) {
        var serverStops = stopReasonCache[serverId] ?? [:]
        serverStops[sessionId] = reason
        stopReasonCache[serverId] = serverStops
    }

    func loadStopReason(for serverId: UUID, sessionId: String) -> String? {
        stopReasonCache[serverId]?[sessionId]
    }

    func clearCache(for serverId: UUID, sessionId: String) {
        var serverChats = chatCache[serverId] ?? [:]
        serverChats.removeValue(forKey: sessionId)
        chatCache[serverId] = serverChats

        var serverStops = stopReasonCache[serverId] ?? [:]
        serverStops.removeValue(forKey: sessionId)
        stopReasonCache[serverId] = serverStops
    }

    func clearCache(for serverId: UUID) {
        chatCache.removeValue(forKey: serverId)
        stopReasonCache.removeValue(forKey: serverId)
    }

    func migrateCache(serverId: UUID, from placeholderId: String, to resolvedId: String) {
        guard placeholderId != resolvedId else { return }

        if var serverChats = chatCache[serverId], let placeholderChat = serverChats[placeholderId] {
            if serverChats[resolvedId]?.isEmpty != false {
                serverChats[resolvedId] = placeholderChat
            }
            chatCache[serverId] = serverChats
        }

        if var serverStops = stopReasonCache[serverId],
           let stop = serverStops[placeholderId],
           serverStops[resolvedId] == nil {
            serverStops[resolvedId] = stop
            stopReasonCache[serverId] = serverStops
        }
    }

    func hasCachedMessages(serverId: UUID, sessionId: String) -> Bool {
        chatCache[serverId]?[sessionId]?.isEmpty == false
    }

    func getLastMessagePreview(for serverId: UUID, sessionId: String) -> String? {
        guard let messages = chatCache[serverId]?[sessionId],
              let lastMessage = messages.last else { return nil }

        switch lastMessage.role {
        case .assistant:
            if !lastMessage.segments.isEmpty {
                let messageText = lastMessage.segments
                    .filter { $0.kind == .message }
                    .map(\.text)
                    .joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if messageText.isEmpty { return nil }
                return messageText.count > 60 ? String(messageText.prefix(60)) + "…" : messageText
            }
            let rawText = lastMessage.content
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("Tool call:") }
                .joined(separator: "\n")
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return nil }
            return text.count > 60 ? String(text.prefix(60)) + "…" : text
        case .user:
            let text = lastMessage.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return nil }
            return "You: " + (text.count > 50 ? String(text.prefix(50)) + "…" : text)
        case .system:
            return nil
        }
    }
}
