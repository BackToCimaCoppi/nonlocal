import SwiftUI
import ACPClient

public enum QuickDirectoryChipKind: String, Equatable, Sendable {
    case currentProject
    case home
    case defaultDirectory
    case recent
}

struct QuickDirectoryChip: Identifiable, Equatable {
    let kind: QuickDirectoryChipKind
    let label: String
    let path: String
    let icon: String

    var id: String { path }
}

@MainActor
final class RemoteDirectoryPickerViewModel: ObservableObject {
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

    static let showHiddenDefaultsKey = "nonlocal.remoteDirectoryPicker.showHidden"

    private let initialInputPath: String
    private let serverDefaultPath: String
    private let recentDirectories: [String]
    private let listDirectory: (NonlocalFsListParams) async throws -> NonlocalFsListResult?
    private let defaults: UserDefaults
    private var requestToken: UInt64 = 0
    private var activeTask: Task<Void, Never>?

    init(
        initialPath: String,
        serverDefaultPath: String,
        recentDirectories: [String],
        listDirectory: @escaping (NonlocalFsListParams) async throws -> NonlocalFsListResult?,
        defaults: UserDefaults = .standard
    ) {
        self.initialInputPath = initialPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serverDefaultPath = serverDefaultPath.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recentDirectories = recentDirectories
        self.listDirectory = listDirectory
        self.defaults = defaults
        self.showHidden = defaults.bool(forKey: Self.showHiddenDefaultsKey)

        if !self.initialInputPath.isEmpty {
            self.currentPath = self.initialInputPath
        } else if !self.serverDefaultPath.isEmpty {
            self.currentPath = self.serverDefaultPath
        } else {
            self.currentPath = "~"
        }
    }

    deinit {
        activeTask?.cancel()
    }

    var quickChips: [QuickDirectoryChip] {
        var result: [QuickDirectoryChip] = []
        var seenCanonical: Set<String> = []

        func appendUnique(kind: QuickDirectoryChipKind, label: String, rawPath: String, icon: String) {
            let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let canonical = Self.canonicalizeForDedup(trimmed, homePath: homePath)
            guard !seenCanonical.contains(canonical) else { return }
            seenCanonical.insert(canonical)
            result.append(QuickDirectoryChip(kind: kind, label: label, path: trimmed, icon: icon))
        }

        appendUnique(kind: .home, label: String(localized: "Home ~"), rawPath: "~", icon: "house")
        if !serverDefaultPath.isEmpty {
            appendUnique(kind: .defaultDirectory, label: String(localized: "Default Directory"), rawPath: serverDefaultPath, icon: "folder.badge.gearshape")
        }
        for recent in recentDirectories {
            let name = (recent as NSString).lastPathComponent
            let label = name.isEmpty || name == "/" ? recent : name
            appendUnique(kind: .recent, label: label, rawPath: recent, icon: "clock")
        }
        return result
    }

