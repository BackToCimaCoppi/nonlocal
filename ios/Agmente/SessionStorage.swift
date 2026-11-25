import CoreData
import Foundation
import ACPClient

/// Provides Core Data persistence for servers and sessions.
/// Sessions are stored locally so they can be restored via `session/load` after app restart.
final class SessionStorage {
    static let shared = SessionStorage(container: PersistenceController.shared.container)
    
    private let container: NSPersistentContainer
    private var viewContext: NSManagedObjectContext { container.viewContext }

    private func insertStoredServer() -> StoredServer? {
        guard let entity = NSEntityDescription.entity(forEntityName: "StoredServer", in: viewContext) else {
            return nil
        }
        return StoredServer(entity: entity, insertInto: viewContext)
    }

    private func insertStoredSession() -> StoredSession? {
        guard let entity = NSEntityDescription.entity(forEntityName: "StoredSession", in: viewContext) else {
            return nil
        }
        return StoredSession(entity: entity, insertInto: viewContext)
    }

    private func insertStoredMessage() -> StoredMessage? {
        guard let entity = NSEntityDescription.entity(forEntityName: "StoredMessage", in: viewContext) else {
            return nil
        }
        return StoredMessage(entity: entity, insertInto: viewContext)
    }

    private func storedMessageRequest(for session: StoredSession) -> NSFetchRequest<StoredMessage> {
        let request = NSFetchRequest<StoredMessage>(entityName: "StoredMessage")
        request.predicate = NSPredicate(format: "session == %@", session)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \StoredMessage.orderIndex, ascending: true)]
        return request
    }
    
    init(container: NSPersistentContainer) {
        self.container = container
    }

    static func inMemory() -> SessionStorage {
        let controller = PersistenceController(inMemory: true)
        return SessionStorage(container: controller.container)
    }
    
    // MARK: - Server Operations
    
    /// Fetch all stored servers.
    func fetchServers() -> [ACPServerConfiguration] {
        let request = NSFetchRequest<StoredServer>(entityName: "StoredServer")
        request.sortDescriptors = [NSSortDescriptor(keyPath: \StoredServer.name, ascending: true)]
        
        do {
            let results = try viewContext.fetch(request)
            return results.map { stored in
                let workingDirectory = Self.normalizedWorkingDirectory(stored.workingDirectory ?? "") ?? ""
                return ACPServerConfiguration(
                    id: stored.id ?? UUID(),
                    name: stored.name ?? "",
                    scheme: stored.scheme ?? "ws",
                    host: stored.host ?? "",
                    token: stored.token ?? "",
                    workingDirectory: workingDirectory
                )
            }
        } catch {
            return []
        }
    }
    
    /// Save or update a server configuration.
    func saveServer(_ server: ACPServerConfiguration) {
        let request = NSFetchRequest<StoredServer>(entityName: "StoredServer")
        request.predicate = NSPredicate(format: "id == %@", server.id as CVarArg)
        
        do {
            let results = try viewContext.fetch(request)
            let stored: StoredServer
            if let existing = results.first {
                stored = existing
            } else {
                guard let newServer = insertStoredServer() else { return }
                stored = newServer
                stored.id = server.id
            }
            
            stored.name = server.name
            stored.scheme = server.scheme
            stored.host = server.host
            stored.token = server.token.trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitizedWorkingDirectory = Self.normalizedWorkingDirectory(server.workingDirectory)
            stored.workingDirectory = sanitizedWorkingDirectory

            // Keep the working directory history in sync with the server's configured default.
            var usedDirectories = (stored.usedWorkingDirectories as? [String]) ?? []
            if let sanitizedWorkingDirectory, !usedDirectories.contains(sanitizedWorkingDirectory) {
                usedDirectories.insert(sanitizedWorkingDirectory, at: 0)
            }
            stored.usedWorkingDirectories = usedDirectories as NSArray

            try viewContext.save()
        } catch {
        }
    }

    /// Trims whitespace from a working directory. Returns `nil` when the result is empty so we don't
    /// overwrite stored values with a fabricated default.
    private static func normalizedWorkingDirectory(_ workingDirectory: String) -> String? {
        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    
    /// Delete a server and all its associated sessions.
    func deleteServer(id: UUID) {
        let request = NSFetchRequest<StoredServer>(entityName: "StoredServer")
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        
        do {
            let results = try viewContext.fetch(request)
            if let stored = results.first {
                viewContext.delete(stored)
                try viewContext.save()
            }
        } catch {
        }
    }
    
    // MARK: - Used Working Directories
    
    /// Fetch the list of working directories that have been used with this server.
    func fetchUsedWorkingDirectories(forServerId serverId: UUID) -> [String] {
        let request = NSFetchRequest<StoredServer>(entityName: "StoredServer")
        request.predicate = NSPredicate(format: "id == %@", serverId as CVarArg)
        
        do {
            if let stored = try viewContext.fetch(request).first,
               let directories = stored.usedWorkingDirectories as? [String] {
                return directories
            }
        } catch {
        }
        return []
    }
    
    /// Add a working directory to the list of used directories for a server.
    /// Returns true if the directory was newly added, false if it was already in the list.
    @discardableResult
    func addUsedWorkingDirectory(_ directory: String, forServerId serverId: UUID) -> Bool {
        let request = NSFetchRequest<StoredServer>(entityName: "StoredServer")
        request.predicate = NSPredicate(format: "id == %@", serverId as CVarArg)

        do {
            if let stored = try viewContext.fetch(request).first {
                var directories = (stored.usedWorkingDirectories as? [String]) ?? []
                if !directories.contains(directory) {
                    directories.append(directory)
                    stored.usedWorkingDirectories = directories as NSArray
                    try viewContext.save()
                    return true
                }
            }
        } catch {
        }
        return false
    }
    
    // MARK: - Session Operations
    
    private func fetchStoredServer(id serverId: UUID) -> StoredServer? {
        let request = NSFetchRequest<StoredServer>(entityName: "StoredServer")
        request.predicate = NSPredicate(format: "id == %@", serverId as CVarArg)
        return (try? viewContext.fetch(request))?.first
    }

    private func fetchStoredSession(sessionId: String, forServerId serverId: UUID) -> StoredSession? {
        let request = NSFetchRequest<StoredSession>(entityName: "StoredSession")
        request.predicate = NSPredicate(
            format: "sessionId == %@ AND server.id == %@",
            sessionId,
            serverId as CVarArg
        )
        return (try? viewContext.fetch(request))?.first
    }

    /// Fetch all sessions for a given server.
    func fetchSessions(forServerId serverId: UUID) -> [StoredSessionInfo] {
        let request = NSFetchRequest<StoredSession>(entityName: "StoredSession")
        request.predicate = NSPredicate(format: "server.id == %@", serverId as CVarArg)
        request.sortDescriptors = [NSSortDescriptor(keyPath: \StoredSession.updatedAt, ascending: false)]
        
        do {
            let results = try viewContext.fetch(request)
            return results.map { stored in
                StoredSessionInfo(
                    sessionId: stored.sessionId ?? "",
                    title: stored.title,
                    cwd: stored.cwd,
                    updatedAt: stored.updatedAt,
                    hasUnread: stored.hasUnread,
                    lastSeenServerUpdatedAt: stored.lastSeenServerUpdatedAt,
                    absorbNextServerUpdatedAt: stored.absorbNextServerUpdatedAt
                )
            }
        } catch {
            return []
        }
    }

    func isUnreadBaselineInitialized(forServerId serverId: UUID) -> Bool {
        fetchStoredServer(id: serverId)?.hasInitializedUnreadBaseline ?? false
    }

    func markUnreadBaselineInitialized(forServerId serverId: UUID) {
        guard let server = fetchStoredServer(id: serverId) else { return }
        guard !server.hasInitializedUnreadBaseline else { return }
        server.hasInitializedUnreadBaseline = true
        try? viewContext.save()
    }

    func updateSessionUnreadState(
        sessionId: String,
        forServerId serverId: UUID,
        hasUnread: Bool? = nil,
        lastSeenServerUpdatedAt: Date? = nil,
        absorbNextServerUpdatedAt: Bool? = nil
    ) {
        guard !sessionId.isEmpty else { return }
        let stored: StoredSession
        if let existing = fetchStoredSession(sessionId: sessionId, forServerId: serverId) {
            stored = existing
        } else {
            guard let server = fetchStoredServer(id: serverId),
                  let newSession = insertStoredSession() else {
                return
            }
            newSession.sessionId = sessionId
            newSession.server = server
            stored = newSession
        }

        if let hasUnread {
            stored.hasUnread = hasUnread
        }
        if let lastSeenServerUpdatedAt {
            stored.lastSeenServerUpdatedAt = lastSeenServerUpdatedAt
        }
        if let absorbNextServerUpdatedAt {
            stored.absorbNextServerUpdatedAt = absorbNextServerUpdatedAt
        }

        if viewContext.hasChanges {
            try? viewContext.save()
        }
    }
    
    /// Save or update a session for a given server.
    /// - Parameter clearTitleWhenNil: When true and `session.title` is `nil`, clears any previously stored title.
    func saveSession(_ session: StoredSessionInfo, forServerId serverId: UUID, clearTitleWhenNil: Bool = false) {
        // First, find the server
        let serverRequest = NSFetchRequest<StoredServer>(entityName: "StoredServer")
        serverRequest.predicate = NSPredicate(format: "id == %@", serverId as CVarArg)
        
        do {
            guard let server = try viewContext.fetch(serverRequest).first else {
                return
            }
            
            // Check if session already exists
            let sessionRequest = NSFetchRequest<StoredSession>(entityName: "StoredSession")
            sessionRequest.predicate = NSPredicate(
                format: "sessionId == %@ AND server.id == %@",
                session.sessionId,
                serverId as CVarArg
            )
            
            let results = try viewContext.fetch(sessionRequest)
            let stored: StoredSession
            let isNew: Bool
            if let existing = results.first {
                stored = existing
                isNew = false
            } else {
                guard let newSession = insertStoredSession() else { return }
                stored = newSession
                stored.sessionId = session.sessionId
                stored.server = server
                isNew = true
            }
            
            // Preserve nil titles by default so callers passing nil as "unknown" don't clobber
            // an existing title; authoritative syncs/renames opt into clearing explicitly.
            if let title = session.title {
                stored.title = title
            } else if clearTitleWhenNil {
                stored.title = nil
            }
            if let cwd = session.cwd {
                stored.cwd = cwd
            }
            if let updatedAt = session.updatedAt {
                stored.updatedAt = updatedAt
            } else if isNew {
                // Avoid forcing "today" grouping for sessions with unknown timestamps.
                stored.updatedAt = nil
            }
            
            try viewContext.save()
        } catch {
        }
    }
    
    /// Update fields of an existing session.
    /// - Parameters:
    ///   - title: When non-nil, updates the stored title.
    ///   - touchUpdatedAt: When true, sets `updatedAt` to `updatedAt ?? Date()` (local activity timestamp).
    ///   - updatedAt: Explicit timestamp to write when `touchUpdatedAt` is true (or non-nil override).
    ///   - clearTitle: When true and `title` is nil, clears the stored title.
    func updateSession(
        sessionId: String,
        forServerId serverId: UUID,
        title: String?,
        touchUpdatedAt: Bool = true,
        updatedAt: Date? = nil,
        clearTitle: Bool = false
    ) {
        if let stored = fetchStoredSession(sessionId: sessionId, forServerId: serverId) {
            if let title = title {
                stored.title = title
            } else if clearTitle {
                stored.title = nil
            }
            if let updatedAt {
                stored.updatedAt = updatedAt
            } else if touchUpdatedAt {
                stored.updatedAt = Date()
            }
            try? viewContext.save()
        }
    }
    
    /// Delete a session.
    func deleteSession(sessionId: String, forServerId serverId: UUID) {
        let request = NSFetchRequest<StoredSession>(entityName: "StoredSession")
        request.predicate = NSPredicate(
            format: "sessionId == %@ AND server.id == %@",
            sessionId,
            serverId as CVarArg
        )
        
        do {
            if let stored = try viewContext.fetch(request).first {
                viewContext.delete(stored)
                try viewContext.save()
            }
        } catch {
        }
    }
    
    /// Delete all sessions for a server.
    func deleteAllSessions(forServerId serverId: UUID) {
        let request = NSFetchRequest<StoredSession>(entityName: "StoredSession")
        request.predicate = NSPredicate(format: "server.id == %@", serverId as CVarArg)
        
        do {
            let results = try viewContext.fetch(request)
            for session in results {
                viewContext.delete(session)
            }
            try viewContext.save()
        } catch {
        }
    }

    /// Remove any stored sessions for this server that are not in `keeping`.
    /// Intended to keep Core Data in sync with agents that support `session/list`.
    @discardableResult
    func pruneSessions(forServerId serverId: UUID, keeping sessionIds: Set<String>) -> Int {
        let request = NSFetchRequest<StoredSession>(entityName: "StoredSession")
        request.predicate = NSPredicate(format: "server.id == %@", serverId as CVarArg)

        do {
            let results = try viewContext.fetch(request)
            var deleted = 0
            for session in results {
                let id = session.sessionId ?? ""
                if !sessionIds.contains(id) {
                    viewContext.delete(session)
                    deleted += 1
                }
            }
            if viewContext.hasChanges {
                try viewContext.save()
            }
            return deleted
        } catch {
            return 0
        }
    }
    
    // MARK: - Message Operations
    
    /// Save messages for a session. Replaces all existing messages.
    func saveMessages(_ messages: [StoredMessageInfo], forSessionId sessionId: String, serverId: UUID) {
        // First find the session
        let sessionRequest = NSFetchRequest<StoredSession>(entityName: "StoredSession")
        sessionRequest.predicate = NSPredicate(
            format: "sessionId == %@ AND server.id == %@",
            sessionId,
            serverId as CVarArg
        )
        
        do {
            guard let session = try viewContext.fetch(sessionRequest).first else {
                return
            }
            
            let existingMessages = try viewContext.fetch(storedMessageRequest(for: session))
            for message in existingMessages {
                viewContext.delete(message)
            }
            
            let messageSet = session.mutableSetValue(forKey: "messages")

            // Add new messages
            for (index, messageInfo) in messages.enumerated() {
                guard let stored = insertStoredMessage() else { continue }
                stored.messageId = messageInfo.messageId
                stored.role = messageInfo.role
                stored.content = messageInfo.content
                stored.createdAt = messageInfo.createdAt
                stored.orderIndex = Int32(index)
                stored.segmentsData = messageInfo.segmentsData
                stored.isError = messageInfo.isError
                stored.session = session
                messageSet.add(stored)
            }
            
            try viewContext.save()
        } catch {
        }
    }
    
    /// Fetch all messages for a session, ordered by creation.
    func fetchMessages(forSessionId sessionId: String, serverId: UUID) -> [StoredMessageInfo] {
        guard let session = fetchStoredSession(sessionId: sessionId, forServerId: serverId) else {
            return []
        }

        do {
            let messages = try viewContext.fetch(storedMessageRequest(for: session))

            return messages.map { stored in
                StoredMessageInfo(
                    messageId: stored.messageId ?? UUID(),
                    role: stored.role ?? "user",
                    content: stored.content ?? "",
                    createdAt: stored.createdAt ?? Date(),
                    segmentsData: stored.segmentsData,
                    isError: stored.isError
                )
            }
        } catch {
            return []
        }
    }
    
    /// Delete all messages for a session.
    func deleteMessages(forSessionId sessionId: String, serverId: UUID) {
        let sessionRequest = NSFetchRequest<StoredSession>(entityName: "StoredSession")
        sessionRequest.predicate = NSPredicate(
            format: "sessionId == %@ AND server.id == %@",
            sessionId,
            serverId as CVarArg
        )
        
        do {
            guard let session = try viewContext.fetch(sessionRequest).first else {
                return
            }

            let existingMessages = try viewContext.fetch(storedMessageRequest(for: session))
            for message in existingMessages {
                viewContext.delete(message)
            }

            try viewContext.save()
        } catch {
        }
    }
}

