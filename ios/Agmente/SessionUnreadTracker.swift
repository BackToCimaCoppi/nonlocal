import Foundation
import ACPClient

/// Visual activity dot state for each row in the session list and summary counts.
enum SessionRowStatus: String, Equatable, Sendable {
    case running
    case unread
    case read
}

extension SessionSummary {
    /// Shared descending timestamp comparator used across ACP, Codex, and folder groupings.
    static func compareByUpdatedAtDesc(_ lhs: SessionSummary, _ rhs: SessionSummary) -> Bool {
        switch (lhs.updatedAt, rhs.updatedAt) {
        case let (lDate?, rDate?):
            if lDate != rDate { return lDate > rDate }
            return lhs.id < rhs.id
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhs.id < rhs.id
        }
    }
}

/// Manages per-server session unread state, authoritative server updatedAt watermarks,
/// and one-time baseline initialization, shared cleanly across ACP and Codex ViewModels.
@MainActor
final class SessionUnreadTracker {
    private var unreadSessionIds: Set<String> = []
    private var lastSeenServerUpdatedAt: [String: Date] = [:]
    private var latestServerUpdatedAt: [String: Date] = [:]
    private var absorbNextServerIds: Set<String> = []
    private(set) var hasInitializedBaseline: Bool = false

    func hydrate(from storedSessions: [StoredSessionInfo], baselineInitialized: Bool) {
        unreadSessionIds.removeAll()
        lastSeenServerUpdatedAt.removeAll()
        latestServerUpdatedAt.removeAll()
        absorbNextServerIds.removeAll()
        hasInitializedBaseline = baselineInitialized

        for session in storedSessions {
            if session.hasUnread {
                unreadSessionIds.insert(session.sessionId)
            }
            if let seen = session.lastSeenServerUpdatedAt {
                lastSeenServerUpdatedAt[session.sessionId] = seen
                latestServerUpdatedAt[session.sessionId] = seen
            }
            if session.absorbNextServerUpdatedAt {
                absorbNextServerIds.insert(session.sessionId)
            }
        }
    }

    func isUnread(_ sessionId: String) -> Bool {
        unreadSessionIds.contains(sessionId)
    }

    func knownServerUpdatedAt(for sessionId: String) -> Date? {
        lastSeenServerUpdatedAt[sessionId]
    }

    func latestKnownServerUpdatedAt(for sessionId: String) -> Date? {
        latestServerUpdatedAt[sessionId] ?? lastSeenServerUpdatedAt[sessionId]
    }

    func absorbsNextServerUpdate(_ sessionId: String) -> Bool {
        absorbNextServerIds.contains(sessionId)
    }

    /// Returns true if a recovered non-active bridge sync turn should NOT mark unread because its
    /// server activity timestamp is already covered by the user's seen watermark.
    func isCoveredBySeenWatermark(sessionId: String, serverActivityDate: Date?) -> Bool {
        guard let serverActivityDate, let seen = lastSeenServerUpdatedAt[sessionId] else {
            return false
        }
        return serverActivityDate.timeIntervalSince(seen) <= 2.0
    }

    func markUnread(
        _ sessionId: String,
        forServerId serverId: UUID,
        storage: SessionStorage?,
        activeViewingSessionId: String?,
        knownServerUpdatedAt: Date? = nil
    ) {
        guard !sessionId.isEmpty else { return }
        if let knownServerUpdatedAt {
            latestServerUpdatedAt[sessionId] = maxDate(latestServerUpdatedAt[sessionId], knownServerUpdatedAt)
        }
        if sessionId == activeViewingSessionId {
            markRead(
                sessionId,
                knownServerUpdatedAt: knownServerUpdatedAt,
                absorbNextServerTime: knownServerUpdatedAt == nil,
                forServerId: serverId,
                storage: storage
            )
            return
        }

        let needsServerTimeAbsorb = (knownServerUpdatedAt == nil)
        let unreadChanged = unreadSessionIds.insert(sessionId).inserted
        let absorbChanged: Bool
        if needsServerTimeAbsorb {
            absorbChanged = absorbNextServerIds.insert(sessionId).inserted
        } else {
            absorbChanged = absorbNextServerIds.remove(sessionId) != nil
        }
        if unreadChanged || absorbChanged {
            storage?.updateSessionUnreadState(
                sessionId: sessionId,
                forServerId: serverId,
                hasUnread: true,
                lastSeenServerUpdatedAt: nil,
                absorbNextServerUpdatedAt: absorbNextServerIds.contains(sessionId)
            )
        }
    }