    static func canonicalizeForDedup(_ path: String, homePath: String?) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        var expanded = trimmed
        if let home = homePath?.trimmingCharacters(in: .whitespacesAndNewlines), !home.isEmpty {
            let normalizedHome = stripTrailingSlash(home)
            if expanded == "~" {
                expanded = normalizedHome
            } else if expanded.hasPrefix("~/") {
                expanded = normalizedHome + "/" + String(expanded.dropFirst(2))
            }
        }
        return stripTrailingSlash(expanded)
    }

    private static func stripTrailingSlash(_ path: String) -> String {
        if path.count > 1 && path.hasSuffix("/") {
            return String(path.dropLast())
        }
        return path
    }

    func loadInitial() {
        load(path: currentPath, query: searchQuery, allowFallbackToHome: true)
    }

    func navigate(to path: String) {
        searchQuery = ""
        infoBanner = nil
        load(path: path, query: "", allowFallbackToHome: false)
    }

    func navigateUp() {
        guard let parentPath else { return }
        navigate(to: parentPath)
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
            includeFiles: false,
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
            includeFiles: false,
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
            if let rpcCode = Self.extractRPCCode(from: error) {
                if (rpcCode == NonlocalFsErrorCode.notFound.rawValue || rpcCode == NonlocalFsErrorCode.notDirectory.rawValue),
                   allowFallbackToHome,
                   params.path != "~" {
                    infoBanner = String(localized: "Original path not found; switched to Home (~)")
                    let fallbackParams = NonlocalFsListParams(
                        path: "~",
                        includeFiles: false,
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
                case -32601:
                    errorMessage = String(localized: "This bridge version does not support directory browsing. Upgrade the bridge or enter the path manually.")
                case NonlocalFsErrorCode.notFound.rawValue:
                    errorMessage = String(localized: "Directory not found")
                case NonlocalFsErrorCode.notDirectory.rawValue:
                    errorMessage = String(localized: "Target path is not a directory")
                case NonlocalFsErrorCode.invalidParams.rawValue:
                    errorMessage = String(localized: "Invalid directory path format")
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

    static func extractRPCCode(from error: Error) -> Int? {
        if let serviceError = error as? ACPServiceError {
            return serviceError.rpcCode
        }
        return nil
    }
}

struct RemoteDirectoryPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var viewModel: RemoteDirectoryPickerViewModel
    let onSelect: (String) -> Void

    init(
        initialPath: String,
        serverDefaultPath: String,
        recentDirectories: [String],
        listDirectory: @escaping (NonlocalFsListParams) async throws -> NonlocalFsListResult?,
        onSelect: @escaping (String) -> Void
    ) {
        _viewModel = StateObject(
            wrappedValue: RemoteDirectoryPickerViewModel(
                initialPath: initialPath,
                serverDefaultPath: serverDefaultPath,
                recentDirectories: recentDirectories,
                listDirectory: listDirectory
            )
        )
        self.onSelect = onSelect
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
                                .accessibilityIdentifier("dir-picker-info-banner")
                        }
                    }

                    if let errorMessage = viewModel.errorMessage {
                        Section {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                                    .accessibilityIdentifier("dir-picker-error-message")
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
                                Text("Loading directories…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else if viewModel.entries.isEmpty {
                        Section {
                            Text("No subdirectories here")
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
                                .accessibilityIdentifier("dir-picker-parent-row")
                            }

                            ForEach(viewModel.entries, id: \.path) { entry in
                                Button {
                                    viewModel.navigate(to: entry.path)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: entry.type == .symlink ? "folder.badge.questionmark" : "folder.fill")
                                            .foregroundStyle(.blue)
                                        Text(entry.name)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.tertiary)
                                    }
                                }
                                .accessibilityIdentifier("dir-picker-entry-\(entry.name)")
                            }
                        } footer: {
                            if viewModel.truncated {
                                Text("Showing first 500 items. Use search to filter.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .accessibilityIdentifier("dir-picker-truncated-footer")
                            }
                        }
                    }
                }
                #if os(iOS)
                .listStyle(.insetGrouped)
                #endif

                footerConfirmBar
            }
            .navigationTitle("Select Directory")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .searchable(
                text: Binding(
                    get: { viewModel.searchQuery },
                    set: { viewModel.updateSearchQuery($0) }
                ),
                prompt: "Search directories"
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .accessibilityIdentifier("dir-picker-cancel-button")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        viewModel.toggleShowHidden()
                    } label: {
                        Image(systemName: viewModel.showHidden ? "eye.fill" : "eye.slash")
                    }
                    .accessibilityIdentifier("dir-picker-toggle-hidden")
                    .accessibilityLabel(viewModel.showHidden ? Text("Hide hidden items") : Text("Show hidden items"))
                }
            }
            .onAppear {
                viewModel.loadInitial()
            }
        }
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
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("dir-picker-current-path")
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
                            .accessibilityIdentifier("dir-picker-chip-\(chip.kind.rawValue)")
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
        .padding(.bottom, 6)
    }

    private var footerConfirmBar: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                onSelect(viewModel.currentPath)
                dismiss()
            } label: {
                Text("Select This Directory")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.currentPath.isEmpty || viewModel.errorMessage != nil)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .accessibilityIdentifier("dir-picker-confirm-button")
        }
    }
}
