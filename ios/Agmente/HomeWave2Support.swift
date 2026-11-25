import SwiftUI
import ACPClient

// MARK: - Wave 2: Home Projections, Relative Time, Session Deletion Confirm & Project Directories Sheet

enum SessionRelativeTimeFormatter {
    static func format(_ date: Date?, relativeTo now: Date = Date(), locale: Locale = AppLocalization.effectiveLocale) -> String? {
        guard let date else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// Multi-server session display item carrying explicit `(serverId, serverName)` and `ProjectCardDisplay`.
/// Preserves `summary.id` compatibility while providing composite `stableRowId` to prevent cross-server `ForEach` collisions (W2-AC-207).
struct MultiServerSessionDisplay: Identifiable, Equatable {
    let serverId: UUID
    let serverName: String
    let summary: ACPClientSessionSummary
    let status: SessionRowStatus
    let projectDisplay: ProjectCardDisplay
    let groupDirectoryShortName: String?

    var id: String { "\(serverId.uuidString)::\(summary.id)" }
    var sessionId: String { summary.id }
}

/// Unified project/folder group for both single-server and all-sessions views (T3 SD-3.5 / T4 SD-2.7).
struct SessionProjectGroup: Identifiable, Hashable {
    let key: SessionGroupKey
    let serverId: UUID
    let serverName: String
    let title: String
    let isProject: Bool
    let projectId: UUID?
    let directories: [String]
    let folderPath: String

    var id: String { key.stableId }
}

/// All-sessions time section: pinned "In Progress / Unread" + standard 8 `SessionTimeGroup` buckets.
enum AllSessionsTimeSection: Hashable, Identifiable {
    case activeOrUnread
    case timeGroup(SessionTimeGroup)

    var id: String {
        switch self {
        case .activeOrUnread: return "pinned_active_or_unread"
        case .timeGroup(let g): return "time_\(String(describing: g))"
        }
    }

    var title: String {
        switch self {
        case .activeOrUnread:
            return AppLocalization.localized("In Progress / Unread")
        case .timeGroup(let g):
            return g.localizedTitle()
        }
    }
}

extension SessionTimeGroup {
    func localizedTitle(locale: Locale = AppLocalization.effectiveLocale) -> String {
        switch self {
        case .today: return AppLocalization.localized("Today", locale: locale)
        case .yesterday: return AppLocalization.localized("Yesterday", locale: locale)
        case .thisWeek: return AppLocalization.localized("This week", locale: locale)
        case .lastWeek: return AppLocalization.localized("Last week", locale: locale)
        case .thisMonth: return AppLocalization.localized("This month", locale: locale)
        case .lastMonth: return AppLocalization.localized("Last month", locale: locale)
        case .earlier: return AppLocalization.localized("Earlier", locale: locale)
        case .unknown: return AppLocalization.localized("Unknown", locale: locale)
        }
    }
}

extension SessionListProjection {
    /// Builds the pre-search unassigned directory universe for a server (T3 SD-3.4 / W2-AC-304).
    static func unassignedDirectoryUniverse(
        summaries: [ACPClientSessionSummary],
        usedWorkingDirectories: [String],
        serverDefaultDirectory: String?,
        projects: [ServerProject],
        homePath: String?
    ) -> [String] {
        var assigned = Set<String>()
        for proj in projects {
            for dir in proj.directories {
                let norm = DirectoryPathNormalizer.normalize(dir, homePath: homePath)
                if !norm.isEmpty { assigned.insert(norm) }
            }
        }
        var universe = Set<String>()
        for summary in summaries {
            let eff = ProjectDisplayResolver.resolveEffectivePath(
                cwd: summary.cwd,
                serverDefaultDirectory: serverDefaultDirectory,
                homePath: homePath
            )
            if !eff.isEmpty && !assigned.contains(eff) {
                universe.insert(eff)
            }
        }
        for raw in usedWorkingDirectories {
            let norm = DirectoryPathNormalizer.normalize(raw, homePath: homePath)
            if !norm.isEmpty && !assigned.contains(norm) {
                universe.insert(norm)
            }
        }
        return Array(universe)
    }

    /// Projects multi-server sessions into pinned "In Progress / Unread" (.running first, then updatedAt desc)
    /// plus standard 8 `SessionTimeGroup` buckets for `.read` sessions (T4 SD-2.7 / W2-AC-207).
    static func groupAllSessionsByTime(
        _ items: [MultiServerSessionDisplay],
        calendar: Calendar = .current
    ) -> [(section: AllSessionsTimeSection, sessions: [MultiServerSessionDisplay])] {
        var pinned: [MultiServerSessionDisplay] = []
        var readItems: [MultiServerSessionDisplay] = []

        for item in items {
            switch item.status {
            case .running, .unread:
                pinned.append(item)
            case .read:
                readItems.append(item)
            }
        }

        pinned.sort { lhs, rhs in
            if lhs.status != rhs.status {
                return lhs.status == .running
            }
            return ACPClientSessionSummary.compareByUpdatedAtDesc(lhs.summary, rhs.summary)
        }

        var result: [(section: AllSessionsTimeSection, sessions: [MultiServerSessionDisplay])] = []
        if !pinned.isEmpty {
            result.append((.activeOrUnread, pinned))
        }

        let sortedRead = readItems.sorted { ACPClientSessionSummary.compareByUpdatedAtDesc($0.summary, $1.summary) }
        var buckets: [SessionTimeGroup: [MultiServerSessionDisplay]] = [:]
        for item in sortedRead {
            let g = SessionTimeGroup.group(for: item.summary.updatedAt, calendar: calendar)
            buckets[g, default: []].append(item)
        }
        for g in SessionTimeGroup.displayOrder {
            if let bucket = buckets[g], !bucket.isEmpty {
                result.append((.timeGroup(g), bucket))
            }
        }
        return result
    }

    /// Projects single- or multi-server sessions into `(serverId, SessionGroupKey)` project/folder groups.
    /// Cross-server projects with the same name remain separate groups with `serverId`-prefixed keys (T3 SD-3.5 / T4 SD-2.7).
    static func groupByProject(
        serverInputs: [(
            serverId: UUID,
            serverName: String,
            defaultDirectory: String?,
            homePath: String?,
            projects: [ServerProject],
            unassignedUniverse: [String],
            summaries: [ACPClientSessionSummary],
            statusProvider: (String) -> SessionRowStatus
        )],
        noFolderTitle: String = AppLocalization.localized("No Folder")
    ) -> [(group: SessionProjectGroup, sessions: [MultiServerSessionDisplay], hasMore: Bool)] {
        struct Bucket {
            let group: SessionProjectGroup
            var items: [MultiServerSessionDisplay]
        }

        var buckets: [SessionGroupKey: Bucket] = [:]

        for input in serverInputs {
            for summary in input.summaries {
                let effectivePath = ProjectDisplayResolver.resolveEffectivePath(
                    cwd: summary.cwd,
                    serverDefaultDirectory: input.defaultDirectory,
                    homePath: input.homePath
                )
                let matchedProject = ProjectDisplayResolver.project(
                    forPath: effectivePath,
                    serverId: input.serverId,
                    projects: input.projects,
                    homePath: input.homePath
                )
                let key: SessionGroupKey
                let groupTitle: String
                let isProject: Bool
                let projectId: UUID?
                let directories: [String]
                let folderPath: String

                if let proj = matchedProject {
                    key = .project(serverId: input.serverId, projectId: proj.id)
                    groupTitle = proj.name
                    isProject = true
                    projectId = proj.id
                    directories = proj.directories
                    folderPath = proj.directories.first ?? effectivePath
                } else {
                    key = .folder(serverId: input.serverId, path: effectivePath)
                    groupTitle = ProjectDisplayResolver.groupTitle(
                        for: key,
                        projects: input.projects,
                        homePath: input.homePath,
                        unassignedUniverse: input.unassignedUniverse,
                        noFolderTitle: noFolderTitle
                    )
                    isProject = false
                    projectId = nil
                    directories = effectivePath.isEmpty ? [] : [effectivePath]
                    folderPath = effectivePath
                }

                let cardDisplay = ProjectDisplayResolver.cardDisplayForTimeList(
                    rawPath: summary.cwd,
                    serverDefaultDirectory: input.defaultDirectory,
                    serverId: input.serverId,
                    projects: input.projects,
                    homePath: input.homePath,
                    unassignedUniverse: input.unassignedUniverse
                )
                let groupDirShort = ProjectDisplayResolver.cardDisplayForProjectGroup(
                    rawPath: summary.cwd,
                    serverDefaultDirectory: input.defaultDirectory,
                    groupKey: key,
                    projects: input.projects,
                    homePath: input.homePath
                )

                let display = MultiServerSessionDisplay(
                    serverId: input.serverId,
                    serverName: input.serverName,
                    summary: summary,
                    status: input.statusProvider(summary.id),
                    projectDisplay: cardDisplay,
                    groupDirectoryShortName: groupDirShort
                )

                if var existing = buckets[key] {
                    existing.items.append(display)
                    buckets[key] = existing
                } else {
                    let group = SessionProjectGroup(
                        key: key,
                        serverId: input.serverId,
                        serverName: input.serverName,
                        title: groupTitle,
                        isProject: isProject,
                        projectId: projectId,
                        directories: directories,
                        folderPath: folderPath
                    )
                    buckets[key] = Bucket(group: group, items: [display])
                }
            }
        }

        return buckets.values
            .map { bucket -> (group: SessionProjectGroup, sessions: [MultiServerSessionDisplay], hasMore: Bool, latest: ACPClientSessionSummary?) in
                let sorted = bucket.items.sorted { ACPClientSessionSummary.compareByUpdatedAtDesc($0.summary, $1.summary) }
                let limited = Array(sorted.prefix(maxSessionsPerFolder))
                return (
                    group: bucket.group,
                    sessions: limited,
                    hasMore: sorted.count > maxSessionsPerFolder,
                    latest: sorted.first?.summary
                )
            }
            .sorted { lhs, rhs in
                switch (lhs.latest, rhs.latest) {
                case let (l?, r?):
                    if l.updatedAt != r.updatedAt {
                        switch (l.updatedAt, r.updatedAt) {
                        case let (ld?, rd?): return ld > rd
                        case (_?, nil): return true
                        case (nil, _?): return false
                        case (nil, nil): break
                        }
                    }
                    if lhs.group.id != rhs.group.id {
                        return lhs.group.id < rhs.group.id
                    }
                    return l.id < r.id
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.group.id < rhs.group.id
                }
            }
            .map { (group: $0.group, sessions: $0.sessions, hasMore: $0.hasMore) }
    }

    /// Returns all sessions belonging to a `SessionGroupKey` sorted by `updatedAt` desc (T3 SD-3.5 / W2-AC-305).
    static func sessionsInGroup(
        _ summaries: [ACPClientSessionSummary],
        groupKey: SessionGroupKey,
        serverName: String,
        defaultDirectory: String?,
        homePath: String?,
        projects: [ServerProject],
        unassignedUniverse: [String],
        query: String,
        statusProvider: (String) -> SessionRowStatus
    ) -> [MultiServerSessionDisplay] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matchedProject: ServerProject? = {
            if case .project(_, let pid) = groupKey {
                return projects.first(where: { $0.id == pid })
            }
            return nil
        }()
        let projectDirs: Set<String> = Set(
            (matchedProject?.directories ?? []).map { DirectoryPathNormalizer.normalize($0, homePath: homePath) }
        )

        return summaries
            .filter { summary in
                let eff = ProjectDisplayResolver.resolveEffectivePath(
                    cwd: summary.cwd,
                    serverDefaultDirectory: defaultDirectory,
                    homePath: homePath
                )
                switch groupKey {
                case .project:
                    return !eff.isEmpty && projectDirs.contains(eff)
                case .folder(_, let targetPath):
                    let normTarget = DirectoryPathNormalizer.normalize(targetPath, homePath: homePath)
                    if normTarget.isEmpty {
                        return eff.isEmpty
                    }
                    let belongsToAnyProject = ProjectDisplayResolver.project(
                        forPath: eff,
                        serverId: groupKey.serverId,
                        projects: projects,
                        homePath: homePath
                    ) != nil
                    return !belongsToAnyProject && eff == normTarget
                }
            }
            .filter { summary in
                guard !trimmedQuery.isEmpty else { return true }
                return (summary.title?.lowercased().contains(trimmedQuery) ?? false)
                    || summary.id.lowercased().contains(trimmedQuery)
                    || (summary.cwd?.lowercased().contains(trimmedQuery) ?? false)
            }
            .sorted(by: ACPClientSessionSummary.compareByUpdatedAtDesc)
            .map { summary in
                let cardDisplay = ProjectDisplayResolver.cardDisplayForTimeList(
                    rawPath: summary.cwd,
                    serverDefaultDirectory: defaultDirectory,
                    serverId: groupKey.serverId,
                    projects: projects,
                    homePath: homePath,
                    unassignedUniverse: unassignedUniverse
                )
                let groupDirShort = ProjectDisplayResolver.cardDisplayForProjectGroup(
                    rawPath: summary.cwd,
                    serverDefaultDirectory: defaultDirectory,
                    groupKey: groupKey,
                    projects: projects,
                    homePath: homePath
                )
                return MultiServerSessionDisplay(
                    serverId: groupKey.serverId,
                    serverName: serverName,
                    summary: summary,
                    status: statusProvider(summary.id),
                    projectDisplay: cardDisplay,
                    groupDirectoryShortName: groupDirShort
                )
            }
    }
}

// MARK: - Session Deletion Confirmation Flow (T2 / SD-1.9)

struct SessionDeleteDialogState {
    var pendingServerId: UUID?
    var pendingSessionId: String?
    var pendingTitle: String = ""
    var isLocalOnlyDelete: Bool = false
    var subagentCount: Int?
    var isConfirmPresented: Bool = false
    var isDeleting: Bool = false
    var errorMessage: String?
    var isErrorPresented: Bool = false
}

struct SessionDeleteConfirmModifier: ViewModifier {
    @ObservedObject var model: AppViewModel
    @Binding var state: SessionDeleteDialogState