    func markRead(
        _ sessionId: String,
        knownServerUpdatedAt: Date? = nil,
        absorbNextServerTime: Bool,
        forServerId serverId: UUID,
        storage: SessionStorage?
    ) {
        guard !sessionId.isEmpty else { return }

        if let knownServerUpdatedAt {
            latestServerUpdatedAt[sessionId] = maxDate(latestServerUpdatedAt[sessionId], knownServerUpdatedAt)
        }
        let targetAbsorb = absorbNextServerTime || absorbNextServerIds.contains(sessionId)
        let targetSeenAt = targetAbsorb ? nil : (knownServerUpdatedAt ?? latestServerUpdatedAt[sessionId])

        let unreadChanged = unreadSessionIds.remove(sessionId) != nil
        var seenChanged = false
        var persistSeenAt: Date?
        if let targetSeenAt {
            let previous = lastSeenServerUpdatedAt[sessionId]
            if previous == nil || targetSeenAt > previous! {
                lastSeenServerUpdatedAt[sessionId] = targetSeenAt
                persistSeenAt = targetSeenAt
                seenChanged = true
            }
        }

        let effectiveAbsorb = targetAbsorb && targetSeenAt == nil
        let absorbChanged: Bool
        if effectiveAbsorb {
            absorbChanged = absorbNextServerIds.insert(sessionId).inserted
        } else {
            absorbChanged = absorbNextServerIds.remove(sessionId) != nil
        }

        if unreadChanged || seenChanged || absorbChanged {
            storage?.updateSessionUnreadState(
                sessionId: sessionId,
                forServerId: serverId,
                hasUnread: false,
                lastSeenServerUpdatedAt: persistSeenAt,
                absorbNextServerUpdatedAt: effectiveAbsorb
            )
        }
    }

    func recordPendingServerTimeAbsorption(
        _ sessionId: String,
        forServerId serverId: UUID,
        storage: SessionStorage?
    ) {
        guard !sessionId.isEmpty else { return }
        let unreadChanged = unreadSessionIds.remove(sessionId) != nil
        let absorbChanged = absorbNextServerIds.insert(sessionId).inserted
        if unreadChanged || absorbChanged {
            storage?.updateSessionUnreadState(
                sessionId: sessionId,
                forServerId: serverId,
                hasUnread: false,
                lastSeenServerUpdatedAt: nil,
                absorbNextServerUpdatedAt: true
            )
        }
    }

    func recordServerUpdatedAt(
        _ serverUpdatedAt: Date,
        for sessionId: String,
        activeViewingSessionId: String?,
        isRunning: Bool,
        serverId: UUID,
        storage: SessionStorage?
    ) {
        guard !sessionId.isEmpty else { return }
        latestServerUpdatedAt[sessionId] = maxDate(latestServerUpdatedAt[sessionId], serverUpdatedAt)
        if absorbNextServerIds.remove(sessionId) != nil {
            let merged = maxDate(lastSeenServerUpdatedAt[sessionId], serverUpdatedAt)
            lastSeenServerUpdatedAt[sessionId] = merged
            storage?.updateSessionUnreadState(
                sessionId: sessionId,
                forServerId: serverId,
                hasUnread: unreadSessionIds.contains(sessionId),
                lastSeenServerUpdatedAt: merged,
                absorbNextServerUpdatedAt: false
            )
            return
        }

        if sessionId == activeViewingSessionId || isRunning {
            let previous = lastSeenServerUpdatedAt[sessionId]
            if previous == nil || serverUpdatedAt > previous! {
                lastSeenServerUpdatedAt[sessionId] = serverUpdatedAt
                storage?.updateSessionUnreadState(
                    sessionId: sessionId,
                    forServerId: serverId,
                    hasUnread: unreadSessionIds.contains(sessionId),
                    lastSeenServerUpdatedAt: serverUpdatedAt,
                    absorbNextServerUpdatedAt: false
                )
            }
            return
        }

        guard hasInitializedBaseline else { return }
        if let previous = lastSeenServerUpdatedAt[sessionId] {
            let delta = serverUpdatedAt.timeIntervalSince(previous)
            if delta > 2.0 {
                unreadSessionIds.insert(sessionId)
                storage?.updateSessionUnreadState(
                    sessionId: sessionId,
                    forServerId: serverId,
                    hasUnread: true,
                    lastSeenServerUpdatedAt: nil,
                    absorbNextServerUpdatedAt: false
                )
            } else if delta > 0 {
                lastSeenServerUpdatedAt[sessionId] = serverUpdatedAt
                storage?.updateSessionUnreadState(
                    sessionId: sessionId,
                    forServerId: serverId,
                    hasUnread: unreadSessionIds.contains(sessionId),
                    lastSeenServerUpdatedAt: serverUpdatedAt,
                    absorbNextServerUpdatedAt: false
                )
            }
        } else {
            unreadSessionIds.insert(sessionId)
            storage?.updateSessionUnreadState(
                sessionId: sessionId,
                forServerId: serverId,
                hasUnread: true,
                lastSeenServerUpdatedAt: nil,
                absorbNextServerUpdatedAt: false
            )
        }
    }

