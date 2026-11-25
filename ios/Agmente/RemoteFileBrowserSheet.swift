import SwiftUI
import ACPClient

@MainActor
final class RemoteFileBrowserViewModel: ObservableObject {
    @Published var currentPath: String
    @Published var parentPath: String?
    @Published var homePath: String?
    @Published var entries: [NonlocalFsEntry] = []
    @Published var totalCount: Int = 0
    @Published var truncated: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var infoBanner: String?
    @Published var searchQuery: String = ""
    @Published var showHidden: Bool {
        didSet {
            defaults.set(showHidden, forKey: Self.showHiddenDefaultsKey)
        }
    }

    static let showHiddenDefaultsKey = "nonlocal.remoteFileBrowser.showHidden"

    let projectPath: String?
    let serverDefaultPath: String
    private let listDirectory: (NonlocalFsListParams) async throws -> NonlocalFsListResult?
    private let defaults: UserDefaults
    private var requestToken: UInt64 = 0
    private var activeTask: Task<Void, Never>?

    init(
        initialPath: String,
        projectPath: String?,
        serverDefaultPath: String,
        listDirectory: @escaping (NonlocalFsListParams) async throws -> NonlocalFsListResult?,
        defaults: UserDefaults = .standard
    ) {
        let trimmedInitial = initialPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProject = projectPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDefault = serverDefaultPath.trimmingCharacters(in: .whitespacesAndNewlines)

        self.projectPath = (trimmedProject?.isEmpty == false) ? trimmedProject : nil
        self.serverDefaultPath = trimmedDefault.isEmpty ? "~" : trimmedDefault
        self.currentPath = trimmedInitial.isEmpty ? self.serverDefaultPath : trimmedInitial
        self.listDirectory = listDirectory
        self.defaults = defaults
        self.showHidden = defaults.bool(forKey: Self.showHiddenDefaultsKey)
    }

    deinit {
        activeTask?.cancel()
    }

    /// Deduplicated quick chips: optional "Current Project" (only when `projectPath` is non-nil),
    /// "Home ~", and "Server Default", deduplicated pairwise by canonical absolute path (AC-406).
    var quickChips: [QuickDirectoryChip] {
        var result: [QuickDirectoryChip] = []
        var seen: Set<String> = []

        func appendUnique(kind: QuickDirectoryChipKind, label: String, rawPath: String, icon: String) {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let canonical = RemoteDirectoryPickerViewModel.canonicalizeForDedup(trimmed, homePath: homePath)
            guard !seen.contains(canonical) else { return }
            seen.insert(canonical)
            result.append(QuickDirectoryChip(kind: kind, label: label, path: trimmed, icon: icon))
        }

        if let projectPath {
            appendUnique(kind: .currentProject, label: String(localized: "Current Project"), rawPath: projectPath, icon: "folder.fill")
        }
        appendUnique(kind: .home, label: String(localized: "Home ~"), rawPath: "~", icon: "house")
        appendUnique(kind: .defaultDirectory, label: String(localized: "Server Default"), rawPath: serverDefaultPath, icon: "server.rack")
        return result
    }

    func loadInitial() {
        load(path: currentPath, query: searchQuery, allowFallbackToHome: true)
    }

    func navigate(to path: String) {
        searchQuery = ""
        infoBanner = nil
        load(path: path, query: "", allowFallbackToHome: false)
    }

    func updateSearchQuery(_ newQuery: String) {
        searchQuery = newQuery
        load(path: currentPath, query: newQuery, allowFallbackToHome: false)
    }

    func toggleShowHidden() {
        showHidden.toggle()
        load(path: currentPath, query: searchQuery, allowFallbackToHome: false)
    }

    func load(path: String, query: String, allowFallbackToHome: Bool) {
        activeTask?.cancel()
        requestToken &+= 1
        let token = requestToken
        isLoading = true
        errorMessage = nil
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = NonlocalFsListParams(
            path: path,
            includeFiles: true,
            showHidden: showHidden,
            query: trimmedQuery.isEmpty ? nil : trimmedQuery,
            limit: 500
        )
        activeTask = Task { [weak self] in
            guard let self else { return }
            await self.executeLoad(params: params, token: token, allowFallbackToHome: allowFallbackToHome)
        }
    }