    func body(content: Content) -> some View {
        content
            .alert(
                state.isLocalOnlyDelete
                    ? Text("Delete Local Session")
                    : Text("Delete Session Permanently"),
                isPresented: $state.isConfirmPresented
            ) {
                Button("Cancel", role: .cancel) {
                    resetPending()
                }
                Button("Delete", role: .destructive) {
                    confirmDelete()
                }
                .accessibilityIdentifier("confirm-delete-session-button")
            } message: {
                if state.isLocalOnlyDelete {
                    Text("Remove this cached session from this device? Remote files will not be affected.")
                } else if let count = state.subagentCount, count > 0 {
                    Text("This will permanently delete this session and \(count) sub-agent session(s) on the host. This cannot be undone.")
                } else {
                    Text("This will permanently delete this session on the host. This cannot be undone.")
                }
            }
            .alert(Text("Unable to Delete Session"), isPresented: $state.isErrorPresented) {
                Button("OK", role: .cancel) {
                    state.errorMessage = nil
                }
            } message: {
                Text(state.errorMessage ?? "")
            }
    }

    private func resetPending() {
        state.pendingServerId = nil
        state.pendingSessionId = nil
        state.subagentCount = nil
        state.isLocalOnlyDelete = false
    }

    private func confirmDelete() {
        guard let serverId = state.pendingServerId,
              let sessionId = state.pendingSessionId else {
            return
        }
        let localOnly = state.isLocalOnlyDelete
        resetPending()

        if localOnly {
            model.applyImmediateSessionDeletion(sessionId: sessionId, serverId: serverId)
            return
        }

        Task { @MainActor in
            state.isDeleting = true
            defer { state.isDeleting = false }
            let result = await model.deleteRemoteSession(sessionId: sessionId, serverId: serverId)
            if case .failure(let err) = result {
                state.errorMessage = err.localizedMessage
                state.isErrorPresented = true
            }
        }
    }
}

@MainActor
func beginSessionDeletionFlow(
    model: AppViewModel,
    serverId: UUID,
    sessionId: String,
    title: String,
    state: Binding<SessionDeleteDialogState>
) {
    guard let serverVM = model.serverViewModels[serverId] else { return }

    // Local unmaterialized draft: remove immediately without confirmation or network (W2-AC-122)
    if serverVM.isPendingSessionId(sessionId) {
        model.applyImmediateSessionDeletion(sessionId: sessionId, serverId: serverId)
        return
    }

    // Active or awaiting-approval session protection (DEC-8 / W2-AC-122)
    if serverVM.isSessionRunning(sessionId) || serverVM.isSessionWaitingForUser(sessionId) {
        state.wrappedValue.errorMessage = RemoteSessionDeleteError.activeSession.localizedMessage
        state.wrappedValue.isErrorPresented = true
        return
    }

    Task { @MainActor in
        let count = await model.fetchSessionInfoForDeleteConfirmation(serverId: serverId, sessionId: sessionId)
        state.wrappedValue.pendingServerId = serverId
        state.wrappedValue.pendingSessionId = sessionId
        state.wrappedValue.pendingTitle = title
        state.wrappedValue.isLocalOnlyDelete = false
        state.wrappedValue.subagentCount = count
        state.wrappedValue.isConfirmPresented = true
    }
}

// MARK: - Project Directories Management Sheet (T3 / SD-3.7)

struct ProjectDirectoriesSheet: View {
    @ObservedObject var model: AppViewModel
    let serverId: UUID
    let projectId: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var showingDirectoryPicker: Bool = false
    @State private var manualPath: String = ""
    @State private var errorMessage: String?

