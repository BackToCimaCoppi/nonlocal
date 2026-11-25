import SwiftUI
import ACPClient

private struct SessionInfoTarget: Identifiable {
    let serverId: UUID
    let summary: ACPClientSessionSummary
    var id: String { "\(serverId.uuidString)::\(summary.id)" }
}

private struct ProjectManageTarget: Identifiable {
    let serverId: UUID
    let projectId: UUID
    var id: String { "\(serverId.uuidString)::\(projectId.uuidString)" }
}

private struct ProjectRenameState {
    var isPresented: Bool = false
    var serverId: UUID?
    var projectId: UUID?
    var draftName: String = ""
    var errorMessage: String?
}

private struct FolderAssignProjectState {
    var isPresented: Bool = false
    var serverId: UUID?
    var folderPath: String = ""
    var newProjectName: String = ""
    var errorMessage: String?
}

struct FileBrowserServerTarget: Identifiable {
    let id: UUID
}

struct HomeSessionListView: View {
    @ObservedObject var model: AppViewModel
    @Binding var navigationPath: [NavigationDestination]
    let onEditServer: (ACPServerConfiguration) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var sessionSearchText: String = ""
    @State private var isSearchFieldPresented: Bool = false
    @State private var showingNewSessionSheet: Bool = false
    @State private var newSessionTargetServerId: UUID?
    @State private var newSessionPreselectedProjectId: UUID?
    @State private var showingDefaultModelSheet: Bool = false
    @State private var fileBrowserTarget: FileBrowserServerTarget? = nil
    @State private var customWorkingDirectory: String = ""
    @State private var renameDialog = SessionRenameDialogState()
    @State private var deleteDialog = SessionDeleteDialogState()
    @State private var sessionInfoTarget: SessionInfoTarget?
    @State private var projectDirsTarget: ProjectManageTarget?
    @State private var projectRenameState = ProjectRenameState()
    @State private var folderAssignState = FolderAssignProjectState()
    @AppStorage("antigravityQuotaCardCollapsed") private var quotaCardCollapsed: Bool = true
    @AppStorage("sessionGroupingMode") private var groupingMode: SessionGroupingMode = .byTime

    private static func formatLastConnected(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = AppLocalization.effectiveLocale
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private func startupLog(_ message: String) {
        print("[APP][STARTUP] \(message)")
    }

    private var isAllSessionsMode: Bool {
        model.effectiveHomeDisplayMode == .allSessions
    }

    private var activeServersForProjection: [ACPServerConfiguration] {
        if isAllSessionsMode {
            return model.servers
        }
        if let selected = model.selectedServer {
            return [selected]
        }
        return []
    }

    private var hasAnySessionsInCurrentMode: Bool {
        activeServersForProjection.contains { server in
            !(model.serverViewModels[server.id]?.sessionSummaries.isEmpty ?? true)
        }
    }

    private func makeMultiServerDisplays(filtered: Bool) -> [MultiServerSessionDisplay] {
        let query = filtered ? sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
        var displays: [MultiServerSessionDisplay] = []

        for server in activeServersForProjection {
            let summaries = model.serverViewModels[server.id]?.sessionSummaries ?? []
            let projects = model.projectStore.projects(for: server.id)
            let homePath = model.projectStore.homePath(for: server.id)
            let usedDirs = model.storage.fetchUsedWorkingDirectories(forServerId: server.id)
            let universe = SessionListProjection.unassignedDirectoryUniverse(
                summaries: summaries,
                usedWorkingDirectories: usedDirs,
                serverDefaultDirectory: server.workingDirectory,
                projects: projects,
                homePath: homePath
            )

            for summary in summaries {
                let cardDisplay = ProjectDisplayResolver.cardDisplayForTimeList(
                    rawPath: summary.cwd,
                    serverDefaultDirectory: server.workingDirectory,
                    serverId: server.id,
                    projects: projects,
                    homePath: homePath,
                    unassignedUniverse: universe
                )
                if !query.isEmpty {
                    let matchTitle = summary.title?.lowercased().contains(query) ?? false
                    let matchId = summary.id.lowercased().contains(query)
                    let matchCwd = summary.cwd?.lowercased().contains(query) ?? false
                    let matchServer = isAllSessionsMode && server.name.lowercased().contains(query)
                    let matchProject: Bool = {
                        switch cardDisplay {
                        case .project(let name, let short):
                            return name.lowercased().contains(query) || (short?.lowercased().contains(query) ?? false)
                        case .unassignedDirectory(let label):
                            return label.lowercased().contains(query)
                        case .none:
                            return false
                        }
                    }()
                    guard matchTitle || matchId || matchCwd || matchServer || matchProject else { continue }
                }

                let status = model.serverViewModels[server.id]?.sessionRowStatus(for: summary.id) ?? .read
                displays.append(
                    MultiServerSessionDisplay(
                        serverId: server.id,
                        serverName: server.name,
                        summary: summary,
                        status: status,
                        projectDisplay: cardDisplay,
                        groupDirectoryShortName: nil
                    )
                )
            }
        }
        return displays
    }

    private var groupedAllSessionsByTime: [(section: AllSessionsTimeSection, sessions: [MultiServerSessionDisplay])] {
        let items = makeMultiServerDisplays(filtered: true)
        if isAllSessionsMode {
            return SessionListProjection.groupAllSessionsByTime(items)
        }
        let sorted = items.sorted { ACPClientSessionSummary.compareByUpdatedAtDesc($0.summary, $1.summary) }
        var buckets: [SessionTimeGroup: [MultiServerSessionDisplay]] = [:]
        for item in sorted {
            let g = SessionTimeGroup.group(for: item.summary.updatedAt)
            buckets[g, default: []].append(item)
        }
        return SessionTimeGroup.displayOrder.compactMap { g in
            guard let bucket = buckets[g], !bucket.isEmpty else { return nil }
            return (.timeGroup(g), bucket)
        }
    }

    private var groupedByProject: [(group: SessionProjectGroup, sessions: [MultiServerSessionDisplay], hasMore: Bool)] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let inputs = activeServersForProjection.map { server -> (
            serverId: UUID,
            serverName: String,
            defaultDirectory: String?,
            homePath: String?,
            projects: [ServerProject],
            unassignedUniverse: [String],
            summaries: [ACPClientSessionSummary],
            statusProvider: (String) -> SessionRowStatus
        ) in
            let allSummaries = model.serverViewModels[server.id]?.sessionSummaries ?? []
            let projects = model.projectStore.projects(for: server.id)
            let homePath = model.projectStore.homePath(for: server.id)
            let usedDirs = model.storage.fetchUsedWorkingDirectories(forServerId: server.id)
            let universe = SessionListProjection.unassignedDirectoryUniverse(
                summaries: allSummaries,
                usedWorkingDirectories: usedDirs,
                serverDefaultDirectory: server.workingDirectory,
                projects: projects,
                homePath: homePath
            )
            let filteredSummaries: [ACPClientSessionSummary] = query.isEmpty ? allSummaries : allSummaries.filter { s in
                let matchBasic = (s.title?.lowercased().contains(query) ?? false)
                    || s.id.lowercased().contains(query)
                    || (s.cwd?.lowercased().contains(query) ?? false)
                    || (isAllSessionsMode && server.name.lowercased().contains(query))
                if matchBasic { return true }
                let eff = ProjectDisplayResolver.resolveEffectivePath(
                    cwd: s.cwd,
                    serverDefaultDirectory: server.workingDirectory,
                    homePath: homePath
                )
                if let proj = ProjectDisplayResolver.project(forPath: eff, serverId: server.id, projects: projects, homePath: homePath) {
                    return proj.name.lowercased().contains(query)
                }
                return false
            }
            return (
                serverId: server.id,
                serverName: server.name,
                defaultDirectory: server.workingDirectory,
                homePath: homePath,
                projects: projects,
                unassignedUniverse: universe,
                summaries: filteredSummaries,
                statusProvider: { sid in model.serverViewModels[server.id]?.sessionRowStatus(for: sid) ?? .read }
            )
        }
        return SessionListProjection.groupByProject(serverInputs: inputs)
    }

