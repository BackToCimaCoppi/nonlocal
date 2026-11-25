import SwiftUI
import UIKit
import ACPClient

/// Pure server-bound adapter for `WorkingDirectoryPickerSheet` (SD-2.8 / SC-AC-048).
/// Strictly anchors every read and mutation to `serverViewModel` / `serverViewModel.id`,
/// never touching `AppViewModel.selectedServerId` or global selected-server accessors.
@MainActor
struct WorkingDirectoryPickerBinding {
    let model: AppViewModel
    let serverViewModel: ServerViewModel

    var serverId: UUID { serverViewModel.id }
    var sessionId: String { serverViewModel.sessionId }
    var isPendingSession: Bool { serverViewModel.isPendingSession }
    var connectionState: ACPConnectionState { serverViewModel.connectionState }
    var serverDefaultCwd: String { serverViewModel.workingDirectory }

    var currentSessionCwd: String {
        model.currentSessionCwd(for: serverViewModel.id, sessionId: serverViewModel.sessionId)
    }

    var usedWorkingDirectoryHistory: [String] {
        model.usedWorkingDirectoryHistory(for: serverViewModel.id, currentSessionCwd: currentSessionCwd)
    }

    var serverDefaultPathForBrowsing: String {
        model.normalizedDefaultDirectoryForBrowsing(for: serverViewModel.id)
    }

    func listRemoteDirectory(_ params: NonlocalFsListParams) async throws -> NonlocalFsListResult? {
        try await model.listRemoteDirectory(
            serverId: serverViewModel.id,
            path: params.path,
            includeFiles: params.includeFiles ?? false
        )
    }

    func updatePendingWorkingDirectory(_ newValue: String) {
        model.updatePendingSessionWorkingDirectory(serverId: serverViewModel.id, newValue)
    }
}

struct WorkingDirectoryPickerSheet: View {
    @ObservedObject var model: AppViewModel
    @ObservedObject var serverViewModel: ServerViewModel
    @Binding var isPresented: Bool
    @State private var pendingWorkingDirectory: String = ""
    @State private var showingDirectoryPicker: Bool = false

    private var binding: WorkingDirectoryPickerBinding {
        WorkingDirectoryPickerBinding(model: model, serverViewModel: serverViewModel)
    }

