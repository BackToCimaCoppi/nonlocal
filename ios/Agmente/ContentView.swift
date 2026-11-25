import SwiftUI
import ACPClient

struct ContentView: View {
    @Environment(\.colorScheme) private var colorScheme
    @StateObject private var model = AppViewModel()
    @State private var addServerSheet: AddServerSheet?
    @State private var showingSettings = false
    @State private var navigationPath: [NavigationDestination] = []
    @State private var serverToDelete: ACPServerConfiguration?
    @State private var serverToEdit: ACPServerConfiguration?
    @State private var previousServerId: UUID?
    @Environment(\.scenePhase) private var scenePhase

    private var currentVisibleSession: (serverId: UUID, sessionId: String)? {
        guard scenePhase == .active else { return nil }
        if case .session(let serverId, let sid) = navigationPath.last {
            return (serverId, sid)
        }
        return nil
    }

    private var currentVisibleSessionKey: String {
        guard let visible = currentVisibleSession else { return "" }
        return "\(visible.serverId.uuidString)::\(visible.sessionId)"
    }

    private func startupLog(_ message: String) {
        print("[APP][STARTUP] \(message)")
    }

    @ViewBuilder
    private var containerView: some View {
        NavigationStack(path: $navigationPath) {
            rootContent
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .navigationDestination(for: NavigationDestination.self, destination: destinationView)
        }
    }