    @discardableResult
    func loadAndWait(path: String, query: String = "", allowFallbackToHome: Bool = false) async -> Bool {
        activeTask?.cancel()
        requestToken &+= 1
        let token = requestToken
        isLoading = true
        errorMessage = nil
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = NonlocalFsListParams(
            path: path,
            includeFiles: true,
            showHidden: showHidden,
            query: trimmedQuery.isEmpty ? nil : trimmedQuery,
            limit: 500
        )
        return await executeLoad(params: params, token: token, allowFallbackToHome: allowFallbackToHome)
    }

    @discardableResult
    private func executeLoad(
        params: NonlocalFsListParams,
        token: UInt64,
        allowFallbackToHome: Bool
    ) async -> Bool {
        do {
            let result = try await listDirectory(params)
            guard !Task.isCancelled, token == requestToken else { return false }
            isLoading = false
            guard let result else {
                errorMessage = String(localized: "Unable to load directory listing")
                return false
            }
            currentPath = result.path
            parentPath = result.parentPath
            if !result.homePath.isEmpty {
                homePath = result.homePath
            }
            entries = result.entries
            totalCount = result.totalCount
            truncated = result.truncated
            errorMessage = nil
            return true
        } catch {
            guard !Task.isCancelled, token == requestToken else { return false }
            if let rpcCode = RemoteDirectoryPickerViewModel.extractRPCCode(from: error) {
                if (rpcCode == NonlocalFsErrorCode.notFound.rawValue || rpcCode == NonlocalFsErrorCode.notDirectory.rawValue),
                   allowFallbackToHome,
                   params.path != "~" {
                    infoBanner = String(localized: "Original path not found; switched to Home (~)")
                    let fallbackParams = NonlocalFsListParams(
                        path: "~",
                        includeFiles: true,
                        showHidden: showHidden,
                        query: nil,
                        limit: 500
                    )
                    return await executeLoad(params: fallbackParams, token: token, allowFallbackToHome: false)
                }
                isLoading = false
                switch rpcCode {
                case NonlocalFsErrorCode.permissionDenied.rawValue:
                    errorMessage = String(localized: "Permission denied for this directory")
                case NonlocalFsErrorCode.notFound.rawValue:
                    errorMessage = String(localized: "Directory not found")
                case NonlocalFsErrorCode.notDirectory.rawValue:
                    errorMessage = String(localized: "Target path is not a directory")
                default:
                    errorMessage = error.localizedDescription
                }
            } else {
                isLoading = false
                errorMessage = error.localizedDescription
            }
            return false
        }
    }
}