    private func navigate(to destination: NavigationDestination) {
        navigationPath.append(destination)
    }

    @ViewBuilder
    private func destinationTrigger<Label: View>(
        _ destination: NavigationDestination,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            navigate(to: destination)
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }

    private func canDeleteSession(serverId: UUID, sessionId: String) -> Bool {
        guard let serverVM = model.serverViewModels[serverId] else {
            return false
        }
        return serverVM.isPendingSessionId(sessionId) || serverVM.hasCompletedNonlocalSync
    }

    @ViewBuilder
    private func sessionDestinationTrigger(
        _ item: MultiServerSessionDisplay,
        showServerBadge: Bool,
        showProjectMeta: Bool,
        groupDirShortName: String? = nil
    ) -> some View {
        let summary = item.summary
        let destination = NavigationDestination.session(serverId: item.serverId, sessionId: summary.id)
        let serverConnected = model.connectionState(for: item.serverId) == .connected
        let allowDelete = canDeleteSession(serverId: item.serverId, sessionId: summary.id)

        destinationTrigger(destination) {
            SessionRow(
                sessionId: summary.id,
                title: summary.title ?? String(localized: "New Chat"),
                lastMessage: model.getLastMessagePreview(for: item.serverId, sessionId: summary.id),
                updatedAt: summary.updatedAt,
                status: item.status,
                serverBadgeName: showServerBadge ? item.serverName : nil,
                projectDisplay: showProjectMeta ? item.projectDisplay : .none,
                groupDirectoryShortName: groupDirShortName
            )
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if allowDelete {
                Button(role: .destructive) {
                    beginSessionDeletionFlow(
                        model: model,
                        serverId: item.serverId,
                        sessionId: summary.id,
                        title: summary.title ?? String(localized: "New Chat"),
                        state: $deleteDialog
                    )
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .accessibilityIdentifier("swipe-delete-\(summary.id)")
            }
        }
        .contextMenu {
            if let serverVM = model.serverViewModels[item.serverId], !serverVM.isPendingSessionId(summary.id) {
                Button {
                    sessionInfoTarget = SessionInfoTarget(serverId: item.serverId, summary: summary)
                } label: {
                    Label("Session Info", systemImage: "info.circle")
                }
                Button {
                    renameDialog.serverId = item.serverId
                    renameDialog.sessionId = summary.id
                    renameDialog.draftTitle = summary.title ?? ""
                    renameDialog.isPresented = true
                } label: {
                    Label("Rename Session", systemImage: "pencil")
                }
                .disabled(!serverConnected || renameDialog.isSubmitting)
            }

            if allowDelete {
                Button(role: .destructive) {
                    beginSessionDeletionFlow(
                        model: model,
                        serverId: item.serverId,
                        sessionId: summary.id,
                        title: summary.title ?? String(localized: "New Chat"),
                        state: $deleteDialog
                    )
                } label: {
                    Label("Delete Session", systemImage: "trash")
                }
            }
        }
    }

    private var searchPlacement: SearchFieldPlacement {
        if #available(iOS 26.0, *) {
            return .toolbar
        } else {
            return .navigationBarDrawer(displayMode: .automatic)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                if !model.protocolIncompatibleServersInCurrentMode.isEmpty {
                    nonBridgeLockoutBanner
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                }

                if !model.preemptedServersInCurrentMode.isEmpty {
                    preemptedReconnectBanner
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 4, trailing: 16))
                }

