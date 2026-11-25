import SwiftUI
import ACPClient

struct NewSessionSheet: View {
    @ObservedObject var model: AppViewModel
    let isAllSessionsMode: Bool
    let initialServerId: UUID?
    let preselectedProjectId: UUID?
    @Binding var workingDirectory: String
    let onCancel: () -> Void
    let onCreate: (UUID, String) -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedServerId: UUID?
    @State private var selectedProjectId: UUID?
    @State private var showingDirectoryPicker: Bool = false
    @State private var showingInlineNewProjectAlert: Bool = false
    @State private var inlineProjectName: String = ""
    @State private var inlineProjectError: String?
    @State private var createdInlineProjectIds: [(serverId: UUID, projectId: UUID)] = []

    private var effectiveServerId: UUID? {
        selectedServerId ?? initialServerId ?? model.servers.first?.id
    }

    private var effectiveServer: ACPServerConfiguration? {
        guard let sid = effectiveServerId else { return nil }
        return model.servers.first(where: { $0.id == sid })
    }

    private var usedWorkingDirectories: [String] {
        guard let sid = effectiveServerId else { return [] }
        return model.storage.fetchUsedWorkingDirectories(forServerId: sid)
    }

    private var serverDefaultDirectory: String {
        effectiveServer?.workingDirectory ?? "/"
    }

    private var canBrowseDirectory: Bool {
        guard let sid = effectiveServerId else { return false }
        return model.connectionState(for: sid) == .connected
    }

    private var projectsForCurrentServer: [ServerProject] {
        guard let sid = effectiveServerId else { return [] }
        return model.projectStore.projects(for: sid)
    }

    private func defaultDirectory(for serverId: UUID) -> String {
        let lastUsed = model.storage.fetchUsedWorkingDirectories(forServerId: serverId).first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !lastUsed.isEmpty { return lastUsed }
        let serverDir = model.servers.first(where: { $0.id == serverId })?.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return serverDir.isEmpty ? "/" : serverDir
    }

    private func cleanupEmptyInlineProjects(keeping keepProjectId: UUID? = nil) {
        for entry in createdInlineProjectIds {
            if let keepProjectId, entry.projectId == keepProjectId { continue }
            if let project = model.projectStore.project(id: entry.projectId, forServerId: entry.serverId),
               project.directories.isEmpty {
                model.projectStore.deleteProject(id: entry.projectId, serverId: entry.serverId)
            }
        }
        createdInlineProjectIds.removeAll { entry in
            guard let keepProjectId else { return true }
            return entry.projectId != keepProjectId
        }
    }

    @ViewBuilder
    private var contentForm: some View {
        Form {
            formSections
        }
    }