    private var project: ServerProject? {
        model.projectStore.project(id: projectId, forServerId: serverId)
    }

    private var canBrowseRemote: Bool {
        model.connectionState(for: serverId) == .connected
    }

    private var serverDefaultDirectory: String {
        let raw = model.servers.first(where: { $0.id == serverId })?.workingDirectory ?? "~"
        return raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "~" : raw
    }

    var body: some View {
        NavigationStack {
            List {
                if let project {
                    Section {
                        if project.directories.isEmpty {
                            Text("No directories bound to this project.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(project.directories, id: \.self) { dir in
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                    Text(dir)
                                        .font(.system(.footnote, design: .monospaced))
                                        .lineLimit(2)
                                        .truncationMode(.middle)
                                    Spacer()
                                    Button(role: .destructive) {
                                        model.projectStore.unbindDirectory(dir, fromProjectId: projectId, serverId: serverId)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityIdentifier("unbind-directory-button")
                                }
                            }
                        }
                    } header: {
                        Text("Bound Directories")
                    } footer: {
                        Text("Unbinding a directory only updates local project grouping and never deletes sessions or host files.")
                    }

                    Section {
                        HStack(spacing: 8) {
                            TextField("Directory path", text: $manualPath)
#if os(iOS)
                                .textInputAutocapitalization(.never)
#endif
                                .disableAutocorrection(true)
                                .font(.system(.footnote, design: .monospaced))
                                .accessibilityIdentifier("project-add-directory-field")

                            Button("Add") {
                                addDirectory(manualPath)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(manualPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("project-add-directory-button")
                        }

                        if canBrowseRemote {
                            Button {
                                showingDirectoryPicker = true
                            } label: {
                                Label("Browse Remote Directory…", systemImage: "folder.badge.plus")
                            }
                            .accessibilityIdentifier("project-browse-directory-button")
                        }
                    } header: {
                        Text("Add Directory")
                    }
                }
            }
            .navigationTitle(project?.name ?? String(localized: "Manage Directories"))
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("project-directories-done-button")
                }
            }
            .sheet(isPresented: $showingDirectoryPicker) {
                RemoteDirectoryPickerSheet(
                    initialPath: serverDefaultDirectory,
                    serverDefaultPath: serverDefaultDirectory,
                    recentDirectories: model.storage.fetchUsedWorkingDirectories(forServerId: serverId),
                    listDirectory: { params in
                        try await model.listRemoteDirectory(serverId: serverId, path: params.path, includeFiles: params.includeFiles ?? false)
                    },
                    onSelect: { selected in
                        addDirectory(selected)
                    }
                )
            }
            .alert(Text("Error"), isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func addDirectory(_ path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try model.projectStore.bindDirectory(trimmed, toProjectId: projectId, serverId: serverId)
            manualPath = ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