                if !isAllSessionsMode {
                    summaryCard
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 10, trailing: 16))
                }

                if !hasAnySessionsInCurrentMode {
                    VStack(spacing: 12) {
                        PixelBot()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 28)
                        VStack(spacing: 8) {
                            Text("Start a new session to chat with your agent")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                    }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 16, trailing: 16))
                } else {
                    switch groupingMode {
                    case .byTime:
                        ForEach(groupedAllSessionsByTime, id: \.section) { section, sessions in
                            sessionListSection(title: section.title, sessions: sessions)
                        }
                    case .byFolder:
                        ForEach(groupedByProject, id: \.group.id) { group, sessions, hasMore in
                            projectListSection(group: group, sessions: sessions, hasMore: hasMore)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(.systemGroupedBackground))
            .refreshable {
                await model.refreshServersForCurrentMode()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if model.servers.count >= 2 && !isSearchFieldPresented && sessionSearchText.isEmpty {
                    ServerTouchBar(
                        mode: model.effectiveHomeDisplayMode,
                        items: model.touchBarItems,
                        activeIndex: model.selectedServerIndex,
                        onToggleMode: {
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                                model.toggleHomeDisplayMode()
                            }
                        },
                        onSelectIndex: { idx in
                            guard model.servers.indices.contains(idx) else { return }
                            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                                model.selectServer(model.servers[idx].id)
                            }
                        }
                    )
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }
            }

            if #available(iOS 26.0, *) {
                // Bottom bar hosts search and single "+" new session button
            } else {
                footerActions
            }
        }
        .searchable(
            text: $sessionSearchText,
            isPresented: $isSearchFieldPresented,
            placement: searchPlacement,
            prompt: "Search sessions"
        )
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .modifier(SessionRenameAlertsModifier(model: model, state: $renameDialog))
        .modifier(SessionDeleteConfirmModifier(model: model, state: $deleteDialog))
        .alert("Rename Project", isPresented: $projectRenameState.isPresented) {
            TextField("Project name", text: $projectRenameState.draftName)
                .accessibilityIdentifier("rename-project-text-field")
            Button("Save") {
                if let sid = projectRenameState.serverId, let pid = projectRenameState.projectId {
                    do {
                        try model.projectStore.renameProject(id: pid, to: projectRenameState.draftName, serverId: sid)
                    } catch {
                        projectRenameState.errorMessage = error.localizedDescription
                    }
                }
            }
            .accessibilityIdentifier("rename-project-save-button")
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Project", isPresented: $folderAssignState.isPresented) {
            TextField("Project name", text: $folderAssignState.newProjectName)
                .accessibilityIdentifier("new-project-name-field")
            Button("Create") {
                if let sid = folderAssignState.serverId {
                    do {
                        _ = try model.projectStore.createProject(
                            name: folderAssignState.newProjectName,
                            serverId: sid,
                            initialDirectory: folderAssignState.folderPath
                        )
                    } catch {
                        folderAssignState.errorMessage = error.localizedDescription
                    }
                }
            }
            .accessibilityIdentifier("new-project-create-button")
            Button("Cancel", role: .cancel) {}
        }
        .sheet(item: $projectDirsTarget) { target in
            ProjectDirectoriesSheet(model: model, serverId: target.serverId, projectId: target.projectId)
        }
        .sheet(isPresented: $showingNewSessionSheet) {
            NewSessionSheet(
                model: model,
                isAllSessionsMode: isAllSessionsMode,
                initialServerId: newSessionTargetServerId ?? model.preferredNewSessionServerId ?? model.servers.first?.id,
                preselectedProjectId: newSessionPreselectedProjectId,
                workingDirectory: $customWorkingDirectory,
                onCancel: { showingNewSessionSheet = false },
                onCreate: { targetServerId, directory in
                    showingNewSessionSheet = false
                    if let createdSessionId = model.sendNewSession(serverId: targetServerId, workingDirectory: directory),
                       !createdSessionId.isEmpty {
                        navigate(to: .session(serverId: targetServerId, sessionId: createdSessionId))
                    }
                }
            )
        }
        .toolbar {
            if hasAnySessionsInCurrentMode {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            groupingMode = groupingMode.toggled
                        }
                    } label: {
                        Image(systemName: groupingMode.systemImage)
                    }
                    .accessibilityLabel(groupingMode == .byTime ? "Group by project" : "Group by time")
                    .accessibilityIdentifier("sessionGroupingToggle")
                }
            }

            if #available(iOS 26.0, *) {
                DefaultToolbarItem(kind: .search, placement: .bottomBar)

                ToolbarItem(placement: .bottomBar) {
                    newSessionButton(expanded: true)
                        .padding(.horizontal, 4)
                }
            }
        }
        .sheet(isPresented: $showingDefaultModelSheet) {
            if let serverVM = model.selectedServerViewModel {
                ServerDefaultModelSheet(
                    serverId: serverVM.id,
                    serverName: serverVM.name,
                    serverConfigOptions: serverVM.serverConfigOptionsForModelCatalog(),
                    preferences: serverVM.defaultModelPreferences
                )
            }
        }
        .sheet(item: $sessionInfoTarget) { target in
            SessionInfoSheet(
                model: model,
                sessionId: target.summary.id,
                localTitle: target.summary.title,
                localCwd: target.summary.cwd,
                serverId: target.serverId
            )
        }
        .sheet(item: $fileBrowserTarget) { target in
            let defaultDir = model.normalizedDefaultDirectoryForBrowsing(for: target.id)
            RemoteFileBrowserSheet(
                initialPath: defaultDir,
                projectPath: nil,
                serverDefaultPath: defaultDir,
                listDirectory: { params in
                    try await model.listRemoteDirectory(
                        serverId: target.id,
                        path: params.path,
                        includeFiles: params.includeFiles ?? false
                    )
                },
                readFile: { path in
                    try await model.readRemoteFile(serverId: target.id, path: path)
                },
                mermaidSVGProvider: Self.makeMermaidSVGProvider()
            )
        }
        .onAppear {
            startupLog(
                "HomeSessionListView.onAppear isConnecting=\(model.isConnecting) isInitialAppLaunch=\(model.isInitialAppLaunch)"
            )
            if model.shouldAutoConnectOnSessionListAppear {
                model.connect()
            }
        }
    }

    /// Independent red/warning notice shown when a server fails Nonlocal bridge admission/sync (SD-1.2 / DEC-18).
    /// Always visible regardless of `devModeEnabled` and visually distinct from orange 4001 preemption banner.
    private var nonBridgeLockoutBanner: some View {
        VStack(spacing: 8) {
            ForEach(model.protocolIncompatibleServersInCurrentMode) { server in
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        if isAllSessionsMode {
                            Text(server.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        Text(
                            model.protocolIncompatibleMessage(for: server.id)
                                ?? AppLocalization.localized("This server is not a compatible Nonlocal bridge.")
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 8)

                    Button {
                        onEditServer(server)
                    } label: {
                        Text(AppLocalization.localized("Edit"))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.red))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("nonBridgeEditButton_\(server.id.uuidString)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.red.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.32), lineWidth: 1)
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("nonBridgeLockoutBanner")
    }

    /// Compact top notice shown exclusively when a server connection was preempted by close code 4001 (DEC-1=A).
    /// Hidden completely when online or disconnected normally so normal layouts remain untouched.
    private var preemptedReconnectBanner: some View {
        VStack(spacing: 8) {
            ForEach(model.preemptedServersInCurrentMode) { server in
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        if isAllSessionsMode {
                            Text(server.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                        }
                        Text(AppLocalization.localized("Taken over by another connection"))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 8)

                    Button {
                        model.connectServer(server.id)
                    } label: {
                        Text(AppLocalization.localized("Reconnect"))
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.accentColor))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("preemptedReconnectButton_\(server.id.uuidString)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.orange.opacity(0.12))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.orange.opacity(0.28), lineWidth: 1)
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("preemptedReconnectBanner")
    }

    private static func makeMermaidSVGProvider() -> ((String, Bool) async -> Result<String, Error>)? {
        return { source, isDark in
            let result = await MermaidRenderer.shared.render(source: source, isDark: isDark)
            switch result {
            case .success(let diagram):
                return .success(diagram.svg)
            case .failure(let error):
                return .failure(error)
            }
        }
    }

    private var summaryCard: some View {
        let runningCount = model.runningSessionCount
        let unreadCount = model.unreadSessionCount
        let totalCount = model.serverSessionSummaries.count
        let activeServer = model.selectedServer
        let activeConnectionState = activeServer.map { model.connectionState(for: $0.id) } ?? .disconnected
        let lastConnectedLabel = (activeServer.flatMap { model.lastConnectedAt(for: $0.id) } ?? model.lastConnectedAt)
            .map { Self.formatLastConnected($0) } ?? "—"
        let quotaSnapshot = model.currentQuotaSnapshot

        return VStack(alignment: .leading, spacing: 12) {
                // Header row with Antigravity ACP title and collapse toggle (SD-1.9)
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Antigravity ACP")
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .accessibilityIdentifier("antigravityCardTitle")

                        HStack(spacing: 6) {
                            if let tierName = quotaSnapshot?.tier?.name, !tierName.isEmpty {
                                Text(tierName)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                                    .foregroundStyle(Color.accentColor)
                                    .lineLimit(1)
                            }
                            if let serverName = model.selectedServer?.name, !serverName.isEmpty {
                                Text(serverName)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .accessibilityIdentifier("antigravityTierRow")
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        if activeConnectionState == .connected, let activeServer {
                            Button {
                                fileBrowserTarget = FileBrowserServerTarget(id: activeServer.id)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "folder")
                                        .font(.caption2.weight(.semibold))
                                    Text("Files")
                                        .font(.caption.weight(.semibold))
                                }
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color(.systemGray5).opacity(0.75)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("serverCardFilesButton")
                        }

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                quotaCardCollapsed.toggle()
                            }
                        } label: {
                            Image(systemName: quotaCardCollapsed ? "chevron.down" : "chevron.up")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .frame(width: 28, height: 28)
                                .background(Color(.systemGray5).opacity(0.6))
                                .clipShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("quotaCollapseToggleButton")
                    }
                }

                QuotaUsageCardView(
                    snapshot: quotaSnapshot,
                    isCollapsed: quotaCardCollapsed,
                    now: Date()
                )

                // 3-state activity dots (always visible; zero "active"/"idle" text per T7 #衔接点-a)
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(SessionRowStatus.running.dotColor)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text("\(runningCount)")
                            .font(.caption.weight(.medium))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("summaryRunningCount")
                    .accessibilityLabel("Running sessions")
                    .accessibilityValue("\(runningCount)")

                    HStack(spacing: 6) {
                        Circle()
                            .fill(SessionRowStatus.unread.dotColor)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text("\(unreadCount)")
                            .font(.caption.weight(.medium))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("summaryUnreadCount")
                    .accessibilityLabel("Waiting sessions")
                    .accessibilityValue("\(unreadCount)")

                    HStack(spacing: 6) {
                        Circle()
                            .fill(SessionRowStatus.read.dotColor)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text("\(totalCount)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("summaryTotalCount")
                    .accessibilityLabel("Total sessions")
                    .accessibilityValue("\(totalCount)")

                    Spacer()

                    HStack(spacing: 10) {
                        if let updatedLabel = QuotaUsageFormatter.formatUpdatedAt(fetchedAt: quotaSnapshot?.fetchedAt, now: Date()) {
                            Text(updatedLabel)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityIdentifier("quotaUpdatedAtLabel")
                        }

                        Button {
                            showingDefaultModelSheet = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 24)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("serverDefaultModelButton")
                        .accessibilityLabel("Default Model Settings")
                    }
                }

                // Dev mode status (always visible when enabled; hosts Logs for Antigravity card)
                if model.devModeEnabled {
                    HStack(alignment: .center, spacing: 8) {
                        HStack(spacing: 2) {
                            Image(systemName: activeConnectionState == .connected ? "bolt.fill" : "bolt.slash.fill")
                                .font(.caption2)
                            Text(model.currentStateLabel)
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }

                        Text(lastConnectedLabel)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer(minLength: 4)

                        Button {
                            navigate(to: .developerLogs)
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "doc.text")
                                    .font(.caption2)
                                Text("Logs")
                                    .font(.caption.weight(.medium))
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("devRowLogsButton")
                    }
                    .foregroundStyle(activeConnectionState == .connected ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.orange))
                }
            }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
        .modifier(SessionCardStyle())
    }

    private func newSessionButton(expanded: Bool) -> some View {
        Group {
            if #available(iOS 26.0, *) {
                newSessionButtonModern(expanded: expanded)
            } else {
                newSessionButtonLegacy(expanded: expanded)
            }
        }
    }

    private var newSessionButtonTint: Color {
        colorScheme == .dark
            ? Color(red: 0.12, green: 0.13, blue: 0.18)
            : .black
    }

    private var newSessionButtonForeground: Color {
        .white
    }

    private var newSessionControlHeight: CGFloat { 50 }

    private var newSessionChevronWidth: CGFloat { 50 }

    private var newSessionButtonSpacing: CGFloat { 0 }

    private func presentNewSessionSheet(preselectedServerId: UUID? = nil, preselectedProjectId: UUID? = nil) {
        let targetId = preselectedServerId
            ?? (isAllSessionsMode ? model.preferredNewSessionServerId : model.selectedServer?.id)
            ?? model.servers.first?.id
        newSessionTargetServerId = targetId
        newSessionPreselectedProjectId = preselectedProjectId
        customWorkingDirectory = NewSessionDefaults.resolveWorkingDirectory(
            preselectedServerId: targetId,
            servers: model.servers
        )
        showingNewSessionSheet = true
    }

    @available(iOS 26.0, *)
    private func newSessionButtonModern(expanded: Bool) -> some View {
        Button {
            presentNewSessionSheet()
        } label: {
            Label {
                Text("New Session")
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } icon: {
                Image(systemName: "plus")
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: expanded ? .infinity : nil)
            .frame(height: newSessionControlHeight)
        }
        .buttonStyle(.borderedProminent)
        .tint(newSessionButtonTint)
        .foregroundStyle(newSessionButtonForeground)
        .controlSize(.large)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .disabled(model.servers.isEmpty)
        .accessibilityIdentifier("newSessionButton")
    }

    private func newSessionButtonLegacy(expanded: Bool) -> some View {
        Button {
            presentNewSessionSheet()
        } label: {
            Label("New Session", systemImage: "plus")
                .font(.body.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: expanded ? .infinity : nil)
                .frame(height: newSessionControlHeight)
        }
        .buttonStyle(.borderedProminent)
        .tint(newSessionButtonTint)
        .foregroundStyle(newSessionButtonForeground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .disabled(model.servers.isEmpty)
        .accessibilityIdentifier("newSessionButton")
    }

    private var footerActions: some View {
        HStack {
            newSessionButton(expanded: true)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 6)
    }

    private func filterSessions(_ sessions: [SessionSummary]) -> [SessionSummary] {
        let query = sessionSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sessions }
        let lower = query.lowercased()
        return sessions.filter {
            ($0.title?.lowercased().contains(lower) ?? false) || $0.id.lowercased().contains(lower)
        }
    }

    @ViewBuilder
    private func sessionListSection(title: String, sessions: [MultiServerSessionDisplay]) -> some View {
        Section {
            ForEach(sessions, id: \.id) { item in
                sessionDestinationTrigger(
                    item,
                    showServerBadge: isAllSessionsMode,
                    showProjectMeta: true
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            }
        } header: {
            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }

    @ViewBuilder
    private func projectListSection(
        group: SessionProjectGroup,
        sessions: [MultiServerSessionDisplay],
        hasMore: Bool
    ) -> some View {
        let serverProjects = model.projectStore.projects(for: group.serverId)
        let recentDirs = model.storage.fetchUsedWorkingDirectories(forServerId: group.serverId)
        let sortedProjectDirs: [String] = {
            if let pid = group.projectId, let proj = model.projectStore.project(id: pid, forServerId: group.serverId) {
                return model.projectStore.sortedDirectories(for: proj, recentDirectories: recentDirs)
            }
            return group.directories
        }()

        Section {
            ForEach(sessions, id: \.id) { item in
                sessionDestinationTrigger(
                    item,
                    showServerBadge: false,
                    showProjectMeta: false,
                    groupDirShortName: item.groupDirectoryShortName
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            }

            if hasMore {
                destinationTrigger(.folderSessions(group.key)) {
                    HStack {
                        Text("Show More Sessions")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(SessionCardStyle())
                }
                .accessibilityIdentifier("showMoreFolder_\(group.id)")
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
            }
        } header: {
            FolderHeaderCard(
                displayName: group.title,
                path: group.folderPath,
                isProject: group.isProject,
                serverBadgeName: isAllSessionsMode ? group.serverName : nil,
                multiDirectories: (group.isProject && sortedProjectDirs.count > 1) ? sortedProjectDirs : [],
                availableProjectsForAssign: (!group.isProject && !group.folderPath.isEmpty) ? serverProjects : [],
                onAddSessionInDirectory: { dir in
                    let targetDir = dir.isEmpty ? nil : dir
                    if let createdId = model.sendNewSession(serverId: group.serverId, workingDirectory: targetDir),
                       !createdId.isEmpty {
                        navigate(to: .session(serverId: group.serverId, sessionId: createdId))
                    }
                },
                onChooseOtherDirectory: {
                    presentNewSessionSheet(preselectedServerId: group.serverId, preselectedProjectId: group.projectId)
                },
                onRenameProject: group.projectId.map { pid in
                    {
                        projectRenameState.serverId = group.serverId
                        projectRenameState.projectId = pid
                        projectRenameState.draftName = group.title
                        projectRenameState.isPresented = true
                    }
                },
                onManageDirectories: group.projectId.map { pid in
                    {
                        projectDirsTarget = ProjectManageTarget(serverId: group.serverId, projectId: pid)
                    }
                },
                onDeleteProject: group.projectId.map { pid in
                    {
                        model.projectStore.deleteProject(id: pid, serverId: group.serverId)
                    }
                },
                onAssignToProject: (!group.isProject && !group.folderPath.isEmpty) ? { targetProjectId in
                    try? model.projectStore.bindDirectory(group.folderPath, toProjectId: targetProjectId, serverId: group.serverId)
                } : nil,
                onCreateProjectAndAssign: (!group.isProject && !group.folderPath.isEmpty) ? {
                    folderAssignState.serverId = group.serverId
                    folderAssignState.folderPath = group.folderPath
                    folderAssignState.newProjectName = ""
                    folderAssignState.isPresented = true
                } : nil
            )
            .textCase(nil)
        }
    }
}


private enum SessionGroupingMode: String, CaseIterable {
    case byTime
    case byFolder

    var label: String {
        switch self {
        case .byTime: return "Time"
        case .byFolder: return "Folder"
        }
    }

    var systemImage: String {
        switch self {
        case .byTime: return "clock"
        case .byFolder: return "folder"
        }
    }

    var toggled: SessionGroupingMode {
        switch self {
        case .byTime: return .byFolder
        case .byFolder: return .byTime
        }
    }
}


private struct FolderHeaderCard: View {
    let displayName: String
    let path: String
    var isProject: Bool = false
    var serverBadgeName: String? = nil
    var multiDirectories: [String] = []
    var availableProjectsForAssign: [ServerProject] = []
    var onAddSessionInDirectory: ((String) -> Void)? = nil
    var onChooseOtherDirectory: (() -> Void)? = nil
    var onRenameProject: (() -> Void)? = nil
    var onManageDirectories: (() -> Void)? = nil
    var onDeleteProject: (() -> Void)? = nil
    var onAssignToProject: ((UUID) -> Void)? = nil
    var onCreateProjectAndAssign: (() -> Void)? = nil

    private var hasManageMenu: Bool {
        onRenameProject != nil || onManageDirectories != nil || onDeleteProject != nil || onCreateProjectAndAssign != nil
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isProject ? "folder.fill" : "folder")
                .foregroundStyle(isProject ? Color.accentColor : Color.secondary)
            Text(displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isProject ? .primary : .secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            if let serverBadgeName, !serverBadgeName.isEmpty {
                Text(serverBadgeName)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color(.tertiarySystemFill)))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }

            Spacer(minLength: 6)

            if hasManageMenu {
                Menu {
                    if let onRenameProject {
                        Button(action: onRenameProject) {
                            Label("Rename Project", systemImage: "pencil")
                        }
                    }
                    if let onManageDirectories {
                        Button(action: onManageDirectories) {
                            Label("Manage Directories", systemImage: "folder.badge.gearshape")
                        }
                    }
                    if let onDeleteProject {
                        Divider()
                        Button(role: .destructive, action: onDeleteProject) {
                            Label("Delete Project", systemImage: "trash")
                        }
                    }
                    if let onAssignToProject, !availableProjectsForAssign.isEmpty {
                        Menu("Assign to Project") {
                            ForEach(availableProjectsForAssign) { proj in
                                Button(proj.name) {
                                    onAssignToProject(proj.id)
                                }
                            }
                        }
                    }
                    if let onCreateProjectAndAssign {
                        Button(action: onCreateProjectAndAssign) {
                            Label("New Project & Assign…", systemImage: "folder.badge.plus")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 24)
                }
                .accessibilityIdentifier("folderMenu_\(displayName)")
            }

            if !multiDirectories.isEmpty, let onAddSessionInDirectory {
                Menu {
                    ForEach(multiDirectories, id: \.self) { dir in
                        Button {
                            onAddSessionInDirectory(dir)
                        } label: {
                            Label((dir as NSString).lastPathComponent.isEmpty ? dir : (dir as NSString).lastPathComponent, systemImage: "folder")
                        }
                    }
                    if let onChooseOtherDirectory {
                        Divider()
                        Button(action: onChooseOtherDirectory) {
                            Label("Choose Another Directory…", systemImage: "ellipsis.circle")
                        }
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("newSessionInProject_\(displayName)")
            } else if let onAddSessionInDirectory {
                Button {
                    onAddSessionInDirectory(path)
                } label: {
                    Image(systemName: "plus")
                        .font(.footnote.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(path.isEmpty ? "Start new session in default folder" : "Start new session in \(displayName)")
                .accessibilityIdentifier(path.isEmpty ? "newSessionInFolder_default" : "newSessionInFolder_\(path)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SessionRow: View {
    let sessionId: String
    let title: String
    let lastMessage: String?
    var updatedAt: Date? = nil
    let status: SessionRowStatus
    var serverBadgeName: String? = nil
    var projectDisplay: ProjectCardDisplay = .none
    var groupDirectoryShortName: String? = nil
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(status.dotColor)
                .frame(width: 8, height: 8)
                .padding(.top, 6)
                .accessibilityIdentifier("sessionRow_\(sessionId)")
                .accessibilityLabel(status.accessibilityLabelText)
                .accessibilityValue(status.rawValue)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    Spacer(minLength: 4)

                    if let relTime = SessionRelativeTimeFormatter.format(updatedAt) {
                        Text(relTime)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .layoutPriority(1)
                    }
                }

                if let preview = lastMessage, !preview.isEmpty {
                    Text(preview)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if hasMetaRow {
                    HStack(spacing: 6) {
                        if let serverBadgeName, !serverBadgeName.isEmpty {
                            Text(serverBadgeName)
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color(.tertiarySystemFill)))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(1)
                        }

                        if let groupDir = groupDirectoryShortName, !groupDir.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "folder")
                                    .font(.caption2)
                                Text(groupDir)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .foregroundStyle(.tertiary)
                        } else {
                            switch projectDisplay {
                            case .project(let name, let dirShort):
                                HStack(spacing: 4) {
                                    HStack(spacing: 3) {
                                        Image(systemName: "folder.fill")
                                            .font(.caption2)
                                            .foregroundStyle(Color.accentColor)
                                        Text(name)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                    }
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(.secondarySystemFill)))

                                    if let dirShort, !dirShort.isEmpty {
                                        Text("/ \(dirShort)")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            case .unassignedDirectory(let label):
                                HStack(spacing: 3) {
                                    Image(systemName: "folder")
                                        .font(.caption2)
                                    Text(label)
                                        .font(.caption2)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                .foregroundStyle(.tertiary)
                            case .none:
                                EmptyView()
                            }
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SessionCardStyle())
    }

    private var hasMetaRow: Bool {
        if let s = serverBadgeName, !s.isEmpty { return true }
        if let d = groupDirectoryShortName, !d.isEmpty { return true }
        if case .none = projectDisplay { return false }
        return true
    }
}


struct DeveloperLogsView: View {
    @ObservedObject var model: AppViewModel
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if model.updates.isEmpty {
                    ContentUnavailableView(
                        "No Logs",
                        systemImage: "doc.plaintext",
                        description: Text("Requests and responses will appear here while you interact with the agent.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(model.updates) { update in
                            DeveloperLogRow(log: update)
                                .id(update.id)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
            }
            .background(Color(.systemGroupedBackground))
            .onChange(of: model.updates) { _, newValue in
                guard let last = newValue.last else { return }
                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if let last = model.updates.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
        .navigationTitle("Server Logs")
        .navigationBarTitleDisplayMode(.inline)
        .background(Color(.systemGroupedBackground))
    }
}

private struct DeveloperLogRow: View {
    let log: LogLine
    @State private var isExpanded = false
    @Environment(\.colorScheme) private var colorScheme

    private var expandedDetails: String? {
        log.prettyDetails ?? log.details
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            if let details = expandedDetails {
                ScrollView([.vertical, .horizontal], showsIndicators: true) {
                    Text(details)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } else {
                Text(log.message)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(log.title.isEmpty ? "Log Entry" : log.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    if let details = log.details {
                        Text(details)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                Spacer(minLength: 8)

                Text(log.timestampLabel)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(colorScheme == .dark ? Color(.secondarySystemBackground) : Color.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color(.systemGray5).opacity(colorScheme == .dark ? 0.4 : 1), lineWidth: colorScheme == .dark ? 0.5 : 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0 : 0.04), radius: 8, y: 4)
    }
}

struct FolderSessionsView: View {
    @ObservedObject var model: AppViewModel
    let groupKey: SessionGroupKey
    @Binding var navigationPath: [NavigationDestination]
    @State private var searchText: String = ""
    @State private var renameDialog = SessionRenameDialogState()
    @State private var deleteDialog = SessionDeleteDialogState()
    @State private var sessionInfoTarget: SessionInfoTarget?
    @Environment(\.openWindow) private var openWindow

    private var serverConfig: ACPServerConfiguration? {
        model.servers.first(where: { $0.id == groupKey.serverId })
    }

    private var resolvedTitle: String {
        let projects = model.projectStore.projects(for: groupKey.serverId)
        let homePath = model.projectStore.homePath(for: groupKey.serverId)
        let summaries = model.serverViewModels[groupKey.serverId]?.sessionSummaries ?? []
        let usedDirs = model.storage.fetchUsedWorkingDirectories(forServerId: groupKey.serverId)
        let universe = SessionListProjection.unassignedDirectoryUniverse(
            summaries: summaries,
            usedWorkingDirectories: usedDirs,
            serverDefaultDirectory: serverConfig?.workingDirectory,
            projects: projects,
            homePath: homePath
        )
        return ProjectDisplayResolver.groupTitle(
            for: groupKey,
            projects: projects,
            homePath: homePath,
            unassignedUniverse: universe,
            noFolderTitle: AppLocalization.localized("No Folder")
        )
    }

    private var sessionsInGroup: [MultiServerSessionDisplay] {
        let summaries = model.serverViewModels[groupKey.serverId]?.sessionSummaries ?? []
        let projects = model.projectStore.projects(for: groupKey.serverId)
        let homePath = model.projectStore.homePath(for: groupKey.serverId)
        let usedDirs = model.storage.fetchUsedWorkingDirectories(forServerId: groupKey.serverId)
        let universe = SessionListProjection.unassignedDirectoryUniverse(
            summaries: summaries,
            usedWorkingDirectories: usedDirs,
            serverDefaultDirectory: serverConfig?.workingDirectory,
            projects: projects,
            homePath: homePath
        )
        return SessionListProjection.sessionsInGroup(
            summaries,
            groupKey: groupKey,
            serverName: serverConfig?.name ?? "",
            defaultDirectory: serverConfig?.workingDirectory,
            homePath: homePath,
            projects: projects,
            unassignedUniverse: universe,
            query: searchText,
            statusProvider: { sid in model.serverViewModels[groupKey.serverId]?.sessionRowStatus(for: sid) ?? .read }
        )
    }

    private var groupedSessionsInFolder: [(group: SessionTimeGroup, sessions: [MultiServerSessionDisplay])] {
        var buckets: [SessionTimeGroup: [MultiServerSessionDisplay]] = [:]
        for item in sessionsInGroup {
            let g = SessionTimeGroup.group(for: item.summary.updatedAt)
            buckets[g, default: []].append(item)
        }
        return SessionTimeGroup.displayOrder.compactMap { g in
            guard let list = buckets[g], !list.isEmpty else { return nil }
            return (g, list)
        }
    }

    private func navigate(to destination: NavigationDestination) {
        navigationPath.append(destination)
    }

    @ViewBuilder
    private func destinationTrigger<Label: View>(
        _ destination: NavigationDestination,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button {
            navigate(to: destination)
        } label: {
            label()
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        List {
            let grouped = groupedSessionsInFolder
            if grouped.isEmpty {
                ContentUnavailableView(
                    "No Sessions",
                    systemImage: "tray",
                    description: Text("No sessions found in this folder.")
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                ForEach(grouped, id: \.group) { entry in
                    Section {
                        ForEach(entry.sessions, id: \.id) { item in
                            folderSessionRow(item)
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 5, leading: 16, bottom: 5, trailing: 16))
                        }
                    } header: {
                        Text(entry.group.localizedTitle())
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(resolvedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search sessions")
        .textInputAutocapitalization(.never)
        .disableAutocorrection(true)
        .modifier(SessionRenameAlertsModifier(model: model, state: $renameDialog))
        .modifier(SessionDeleteConfirmModifier(model: model, state: $deleteDialog))
        .sheet(item: $sessionInfoTarget) { target in
            SessionInfoSheet(
                model: model,
                sessionId: target.summary.id,
                localTitle: target.summary.title,
                localCwd: target.summary.cwd,
                serverId: target.serverId
            )
        }
    }

    private func folderSessionRow(_ item: MultiServerSessionDisplay) -> some View {
        let summary = item.summary
        let serverConnected = model.connectionState(for: item.serverId) == .connected
        let allowDelete: Bool = {
            guard let svm = model.serverViewModels[item.serverId] else { return false }
            return svm.isPendingSessionId(summary.id) || svm.hasCompletedNonlocalSync
        }()

        return destinationTrigger(.session(serverId: item.serverId, sessionId: summary.id)) {
            SessionRow(
                sessionId: summary.id,
                title: summary.title ?? String(localized: "New Chat"),
                lastMessage: model.getLastMessagePreview(for: item.serverId, sessionId: summary.id),
                updatedAt: summary.updatedAt,
                status: item.status,
                serverBadgeName: nil,
                projectDisplay: .none,
                groupDirectoryShortName: item.groupDirectoryShortName
            )
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if allowDelete {
                Button(role: .destructive) {
                    beginSessionDeletionFlow(
                        model: model,
                        serverId: item.serverId,
                        sessionId: summary.id,
                        title: summary.title ?? String(localized: "New Chat"),
                        state: $deleteDialog
                    )
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        .contextMenu {
            if let svm = model.serverViewModels[item.serverId], !svm.isPendingSessionId(summary.id) {
                Button {
                    sessionInfoTarget = SessionInfoTarget(serverId: item.serverId, summary: summary)
                } label: {
                    Label("Session Info", systemImage: "info.circle")
                }
                Button {
                    renameDialog.serverId = item.serverId
                    renameDialog.sessionId = summary.id
                    renameDialog.draftTitle = summary.title ?? ""
                    renameDialog.isPresented = true
                } label: {
                    Label("Rename Session", systemImage: "pencil")
                }
                .disabled(!serverConnected || renameDialog.isSubmitting)
            }
            if allowDelete {
                Button(role: .destructive) {
                    beginSessionDeletionFlow(
                        model: model,
                        serverId: item.serverId,
                        sessionId: summary.id,
                        title: summary.title ?? String(localized: "New Chat"),
                        state: $deleteDialog
                    )
                } label: {
                    Label("Delete Session", systemImage: "trash")
                }
            }
        }
    }
}

private struct SessionRenameDialogState {
    var isPresented: Bool = false
    var serverId: UUID? = nil
    var sessionId: String = ""
    var draftTitle: String = ""
    var isSubmitting: Bool = false
    var showError: Bool = false
    var errorMessage: String = ""
}

private struct SessionRenameAlertsModifier: ViewModifier {
    @ObservedObject var model: AppViewModel
    @Binding var state: SessionRenameDialogState

    func body(content: Content) -> some View {
        content
            .alert("Rename Session", isPresented: $state.isPresented) {
                TextField("New title (leave empty for automatic title)", text: $state.draftTitle)
                    .accessibilityIdentifier("rename-session-text-field")
                Button("Save") {
                    guard let targetServerId = state.serverId else { return }
                    let targetId = state.sessionId
                    let draft = state.draftTitle
                    Task { @MainActor in
                        state.isSubmitting = true
                        defer { state.isSubmitting = false }
                        do {
                            _ = try await model.renameSession(serverId: targetServerId, sessionId: targetId, title: draft)
                        } catch {
                            state.errorMessage = error.localizedDescription
                            state.showError = true
                        }
                    }
                }
                .accessibilityIdentifier("rename-session-save-button")
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Update the display title for this session.")
            }
            .alert("Rename Failed", isPresented: $state.showError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(state.errorMessage)
            }
    }
}