    @ViewBuilder
    private var formSections: some View {
        if isAllSessionsMode && model.servers.count > 1 {
            Section {
                Picker("Server", selection: Binding<UUID?>(
                    get: { effectiveServerId },
                    set: { newId in
                        guard let newId, newId != selectedServerId else { return }
                        selectedServerId = newId
                        selectedProjectId = nil
                        workingDirectory = defaultDirectory(for: newId)
                    }
                )) {
                    ForEach(model.servers) { server in
                        Text(server.name).tag(Optional(server.id))
                    }
                }
                .accessibilityIdentifier("newSessionServerPicker")
            } header: {
                Text("Server")
            }
        }

        if let sid = effectiveServerId {
            Section {
                Picker("Project", selection: $selectedProjectId) {
                    Text("None").tag(Optional<UUID>.none)
                    ForEach(projectsForCurrentServer) { project in
                        Text(project.name).tag(Optional(project.id))
                    }
                }
                .accessibilityIdentifier("newSessionProjectPicker")
                .onChange(of: selectedProjectId) { _, newProjectId in
                    guard let newProjectId,
                          let project = model.projectStore.project(id: newProjectId, forServerId: sid),
                          let firstDir = project.directories.first, !firstDir.isEmpty else {
                        return
                    }
                    let currentNorm = DirectoryPathNormalizer.normalize(workingDirectory, homePath: model.projectStore.homePath(for: sid))
                    if !project.directories.contains(currentNorm) {
                        workingDirectory = firstDir
                    }
                }

                Button {
                    inlineProjectName = ""
                    inlineProjectError = nil
                    showingInlineNewProjectAlert = true
                } label: {
                    Label("New Project…", systemImage: "folder.badge.plus")
                }
                .accessibilityIdentifier("newSessionInlineNewProjectButton")
            } header: {
                Text("Project (Optional)")
            }
        }

        Section {
            HStack(spacing: 8) {
                TextField("Working directory", text: $workingDirectory)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityIdentifier("NewSessionWorkingDirectoryField")

                if canBrowseDirectory, effectiveServerId != nil {
                    Button("Browse") {
                        showingDirectoryPicker = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("NewSessionBrowseDirectoryButton")
                }
            }
        } header: {
            Text("Working Directory")
        } footer: {
            Text("The directory where the agent will operate for this session.")
        }

        let trimmedCurrent = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let history = usedWorkingDirectories.filter { $0 != trimmedCurrent }
        if !history.isEmpty {
            Section {
                ForEach(history, id: \.self) { directory in
                    Button {
                        workingDirectory = directory
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(directory)
                                .font(.system(.body, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            } header: {
                Text("Previously Used")
            } footer: {
                Text("Tap to fill the working directory.")
            }
        }
    }

    var body: some View {
        NavigationStack {
            contentForm
            .navigationTitle("New Session")
            .onAppear {
                if selectedServerId == nil {
                    selectedServerId = initialServerId ?? model.servers.first?.id
                }
                if selectedProjectId == nil, let preselectedProjectId {
                    selectedProjectId = preselectedProjectId
                }
                if let sid = effectiveServerId,
                   workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if let pid = selectedProjectId,
                       let project = model.projectStore.project(id: pid, forServerId: sid),
                       let firstDir = project.directories.first, !firstDir.isEmpty {
                        workingDirectory = firstDir
                    } else {
                        workingDirectory = defaultDirectory(for: sid)
                    }
                }
            }
            .alert("New Project", isPresented: $showingInlineNewProjectAlert) {
                TextField("Project name", text: $inlineProjectName)
                Button("Create") {
                    guard let sid = effectiveServerId else { return }
                    do {
                        let created = try model.projectStore.createProject(name: inlineProjectName, serverId: sid)
                        createdInlineProjectIds.append((serverId: sid, projectId: created.id))
                        selectedProjectId = created.id
                    } catch {
                        inlineProjectError = error.localizedDescription
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showingDirectoryPicker) {
                if let sid = effectiveServerId {
                    RemoteDirectoryPickerSheet(
                        initialPath: workingDirectory,
                        serverDefaultPath: serverDefaultDirectory,
                        recentDirectories: usedWorkingDirectories,
                        listDirectory: { params in
                            try await model.listRemoteDirectory(
                                serverId: sid,
                                path: params.path,
                                includeFiles: params.includeFiles ?? false
                            )
                        },
                        onSelect: { selectedPath in
                            workingDirectory = selectedPath
                        }
                    )
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        cleanupEmptyInlineProjects()
                        onCancel()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        guard let sid = effectiveServerId else {
                            cleanupEmptyInlineProjects()
                            onCancel()
                            return
                        }
                        let trimmed = workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                        let effectiveDir = trimmed.isEmpty ? serverDefaultDirectory : trimmed
                        if let pid = selectedProjectId, !effectiveDir.isEmpty {
                            try? model.projectStore.bindDirectory(effectiveDir, toProjectId: pid, serverId: sid)
                            cleanupEmptyInlineProjects(keeping: pid)
                        } else {
                            cleanupEmptyInlineProjects()
                        }
                        onCreate(sid, effectiveDir)
                    }
                    .fontWeight(.semibold)
                    .disabled(effectiveServerId == nil)
                    .accessibilityIdentifier("NewSessionCreateButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