// MARK: - Data Types

/// A lightweight struct representing session info stored in Core Data.
/// Maps to the `StoredSession` entity but is easier to work with in Swift code.
struct StoredSessionInfo: Identifiable, Hashable {
    var id: String { sessionId }
    let sessionId: String
    let title: String?
    let cwd: String?
    let updatedAt: Date?
    let hasUnread: Bool
    let lastSeenServerUpdatedAt: Date?
    let absorbNextServerUpdatedAt: Bool

    init(
        sessionId: String,
        title: String?,
        cwd: String?,
        updatedAt: Date?,
        hasUnread: Bool = false,
        lastSeenServerUpdatedAt: Date? = nil,
        absorbNextServerUpdatedAt: Bool = false
    ) {
        self.sessionId = sessionId
        self.title = title
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.hasUnread = hasUnread
        self.lastSeenServerUpdatedAt = lastSeenServerUpdatedAt
        self.absorbNextServerUpdatedAt = absorbNextServerUpdatedAt
    }

    /// Convert to the view model's SessionSummary type.
    func toSessionSummary() -> SessionSummary {
        SessionSummary(id: sessionId, title: title, cwd: cwd, updatedAt: updatedAt)
    }
}

/// A lightweight struct representing message info stored in Core Data.
/// Maps to the `StoredMessage` entity but is easier to work with in Swift code.
struct StoredMessageInfo: Identifiable, Hashable {
    var id: UUID { messageId }
    let messageId: UUID
    let role: String
    let content: String
    let createdAt: Date
    /// Encoded segments data (for assistant messages with tool calls, etc.)
    let segmentsData: Data?
    let isError: Bool

    init(
        messageId: UUID,
        role: String,
        content: String,
        createdAt: Date,
        segmentsData: Data?,
        isError: Bool = false
    ) {
        self.messageId = messageId
        self.role = role
        self.content = content
        self.createdAt = createdAt
        self.segmentsData = segmentsData
        self.isError = isError
    }
}