    func reconcileServerList(
        _ summaries: [SessionSummary],
        activeViewingSessionId: String?,
        runningSessionIds: Set<String>,
        ignoredSessionIds: Set<String>,
        pendingSessionIds: Set<String>,
        serverId: UUID,
        storage: SessionStorage?
    ) {
        if !hasInitializedBaseline {
            let reconciledIds = Set(
                summaries.map(\.id).filter { !ignoredSessionIds.contains($0) && !pendingSessionIds.contains($0) }
            )
            let staleUnread = unreadSessionIds
            unreadSessionIds.removeAll()
            absorbNextServerIds.subtract(reconciledIds)

            for sid in staleUnread {
                storage?.updateSessionUnreadState(
                    sessionId: sid,
                    forServerId: serverId,
                    hasUnread: false,
                    lastSeenServerUpdatedAt: nil,
                    absorbNextServerUpdatedAt: absorbNextServerIds.contains(sid)
                )
            }

            for summary in summaries {
                let sid = summary.id
                guard reconciledIds.contains(sid) else { continue }
                let baselineDate = maxDate(lastSeenServerUpdatedAt[sid], summary.updatedAt ?? .distantPast)
                lastSeenServerUpdatedAt[sid] = baselineDate
                latestServerUpdatedAt[sid] = maxDate(latestServerUpdatedAt[sid], baselineDate)
                storage?.updateSessionUnreadState(
                    sessionId: sid,
                    forServerId: serverId,
                    hasUnread: false,
                    lastSeenServerUpdatedAt: baselineDate,
                    absorbNextServerUpdatedAt: false
                )
            }

            hasInitializedBaseline = true
            storage?.markUnreadBaselineInitialized(forServerId: serverId)
            return
        }

        for summary in summaries {
            let sid = summary.id
            guard !ignoredSessionIds.contains(sid), !pendingSessionIds.contains(sid) else { continue }
            if let serverDate = summary.updatedAt {
                latestServerUpdatedAt[sid] = maxDate(latestServerUpdatedAt[sid], serverDate)
            }

            if absorbNextServerIds.remove(sid) != nil {
                let merged = maxDate(lastSeenServerUpdatedAt[sid], summary.updatedAt ?? .distantPast)
                lastSeenServerUpdatedAt[sid] = merged
                storage?.updateSessionUnreadState(
                    sessionId: sid,
                    forServerId: serverId,
                    hasUnread: unreadSessionIds.contains(sid),
                    lastSeenServerUpdatedAt: merged,
                    absorbNextServerUpdatedAt: false
                )
                continue
            }

            if sid == activeViewingSessionId || runningSessionIds.contains(sid) {
                if let serverDate = summary.updatedAt {
                    let previous = lastSeenServerUpdatedAt[sid]
                    if previous == nil || serverDate > previous! {
                        lastSeenServerUpdatedAt[sid] = serverDate
                        storage?.updateSessionUnreadState(
                            sessionId: sid,
                            forServerId: serverId,
                            hasUnread: unreadSessionIds.contains(sid),
                            lastSeenServerUpdatedAt: serverDate,
                            absorbNextServerUpdatedAt: false
                        )
                    }
                } else if lastSeenServerUpdatedAt[sid] == nil {
                    lastSeenServerUpdatedAt[sid] = .distantPast
                    storage?.updateSessionUnreadState(
                        sessionId: sid,
                        forServerId: serverId,
                        hasUnread: unreadSessionIds.contains(sid),
                        lastSeenServerUpdatedAt: .distantPast,
                        absorbNextServerUpdatedAt: false
                    )
                }
                continue
            }

            if let seen = lastSeenServerUpdatedAt[sid] {
                if let serverDate = summary.updatedAt {
                    let delta = serverDate.timeIntervalSince(seen)
                    if delta > 2.0 {
                        if unreadSessionIds.insert(sid).inserted {
                            storage?.updateSessionUnreadState(
                                sessionId: sid,
                                forServerId: serverId,
                                hasUnread: true,
                                lastSeenServerUpdatedAt: nil,
                                absorbNextServerUpdatedAt: false
                            )
                        }
                    } else if delta > 0 {
                        lastSeenServerUpdatedAt[sid] = serverDate
                        storage?.updateSessionUnreadState(
                            sessionId: sid,
                            forServerId: serverId,
                            hasUnread: unreadSessionIds.contains(sid),
                            lastSeenServerUpdatedAt: serverDate,
                            absorbNextServerUpdatedAt: false
                        )
                    }
                }
            } else {
                // New session created remotely after initial baseline was established.
                // Seed nil timestamp with .distantPast so once read it won't repeatedly re-trigger unread.
                let seedAt = summary.updatedAt == nil ? Date.distantPast : nil
                if let seedAt {
                    lastSeenServerUpdatedAt[sid] = seedAt
                }
                unreadSessionIds.insert(sid)
                storage?.updateSessionUnreadState(
                    sessionId: sid,
                    forServerId: serverId,
                    hasUnread: true,
                    lastSeenServerUpdatedAt: seedAt,
                    absorbNextServerUpdatedAt: false
                )
            }
        }
    }