struct RemoteFileBrowserSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: RemoteFileBrowserViewModel
    let readFile: (String) async throws -> NonlocalFsReadFileResult?
    let mermaidSVGProvider: ((String, Bool) async -> Result<String, Error>)?

    init(
        initialPath: String,
        projectPath: String?,
        serverDefaultPath: String,
        listDirectory: @escaping (NonlocalFsListParams) async throws -> NonlocalFsListResult?,
        readFile: @escaping (String) async throws -> NonlocalFsReadFileResult?,
        mermaidSVGProvider: ((String, Bool) async -> Result<String, Error>)? = nil
    ) {
        _viewModel = StateObject(
            wrappedValue: RemoteFileBrowserViewModel(
                initialPath: initialPath,
                projectPath: projectPath,
                serverDefaultPath: serverDefaultPath,
                listDirectory: listDirectory
            )
        )
        self.readFile = readFile
        self.mermaidSVGProvider = mermaidSVGProvider
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                headerControls
                List {
                    if let banner = viewModel.infoBanner {
                        Section {
                            Label(banner, systemImage: "info.circle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                                Button("Retry") {
                                    viewModel.load(path: viewModel.currentPath, query: viewModel.searchQuery, allowFallbackToHome: false)
                                }
                                .font(.footnote.weight(.medium))
                            }
                            .padding(.vertical, 4)
                        }
                    } else if viewModel.isLoading && viewModel.entries.isEmpty {
                        Section {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading files…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if viewModel.entries.isEmpty {
                        Section {
                            Text("This directory is empty")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Section {
                            if let parent = viewModel.parentPath {
                                Button {
                                    viewModel.navigate(to: parent)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "arrow.up.doc")
                                            .foregroundStyle(.secondary)
                                        Text("Parent Directory")
                                            .foregroundStyle(.primary)
                                        Spacer()
                                    }
                                }
                                .accessibilityIdentifier("file-browser-parent-row")
                            }

                            ForEach(viewModel.entries, id: \.path) { entry in
                                entryRow(for: entry)
                            }
                        } footer: {
                            if viewModel.truncated {
                                Text("Showing first 500 items. Use search to filter.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif
            }
            .navigationTitle("Server Files")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(
                text: Binding(
                    get: { viewModel.searchQuery },
                    set: { viewModel.updateSearchQuery($0) }
                ),
                prompt: "Search files or folders"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                    .accessibilityIdentifier("file-browser-close-button")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.toggleShowHidden()
                    } label: {
                        Image(systemName: viewModel.showHidden ? "eye.fill" : "eye.slash")
                    }
                    .accessibilityIdentifier("file-browser-toggle-hidden")
                    .accessibilityLabel(viewModel.showHidden ? Text("Hide hidden items") : Text("Show hidden items"))
                }
            }
            .onAppear {
                viewModel.loadInitial()
            }
        }
    }

    @ViewBuilder
    private func entryRow(for entry: NonlocalFsEntry) -> some View {
        let isDir = entry.type == .dir || (entry.type == .symlink && entry.targetType == .dir)
        let isBroken = entry.type == .symlink && entry.targetType == .broken

        if isBroken {
            HStack(spacing: 10) {
                Image(systemName: "link.badge.plus")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text("Broken link (cannot preview)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .opacity(0.6)
            .accessibilityIdentifier("file-browser-broken-\(entry.name)")
        } else if isDir {
            Button {
                viewModel.navigate(to: entry.path)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: entry.type == .symlink ? "folder.badge.gearshape" : "folder.fill")
                        .foregroundStyle(.blue)
                    Text(entry.name)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .accessibilityIdentifier("file-browser-dir-\(entry.name)")
        } else {
            NavigationLink {
                RemoteFilePreviewView(
                    filePath: entry.path,
                    knownFileSize: entry.size.map { Int64($0) },
                    readFile: readFile,
                    mermaidSVGProvider: mermaidSVGProvider
                )
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: iconName(for: entry.name))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let size = entry.size {
                            Text(RemoteFilePreviewFormatter.formatByteCount(Int64(size)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
            }
            .accessibilityIdentifier("file-browser-file-\(entry.name)")
        }
    }

    private func iconName(for filename: String) -> String {
        let lower = filename.lowercased()
        if lower.hasSuffix(".md") || lower.hasSuffix(".markdown") { return "doc.richtext" }
        if lower.hasSuffix(".html") || lower.hasSuffix(".htm") { return "globe" }
        if lower.hasSuffix(".png") || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg")
            || lower.hasSuffix(".gif") || lower.hasSuffix(".webp") || lower.hasSuffix(".svg")
            || lower.hasSuffix(".heic") || lower.hasSuffix(".bmp") {
            return "photo"
        }
        return "doc.text"
    }

    private var headerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(viewModel.currentPath)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("file-browser-current-path")
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            if !viewModel.quickChips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.quickChips) { chip in
                            Button {
                                viewModel.navigate(to: chip.path)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: chip.icon)
                                        .font(.caption2)
                                    Text(chip.label)
                                        .font(.caption.weight(.medium))
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Color.secondary.opacity(0.14)))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("file-browser-chip-\(chip.kind.rawValue)")
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.bottom, 6)
    }
}