    var body: some View {
        containerView
        .sheet(item: $addServerSheet, content: addServerSheet)
        .sheet(item: $serverToEdit, content: editServerSheet)
        .sheet(isPresented: $showingSettings, content: settingsSheet)
        .onChange(of: scenePhase) { _, newPhase in
            startupLog("scenePhase changed to \(String(describing: newPhase))")
            model.handleScenePhaseChanged(newPhase)
            if newPhase == .active,
               let activeServer = model.selectedServer,
               model.connectionState(for: activeServer.id) == .connected,
               !model.isConnecting {
                model.resumeConnectionIfNeeded()
            }
        }
        .onChange(of: currentVisibleSessionKey) { _, _ in
            let visible = currentVisibleSession
            model.setActiveViewingSession(serverId: visible?.serverId, sessionId: visible?.sessionId)
        }
        .onChange(of: model.selectedServerId) { oldServerId, newServerId in
            if oldServerId != newServerId {
                previousServerId = oldServerId
            }
            let visible = currentVisibleSession
            model.setActiveViewingSession(serverId: visible?.serverId, sessionId: visible?.sessionId)
        }
        .onAppear {
            startupLog(
                "ContentView.onAppear selectedServerId=\(model.selectedServerId?.uuidString ?? "nil") sessionId=\(model.serverSessionId)"
            )
            // T2 SD-1.9 & T4 SD-2.2: Exact `(serverId, deletedSessionId)` pop without affecting other servers' same-ID sessions.
            model.onSessionDeletedPop = { deletedServerId, deletedSessionId in
                if case .session(let sid, let sessId) = navigationPath.last,
                   sid == deletedServerId, sessId == deletedSessionId {
                    navigationPath.removeLast()
                }
            }
            if model.servers.count >= 2 {
                model.connectAllServers()
            }
            let visible = currentVisibleSession
            model.setActiveViewingSession(serverId: visible?.serverId, sessionId: visible?.sessionId)
        }
        .alert("Delete Server", isPresented: .init(
            get: { serverToDelete != nil },
            set: { if !$0 { serverToDelete = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                serverToDelete = nil
            }
            Button("Delete", role: .destructive) {
                if let server = serverToDelete {
                    model.deleteServer(server.id)
                    serverToDelete = nil
                }
            }
        } message: {
            if let server = serverToDelete {
                Text("Are you sure you want to delete \"\(server.name)\"? This will remove all cached sessions for this server.")
            }
        }
    }
}

private extension ContentView {
    func sessionTitle(for serverId: UUID, sessionId: String) -> String {
        model.serverViewModels[serverId]?.sessionSummaries.first(where: { $0.id == sessionId })?.title
            ?? String(localized: "Session")
    }

    @ViewBuilder
    var rootContent: some View {
        if model.servers.isEmpty {
            SessionPlaceholderView(onAddServer: { addServerSheet = .acp })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
                .background(Color(.systemGroupedBackground))
                .ignoresSafeArea()
        } else {
            HomeSessionListView(
                model: model,
                navigationPath: $navigationPath,
                onEditServer: { serverToEdit = $0 }
            )
        }
    }

    @ViewBuilder
    func destinationView(_ destination: NavigationDestination) -> some View {
        switch destination {
        case .session(let serverId, let sessionId):
            let resolvedId: String = {
                if let svm = model.serverViewModels[serverId] {
                    return svm.effectiveSessionId(for: sessionId)
                }
                return sessionId
            }()
            let title = sessionTitle(for: serverId, sessionId: resolvedId)
            Group {
                if let serverViewModel = model.serverViewModels[serverId] {
                    let sessionViewModel = serverViewModel.sessionViewModel(for: resolvedId)
                    SessionDetailView(
                        model: model,
                        serverViewModel: serverViewModel,
                        sessionViewModel: sessionViewModel
                    )
                } else {
                    ProgressView("Loading session...")
                }
            }
            .navigationTitle(title)
            .id("\(serverId.uuidString)::\(sessionId)")
            .task(id: "\(serverId.uuidString)::\(resolvedId)") {
                if let svm = model.serverViewModels[serverId] {
                    if svm.selectedSessionId != resolvedId || model.activeViewingSessionId != resolvedId {
                        model.openSession(serverId: serverId, sessionId: resolvedId)
                    }
                } else {
                    model.openSession(serverId: serverId, sessionId: resolvedId)
                }
            }
        case .developerLogs:
            DeveloperLogsView(model: model)
        case .folderSessions(let groupKey):
            FolderSessionsView(
                model: model,
                groupKey: groupKey,
                navigationPath: $navigationPath
            )
        }
    }

    func addServerSheet(_ sheet: AddServerSheet) -> some View {
        AddServerView(
            onValidate: { name, scheme, host, token, workingDirectory in
                await model.validateServerConfiguration(
                    name: name,
                    scheme: scheme,
                    host: host,
                    token: token,
                    workingDirectory: workingDirectory
                )
            },
            onInsert: { validated in
                model.addValidatedServer(validated)
            }
        )
    }

    func editServerSheet(_ server: ACPServerConfiguration) -> some View {
        AddServerView(
            editingServer: server,
            connectionState: model.connectionState(for: server.id),
            recentWorkingDirectories: model.usedWorkingDirectoryHistory(for: server.id),
            listDirectory: { params in
                try await model.listRemoteDirectory(
                    serverId: server.id,
                    path: params.path,
                    includeFiles: params.includeFiles ?? false
                )
            },
            onValidate: { name, scheme, host, token, workingDirectory in
                await model.validateServerConfiguration(
                    name: name,
                    scheme: scheme,
                    host: host,
                    token: token,
                    workingDirectory: workingDirectory
                )
            },
            onInsert: { validated in
                model.updateServer(server.id, with: validated)
            }
        )
    }

    func settingsSheet() -> some View {
        SettingsView(devModeEnabled: $model.devModeEnabled)
    }

    @ToolbarContentBuilder
    var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            // T4 SD-2.5 (DEC-25): Clean pure title on iOS; server switching is consolidated in ServerTouchBar.
            let isAllMode = model.effectiveHomeDisplayMode == .allSessions
            Text(isAllMode ? String(localized: "All Sessions") : model.currentServerName)
                .font(.headline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityIdentifier("homeNavigationTitle")
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            let isAllMode = model.effectiveHomeDisplayMode == .allSessions
            Menu {
                Button {
                    addServerSheet = .acp
                } label: {
                    Label("Add Server", systemImage: "plus")
                }
                .accessibilityIdentifier("addACPServerMenuAction")

                Divider()

                Button {
                    showingSettings = true
                } label: {
                    Label("Settings", systemImage: "gear")
                }
                .accessibilityIdentifier("settingsMenuAction")

                Button {
                    Task { await model.refreshServersForCurrentMode() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .accessibilityIdentifier("refreshMenuAction")

                if !isAllMode, let current = model.selectedServer {
                    Divider()

                    Button {
                        model.disconnect(serverId: current.id)
                    } label: {
                        Label("Disconnect", systemImage: "bolt.slash")
                    }
                    .disabled(model.connectionState(for: current.id) == .disconnected)
                    .accessibilityIdentifier("disconnectServerMenuAction")

                    Button {
                        serverToEdit = current
                    } label: {
                        Label("Edit Server", systemImage: "pencil")
                    }
                    .accessibilityIdentifier("editServerMenuAction")

                    Button(role: .destructive) {
                        serverToDelete = current
                    } label: {
                        Label("Delete \"\(current.name)\"", systemImage: "trash")
                    }
                    .accessibilityIdentifier("deleteServerMenuAction")
                }
            } label: {
                Label("More", systemImage: "ellipsis")
            }
            .accessibilityIdentifier("moreMenuButton")
        }
    }
}

private enum AddServerSheet: String, Identifiable {
    case acp

    var id: String { rawValue }
}


enum NavigationDestination: Hashable {
    case session(serverId: UUID, sessionId: String)
    case developerLogs
    case folderSessions(SessionGroupKey)
}


#Preview {
    ContentView()
}