    func migrateSession(
        from placeholderId: String,
        to resolvedId: String,
        serverId: UUID,
        storage: SessionStorage?
    ) {
        guard placeholderId != resolvedId else { return }

        let wasUnread = unreadSessionIds.remove(placeholderId) != nil
        let previousSeen = lastSeenServerUpdatedAt.removeValue(forKey: placeholderId)
        let previousLatest = latestServerUpdatedAt.removeValue(forKey: placeholderId)
        let wasAbsorb = absorbNextServerIds.remove(placeholderId) != nil

        if wasUnread {
            unreadSessionIds.insert(resolvedId)
        }
        if let previousSeen {
            lastSeenServerUpdatedAt[resolvedId] = maxDate(lastSeenServerUpdatedAt[resolvedId], previousSeen)
        }
        if let previousLatest {
            latestServerUpdatedAt[resolvedId] = maxDate(latestServerUpdatedAt[resolvedId], previousLatest)
        }
        if wasAbsorb {
            absorbNextServerIds.insert(resolvedId)
        }

        if wasUnread || previousSeen != nil || wasAbsorb {
            storage?.updateSessionUnreadState(
                sessionId: resolvedId,
                forServerId: serverId,
                hasUnread: unreadSessionIds.contains(resolvedId),
                lastSeenServerUpdatedAt: lastSeenServerUpdatedAt[resolvedId],
                absorbNextServerUpdatedAt: absorbNextServerIds.contains(resolvedId)
            )
        }
    }

    func removeSession(_ sessionId: String) {
        unreadSessionIds.remove(sessionId)
        lastSeenServerUpdatedAt.removeValue(forKey: sessionId)
        latestServerUpdatedAt.removeValue(forKey: sessionId)
        absorbNextServerIds.remove(sessionId)
    }

    func pruneSessions(keeping sessionIds: Set<String>) {
        unreadSessionIds = unreadSessionIds.intersection(sessionIds)
        absorbNextServerIds = absorbNextServerIds.intersection(sessionIds)
        lastSeenServerUpdatedAt = lastSeenServerUpdatedAt.filter { sessionIds.contains($0.key) }
        latestServerUpdatedAt = latestServerUpdatedAt.filter { sessionIds.contains($0.key) }
    }

    private func maxDate(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (l?, r?): return max(l, r)
        case (let l?, nil): return l
        case (nil, let r?): return r
        case (nil, nil): return nil
        }
    }
}