    var body: some View {
        NavigationStack {
            let currentCwd = binding.currentSessionCwd
            let defaultCwd = binding.serverDefaultCwd
            let isPending = binding.isPendingSession
            let isConnected = binding.connectionState == .connected

            List {
                // Current session's working directory
                Section {
                    if isPending {
                        HStack(spacing: 8) {
                            TextField("Working directory", text: $pendingWorkingDirectory)
                                .textInputAutocapitalization(.never)
                                .disableAutocorrection(true)
                                .font(.system(.body, design: .monospaced))
                                .accessibilityIdentifier("PendingSessionWorkingDirectoryField")

                            if isConnected {
                                Button("Browse") {
                                    showingDirectoryPicker = true
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityIdentifier("PendingSessionBrowseDirectoryButton")
                            }
                        }
                    } else {
                        HStack {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            Text(currentCwd.isEmpty ? "Not set" : currentCwd)
                                .foregroundStyle(currentCwd.isEmpty ? .secondary : .primary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                } header: {
                    Text("This Session")
                } footer: {
                    if isPending {
                        Text("Change the working directory for this pending session before sending your first message.")
                    } else {
                        Text("The working directory for the current session. This is set when the session is created and cannot be changed.")
                    }
                }

                // Server's default working directory
                Section {
                    if isPending {
                        Button {
                            pendingWorkingDirectory = defaultCwd
                        } label: {
                            HStack {
                                Image(systemName: "folder.badge.gearshape")
                                    .foregroundStyle(.orange)
                                Text(defaultCwd.isEmpty ? "Not set" : defaultCwd)
                                    .foregroundStyle(defaultCwd.isEmpty ? .secondary : .primary)
                                    .lineLimit(2)
                                    .truncationMode(.middle)
                                Spacer()
                                if pendingWorkingDirectory == defaultCwd {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    } else {
                        HStack {
                            Image(systemName: "folder.badge.gearshape")
                                .foregroundStyle(.orange)
                            Text(defaultCwd.isEmpty ? "Not set" : defaultCwd)
                                .foregroundStyle(defaultCwd.isEmpty ? .secondary : .primary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                } header: {
                    Text("Server Default")
                } footer: {
                    Text("New sessions will use this directory. You can change this in server settings.")
                }

                let excluded = Set([
                    currentCwd.trimmingCharacters(in: .whitespacesAndNewlines),
                    defaultCwd.trimmingCharacters(in: .whitespacesAndNewlines)
                ].filter { !$0.isEmpty })
                let history = binding.usedWorkingDirectoryHistory.filter { !excluded.contains($0) }

                if !history.isEmpty {
                    Section {
                        ForEach(history, id: \.self) { directory in
                            if isPending {
                                Button {
                                    pendingWorkingDirectory = directory
                                } label: {
                                    HStack {
                                        Image(systemName: "folder")
                                            .foregroundStyle(.secondary)
                                        Text(directory)
                                            .font(.system(.body, design: .monospaced))
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        if pendingWorkingDirectory == directory {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(Color.accentColor)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            } else {
                                HStack {
                                    Image(systemName: "folder")
                                        .foregroundStyle(.secondary)
                                    Text(directory)
                                        .font(.system(.body, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    Spacer()
                                }
                                .contextMenu {
                                    Button("Copy") {
                                        UIPasteboard.general.string = directory
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("Previously Used")
                    } footer: {
                        Text(isPending ? "Tap to fill the working directory." : "Long-press a row to copy.")
                    }
                }
            }
            .navigationTitle("Working Directory")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                pendingWorkingDirectory = binding.currentSessionCwd
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(isPending ? "Save" : "Done") {
                        if isPending {
                            binding.updatePendingWorkingDirectory(pendingWorkingDirectory)
                        }
                        isPresented = false
                    }
                }
            }
            .sheet(isPresented: $showingDirectoryPicker) {
                RemoteDirectoryPickerSheet(
                    initialPath: pendingWorkingDirectory,
                    serverDefaultPath: binding.serverDefaultPathForBrowsing,
                    recentDirectories: binding.usedWorkingDirectoryHistory,
                    listDirectory: { params in
                        try await binding.listRemoteDirectory(params)
                    },
                    onSelect: { selectedPath in
                        pendingWorkingDirectory = selectedPath
                    }
                )
            }
        }
    }
}

/// Thin state-switching container for `.remotePath` chat link sheets (T6 / SD-5.3 / AC-508).
/// Intentionally has NO `NavigationStack`; swaps between `RemoteFilePreviewSheet` and
/// `RemoteFileBrowserSheet` in-place when `-32014` (`IS_A_DIRECTORY`) occurs without
/// mutating `activeSheet.id` or dismissing/re-presenting the modal sheet.
struct RemotePathSheetContainer: View {
    @State private var currentPath: String
    @State private var showingDirectory: Bool

    let lineAnchorHint: String?
    let projectPath: String?
    let serverDefaultPath: String
    let listDirectory: (NonlocalFsListParams) async throws -> NonlocalFsListResult?
    let readFile: (String) async throws -> NonlocalFsReadFileResult?
    let mermaidSVGProvider: ((String, Bool) async -> Result<String, Error>)?

    init(
        initialPath: String,
        prefersDirectory: Bool,
        lineAnchorHint: String?,
        projectPath: String?,
        serverDefaultPath: String,
        listDirectory: @escaping (NonlocalFsListParams) async throws -> NonlocalFsListResult?,
        readFile: @escaping (String) async throws -> NonlocalFsReadFileResult?,
        mermaidSVGProvider: ((String, Bool) async -> Result<String, Error>)? = nil
    ) {
        _currentPath = State(initialValue: initialPath)
        _showingDirectory = State(initialValue: prefersDirectory)
        self.lineAnchorHint = lineAnchorHint
        self.projectPath = projectPath
        self.serverDefaultPath = serverDefaultPath
        self.listDirectory = listDirectory
        self.readFile = readFile
        self.mermaidSVGProvider = mermaidSVGProvider
    }

    var body: some View {
        if showingDirectory {
            RemoteFileBrowserSheet(
                initialPath: currentPath,
                projectPath: projectPath,
                serverDefaultPath: serverDefaultPath,
                listDirectory: listDirectory,
                readFile: readFile,
                mermaidSVGProvider: mermaidSVGProvider
            )
        } else {
            RemoteFilePreviewSheet(
                filePath: currentPath,
                lineAnchorHint: lineAnchorHint,
                onOpenAsDirectory: { directoryPath in
                    currentPath = directoryPath
                    showingDirectory = true
                },
                readFile: readFile,
                mermaidSVGProvider: mermaidSVGProvider
            )
        }
    }
}
