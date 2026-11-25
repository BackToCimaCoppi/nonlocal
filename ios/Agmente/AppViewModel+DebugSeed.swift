#if DEBUG
import Foundation
import ACPClient

extension AppViewModel {
    /// Debug-only UI test fixture seeder triggered exclusively by `-w2-seed-json` / `-w2-seed-b64` / `W2_SEED_B64`.
    /// Supports explicit `devModeEnabled` (defaults to `true` for legacy Wave 2 tests; pass `false` for SC-AC-057)
    /// and pre-seeded session messages (`SeedMessage`) for non-empty German chat UIKit verification (SC-AC-065).
    struct Wave2DebugSeedPayload: Decodable {
        struct SeedMessage: Decodable {
            let role: String
            let content: String
            let isError: Bool?
        }
        struct SeedSession: Decodable {
            let sessionId: String
            let title: String?
            let cwd: String?
            let updatedAtOffsetSeconds: Double?
            let isUnread: Bool?
            let messages: [SeedMessage]?
        }
        struct SeedProject: Decodable {
            let name: String
            let directories: [String]
        }
        struct SeedServer: Decodable {
            let id: UUID?
            let name: String
            let scheme: String
            let host: String
            let token: String?
            let workingDirectory: String
            let sessions: [SeedSession]?
            let projects: [SeedProject]?
        }
        let homeDisplayMode: String?
        let selectedServerIndex: Int?
        let devModeEnabled: Bool?
        let servers: [SeedServer]
    }

    static func hasWave2DebugSeedLaunchRequest() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let b64 = env["W2_SEED_B64"], !b64.isEmpty {
            return true
        }
        let args = ProcessInfo.processInfo.arguments
        if let idx = args.firstIndex(of: "-w2-seed-b64"), idx + 1 < args.count {
            return true
        }
        if let idx = args.firstIndex(of: "-w2-seed-json"), idx + 1 < args.count {
            return true
        }
        return false
    }

    func applyWave2DebugSeedIfRequested() {
        let env = ProcessInfo.processInfo.environment
        let args = ProcessInfo.processInfo.arguments
        let seedData: Data? = {
            if let b64 = env["W2_SEED_B64"], !b64.isEmpty {
                return Data(base64Encoded: b64)
            }
            if let idx = args.firstIndex(of: "-w2-seed-b64"), idx + 1 < args.count {
                return Data(base64Encoded: args[idx + 1])
            }
            if let idx = args.firstIndex(of: "-w2-seed-json"), idx + 1 < args.count {
                return try? Data(contentsOf: URL(fileURLWithPath: args[idx + 1]))
            }
            return nil
        }()
        guard let data = seedData,
              let payload = try? JSONDecoder().decode(Wave2DebugSeedPayload.self, from: data) else {
            return
        }
        for existing in servers {
            deleteServer(existing.id)
        }
        var seededIds: [UUID] = []
        let now = Date()
        for srv in payload.servers {
            let serverId = addServer(
                id: srv.id,
                name: srv.name,
                scheme: srv.scheme,
                host: srv.host,
                token: srv.token ?? "",
                workingDirectory: srv.workingDirectory
            )
            if let sessions = srv.sessions {
                for s in sessions {
                    let dt = now.addingTimeInterval(s.updatedAtOffsetSeconds ?? -60)
                    let seen = (s.isUnread == true) ? dt.addingTimeInterval(-300) : dt
                    storage.saveSession(
                        StoredSessionInfo(
                            sessionId: s.sessionId,
                            title: s.title,
                            cwd: s.cwd ?? srv.workingDirectory,
                            updatedAt: dt,
                            lastSeenServerUpdatedAt: seen
                        ),
                        forServerId: serverId
                    )
                    if let seedMessages = s.messages, !seedMessages.isEmpty {
                        let storedMessages: [StoredMessageInfo] = seedMessages.enumerated().map { idx, msg in
                            let role = ChatMessage.Role(rawValue: msg.role) ?? .user
                            let segments: [AssistantSegment] = (role == .assistant)
                                ? [AssistantSegment(kind: .message, text: msg.content)]
                                : []
                            let chatMsg = ChatMessage(
                                role: role,
                                content: msg.content,
                                isStreaming: false,
                                segments: segments,
                                isError: msg.isError ?? false
                            )
                            return chatMsg.toStoredInfo(createdAt: dt.addingTimeInterval(Double(idx)))
                        }
                        storage.saveMessages(storedMessages, forSessionId: s.sessionId, serverId: serverId)
                    }
                }
                storage.markUnreadBaselineInitialized(forServerId: serverId)
                serverViewModels[serverId]?.loadCachedSessions()
                serverViewModels[serverId]?.hydrateUnreadStateFromStorage()
            }
            if let projects = srv.projects {
                for proj in projects {
                    if let created = try? projectStore.createProject(
                        name: proj.name,
                        serverId: serverId,
                        initialDirectory: proj.directories.first
                    ) {
                        for extraDir in proj.directories.dropFirst() {
                            try? projectStore.bindDirectory(extraDir, toProjectId: created.id, serverId: serverId)
                        }
                    }
                }
            }
            seededIds.append(serverId)
        }

        if let rawMode = payload.homeDisplayMode, let mode = HomeDisplayMode(rawValue: rawMode) {
            setHomeDisplayMode(mode)
        }
        if let selIdx = payload.selectedServerIndex, selIdx >= 0, selIdx < seededIds.count {
            selectServer(seededIds[selIdx])
        } else if let firstId = seededIds.first {
            selectServer(firstId)
        }
        devModeEnabled = payload.devModeEnabled ?? true
        connectAllServers()
        objectWillChange.send()
    }
}
#endif
