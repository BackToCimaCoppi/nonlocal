import Combine
import Foundation

// MARK: - Models

public struct ServerProject: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let id: UUID
    public let serverId: UUID
    public var name: String
    public var directories: [String]
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        serverId: UUID,
        name: String,
        directories: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.serverId = serverId
        self.name = name
        self.directories = directories
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SessionGroupKey: Hashable, Codable, Sendable {
    case project(serverId: UUID, projectId: UUID)
    case folder(serverId: UUID, path: String)

    public var serverId: UUID {
        switch self {
        case .project(let serverId, _):
            return serverId
        case .folder(let serverId, _):
            return serverId
        }
    }

    public var stableId: String {
        switch self {
        case .project(let serverId, let projectId):
            return "project:\(serverId.uuidString):\(projectId.uuidString)"
        case .folder(let serverId, let path):
            return "folder:\(serverId.uuidString):\(path)"
        }
    }
}

public enum ProjectCardDisplay: Equatable, Sendable {
    case project(name: String, directoryShortName: String?)
    case unassignedDirectory(label: String)
    case none
}

public enum ProjectStoreError: Error, Equatable, Sendable {
    case emptyName
    case nameTooLong(max: Int)
    case duplicateName
    case invalidDirectory
    case projectNotFound
}

// MARK: - Path Normalization

public enum DirectoryPathNormalizer {
    /// Normalizes a directory path for deterministic matching and deduplication:
    /// 1. Trims leading/trailing whitespace and newlines; empty input returns `""`.
    /// 2. Collapses repeated `/` into a single `/`.
    /// 3. When a non-empty `homePath` is known, expands `~` and `~/...` against the normalized `homePath`.
    ///    When `homePath` is `nil` or empty, preserves `~` / `~/...` without guessing.
    /// 4. Preserves root `"/"` and trims any trailing `/` on non-root paths.
    /// 5. Preserves case for exact case-sensitive comparison.
    public static func normalize(_ rawPath: String, homePath: String? = nil) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var path = collapseSlashes(trimmed)

        if let rawHome = homePath {
            let normalizedHome = normalizeCore(rawHome)
            if !normalizedHome.isEmpty {
                if path == "~" || path == "~/" {
                    path = normalizedHome
                } else if path.hasPrefix("~/") {
                    path = normalizedHome + "/" + String(path.dropFirst(2))
                }
            }
        }

        path = collapseSlashes(path)
        return stripTrailingSlash(path)
    }

    private static func normalizeCore(_ rawPath: String) -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let collapsed = collapseSlashes(trimmed)
        return stripTrailingSlash(collapsed)
    }

    private static func collapseSlashes(_ input: String) -> String {
        var result = ""
        result.reserveCapacity(input.count)
        var previousWasSlash = false
        for character in input {
            if character == "/" {
                if !previousWasSlash {
                    result.append(character)
                    previousWasSlash = true
                }
            } else {
                result.append(character)
                previousWasSlash = false
            }
        }
        return result
    }

    private static func stripTrailingSlash(_ input: String) -> String {
        if input.count > 1 && input.hasSuffix("/") {
            return String(input.dropLast())
        }
        return input
    }
}

// MARK: - Pure Display & Disambiguation Resolver

public enum ProjectDisplayResolver {
    public static func resolveEffectivePath(
        cwd: String?,
        serverDefaultDirectory: String?,
        homePath: String?
    ) -> String {
        if let cwd {
            let normalizedCwd = DirectoryPathNormalizer.normalize(cwd, homePath: homePath)
            if !normalizedCwd.isEmpty {
                return normalizedCwd
            }
        }
        if let serverDefaultDirectory {
            let normalizedDefault = DirectoryPathNormalizer.normalize(
                serverDefaultDirectory,
                homePath: homePath
            )
            if !normalizedDefault.isEmpty {
                return normalizedDefault
            }
        }
        return ""
    }

    public static func project(
        forPath rawPath: String,
        serverId: UUID,
        projects: [ServerProject],
        homePath: String?
    ) -> ServerProject? {
        let normalized = DirectoryPathNormalizer.normalize(rawPath, homePath: homePath)
        guard !normalized.isEmpty else { return nil }
        return projects.first { project in
            guard project.serverId == serverId else { return false }
            return project.directories.contains { directory in
                DirectoryPathNormalizer.normalize(directory, homePath: homePath) == normalized
            }
        }
    }

    public static func disambiguatedDirectoryNames(for normalizedPaths: [String]) -> [String: String] {
        var uniquePaths: [String] = []
        var seen: Set<String> = []
        for path in normalizedPaths where !path.isEmpty {
            if seen.insert(path).inserted {
                uniquePaths.append(path)
            }
        }
        guard !uniquePaths.isEmpty else { return [:] }

        var componentsByPath: [String: [String]] = [:]
        var depthByPath: [String: Int] = [:]
        for path in uniquePaths {
            componentsByPath[path] = path.split(separator: "/").map(String.init)
            depthByPath[path] = 1
        }

        func candidateLabel(for path: String) -> String {
            if path == "/" {
                return "/"
            }
            let components = componentsByPath[path] ?? []
            let depth = depthByPath[path] ?? 1
            if components.isEmpty || depth > components.count {
                return path
            }
            return components.suffix(depth).joined(separator: "/")
        }

        while true {
            var pathsByLabel: [String: [String]] = [:]
            for path in uniquePaths {
                let label = candidateLabel(for: path)
                pathsByLabel[label, default: []].append(path)
            }

            var progressed = false
            for (_, collidingPaths) in pathsByLabel where collidingPaths.count > 1 {
                for path in collidingPaths {
                    let count = componentsByPath[path]?.count ?? 0
                    let currentDepth = depthByPath[path] ?? 1
                    if currentDepth <= count {
                        depthByPath[path] = currentDepth + 1
                        progressed = true
                    }
                }
            }

            if !progressed {
                break
            }
        }

        var result: [String: String] = [:]
        result.reserveCapacity(uniquePaths.count)
        for path in uniquePaths {
            result[path] = candidateLabel(for: path)
        }
        return result
    }

    public static func cardDisplayForTimeList(
        rawPath: String?,
        serverDefaultDirectory: String?,
        serverId: UUID,
        projects: [ServerProject],
        homePath: String?,
        unassignedUniverse: [String]
    ) -> ProjectCardDisplay {
        let effectivePath = resolveEffectivePath(
            cwd: rawPath,
            serverDefaultDirectory: serverDefaultDirectory,
            homePath: homePath
        )
        guard !effectivePath.isEmpty else { return .none }

        if let matchedProject = project(
            forPath: effectivePath,
            serverId: serverId,
            projects: projects,
            homePath: homePath
        ) {
            let normalizedDirs = deduplicatedNormalizedPaths(
                matchedProject.directories,
                homePath: homePath
            )
            if normalizedDirs.count <= 1 {
                return .project(name: matchedProject.name, directoryShortName: nil)
            }
            let disambiguated = disambiguatedDirectoryNames(for: normalizedDirs)
            let shortName = disambiguated[effectivePath] ?? fallbackShortName(for: effectivePath)
            return .project(name: matchedProject.name, directoryShortName: shortName)
        }

        var normalizedUniverse = deduplicatedNormalizedPaths(unassignedUniverse, homePath: homePath)
        if !normalizedUniverse.contains(effectivePath) {
            normalizedUniverse.append(effectivePath)
        }
        let disambiguated = disambiguatedDirectoryNames(for: normalizedUniverse)
        let label = disambiguated[effectivePath] ?? fallbackShortName(for: effectivePath)
        return .unassignedDirectory(label: label)
    }

    public static func cardDisplayForProjectGroup(
        rawPath: String?,
        serverDefaultDirectory: String?,
        groupKey: SessionGroupKey,
        projects: [ServerProject],
        homePath: String?
    ) -> String? {
        switch groupKey {
        case .folder:
            return nil
        case .project(let serverId, let projectId):
            guard let matchedProject = projects.first(where: {
                $0.serverId == serverId && $0.id == projectId
            }) else {
                return nil
            }
            let normalizedDirs = deduplicatedNormalizedPaths(
                matchedProject.directories,
                homePath: homePath
            )
            guard normalizedDirs.count > 1 else {
                return nil
            }
            let effectivePath = resolveEffectivePath(
                cwd: rawPath,
                serverDefaultDirectory: serverDefaultDirectory,
                homePath: homePath
            )
            guard !effectivePath.isEmpty else {
                return nil
            }
            var universe = normalizedDirs
            if !universe.contains(effectivePath) {
                universe.append(effectivePath)
            }
            let disambiguated = disambiguatedDirectoryNames(for: universe)
            return disambiguated[effectivePath] ?? fallbackShortName(for: effectivePath)
        }
    }

    public static func quickChipLabel(
        for rawPath: String,
        serverId: UUID,
        projects: [ServerProject],
        homePath: String?,
        unassignedUniverse: [String]
    ) -> String {
        let normalized = DirectoryPathNormalizer.normalize(rawPath, homePath: homePath)
        guard !normalized.isEmpty else { return rawPath }

        if let matchedProject = project(
            forPath: normalized,
            serverId: serverId,
            projects: projects,
            homePath: homePath
        ) {
            let normalizedDirs = deduplicatedNormalizedPaths(
                matchedProject.directories,
                homePath: homePath
            )
            if normalizedDirs.count <= 1 {
                return matchedProject.name
            }
            let disambiguated = disambiguatedDirectoryNames(for: normalizedDirs)
            let shortName = disambiguated[normalized] ?? fallbackShortName(for: normalized)
            return "\(matchedProject.name) / \(shortName)"
        }

        var normalizedUniverse = deduplicatedNormalizedPaths(unassignedUniverse, homePath: homePath)
        if !normalizedUniverse.contains(normalized) {
            normalizedUniverse.append(normalized)
        }
        let disambiguated = disambiguatedDirectoryNames(for: normalizedUniverse)
        return disambiguated[normalized] ?? fallbackShortName(for: normalized)
    }

    public static func groupTitle(
        for key: SessionGroupKey,
        projects: [ServerProject],
        homePath: String?,
        unassignedUniverse: [String],
        noFolderTitle: String
    ) -> String {
        switch key {
        case .project(let serverId, let projectId):
            if let matchedProject = projects.first(where: {
                $0.serverId == serverId && $0.id == projectId
            }) {
                return matchedProject.name
            }
            return noFolderTitle
        case .folder(_, let path):
            let normalized = DirectoryPathNormalizer.normalize(path, homePath: homePath)
            guard !normalized.isEmpty else {
                return noFolderTitle
            }
            var normalizedUniverse = deduplicatedNormalizedPaths(unassignedUniverse, homePath: homePath)
            if !normalizedUniverse.contains(normalized) {
                normalizedUniverse.append(normalized)
            }
            let disambiguated = disambiguatedDirectoryNames(for: normalizedUniverse)
            return disambiguated[normalized] ?? fallbackShortName(for: normalized)
        }
    }

    private static func deduplicatedNormalizedPaths(
        _ paths: [String],
        homePath: String?
    ) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        for raw in paths {
            let normalized = DirectoryPathNormalizer.normalize(raw, homePath: homePath)
            guard !normalized.isEmpty else { continue }
            if seen.insert(normalized).inserted {
                result.append(normalized)
            }
        }
        return result
    }

    private static func fallbackShortName(for normalizedPath: String) -> String {
        if normalizedPath == "/" {
            return "/"
        }
        let components = normalizedPath.split(separator: "/")
        if let last = components.last, !last.isEmpty {
            return String(last)
        }
        return normalizedPath
    }
}

// MARK: - ProjectStore

@MainActor
public final class ProjectStore: ObservableObject {
    public nonisolated static let storageKey = "nonlocal.serverProjects.v1"
    public nonisolated static let maxNameLength = 40

    @Published public private(set) var projectsByServer: [UUID: [ServerProject]] = [:]
    @Published public private(set) var homePathByServer: [UUID: String] = [:]

    private let defaults: UserDefaults
    private let storageKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private struct PersistedPayload: Codable {
        var projectsByServer: [String: [ServerProject]]
        var homePathByServer: [String: String]
    }

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = ProjectStore.storageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        load()
    }

    // MARK: - Queries

    public func projects(for serverId: UUID) -> [ServerProject] {
        projectsByServer[serverId] ?? []
    }

    public func homePath(for serverId: UUID) -> String? {
        homePathByServer[serverId]
    }

    public func project(id: UUID, forServerId serverId: UUID) -> ServerProject? {
        projects(for: serverId).first { $0.id == id }
    }

    public func project(forPath rawPath: String, serverId: UUID) -> ServerProject? {
        ProjectDisplayResolver.project(
            forPath: rawPath,
            serverId: serverId,
            projects: projects(for: serverId),
            homePath: homePath(for: serverId)
        )
    }

    public func sortedDirectories(
        for project: ServerProject,
        recentDirectories: [String]
    ) -> [String] {
        let serverHome = homePath(for: project.serverId)
        var recentRankByPath: [String: Int] = [:]
        for (index, rawRecent) in recentDirectories.enumerated() {
            let normalized = DirectoryPathNormalizer.normalize(rawRecent, homePath: serverHome)
            guard !normalized.isEmpty else { continue }
            if recentRankByPath[normalized] == nil {
                recentRankByPath[normalized] = index
            }
        }

        let indexed = project.directories.enumerated().map { (offset: $0.offset, path: $0.element) }
        return indexed.sorted { lhs, rhs in
            let lhsNormalized = DirectoryPathNormalizer.normalize(lhs.path, homePath: serverHome)
            let rhsNormalized = DirectoryPathNormalizer.normalize(rhs.path, homePath: serverHome)
            let lhsRank = recentRankByPath[lhsNormalized]
            let rhsRank = recentRankByPath[rhsNormalized]
            switch (lhsRank, rhsRank) {
            case let (l?, r?):
                if l != r { return l < r }
                return lhs.offset < rhs.offset
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.offset < rhs.offset
            }
        }.map(\.path)
    }

    // MARK: - Mutations

    @discardableResult
    public func createProject(
        name: String,
        serverId: UUID,
        initialDirectory: String? = nil,
        now: Date = Date()
    ) throws -> ServerProject {
        let validatedName = try validateProjectName(name, serverId: serverId, excludingProjectId: nil)
        let serverHome = homePath(for: serverId)

        var initialDirectories: [String] = []
        if let initialDirectory {
            let normalized = DirectoryPathNormalizer.normalize(initialDirectory, homePath: serverHome)
            guard !normalized.isEmpty else {
                throw ProjectStoreError.invalidDirectory
            }
            initialDirectories = [normalized]
        }

        var serverProjects = projectsByServer[serverId] ?? []

        if let boundPath = initialDirectories.first {
            removeDirectory(boundPath, from: &serverProjects, serverHome: serverHome, now: now)
        }

        let project = ServerProject(
            id: UUID(),
            serverId: serverId,
            name: validatedName,
            directories: initialDirectories,
            createdAt: now,
            updatedAt: now
        )
        serverProjects.append(project)
        projectsByServer[serverId] = serverProjects
        persist()
        return project
    }

    public func renameProject(
        id: UUID,
        to newName: String,
        serverId: UUID,
        now: Date = Date()
    ) throws {
        var serverProjects = projectsByServer[serverId] ?? []
        guard let index = serverProjects.firstIndex(where: { $0.id == id }) else {
            throw ProjectStoreError.projectNotFound
        }
        let validatedName = try validateProjectName(newName, serverId: serverId, excludingProjectId: id)
        serverProjects[index].name = validatedName
        serverProjects[index].updatedAt = now
        projectsByServer[serverId] = serverProjects
        persist()
    }

    public func bindDirectory(
        _ rawPath: String,
        toProjectId projectId: UUID,
        serverId: UUID,
        now: Date = Date()
    ) throws {
        let serverHome = homePath(for: serverId)
        let normalized = DirectoryPathNormalizer.normalize(rawPath, homePath: serverHome)
        guard !normalized.isEmpty else {
            throw ProjectStoreError.invalidDirectory
        }

        var serverProjects = projectsByServer[serverId] ?? []
        guard let targetIndex = serverProjects.firstIndex(where: { $0.id == projectId }) else {
            throw ProjectStoreError.projectNotFound
        }

        for index in serverProjects.indices where index != targetIndex {
            let originalCount = serverProjects[index].directories.count
            serverProjects[index].directories.removeAll { dir in
                DirectoryPathNormalizer.normalize(dir, homePath: serverHome) == normalized
            }
            if serverProjects[index].directories.count != originalCount {
                serverProjects[index].updatedAt = now
            }
        }

        var targetDirs: [String] = []
        var seen: Set<String> = []
        for dir in serverProjects[targetIndex].directories {
            let norm = DirectoryPathNormalizer.normalize(dir, homePath: serverHome)
            guard !norm.isEmpty else { continue }
            if seen.insert(norm).inserted {
                targetDirs.append(norm)
            }
        }
        if seen.insert(normalized).inserted {
            targetDirs.append(normalized)
        }
        serverProjects[targetIndex].directories = targetDirs
        serverProjects[targetIndex].updatedAt = now

        projectsByServer[serverId] = serverProjects
        persist()
    }

    public func unbindDirectory(
        _ rawPath: String,
        fromProjectId projectId: UUID,
        serverId: UUID,
        now: Date = Date()
    ) {
        let serverHome = homePath(for: serverId)
        let normalized = DirectoryPathNormalizer.normalize(rawPath, homePath: serverHome)
        guard !normalized.isEmpty else { return }

        var serverProjects = projectsByServer[serverId] ?? []
        guard let targetIndex = serverProjects.firstIndex(where: { $0.id == projectId }) else {
            return
        }

        let originalCount = serverProjects[targetIndex].directories.count
        serverProjects[targetIndex].directories.removeAll { dir in
            DirectoryPathNormalizer.normalize(dir, homePath: serverHome) == normalized
        }
        if serverProjects[targetIndex].directories.count != originalCount {
            serverProjects[targetIndex].updatedAt = now
            projectsByServer[serverId] = serverProjects
            persist()
        }
    }

    public func deleteProject(id: UUID, serverId: UUID) {
        guard var serverProjects = projectsByServer[serverId] else { return }
        let originalCount = serverProjects.count
        serverProjects.removeAll { $0.id == id }
        guard serverProjects.count != originalCount else { return }
        if serverProjects.isEmpty {
            projectsByServer.removeValue(forKey: serverId)
        } else {
            projectsByServer[serverId] = serverProjects
        }
        persist()
    }

    public func deleteProjects(forServerId serverId: UUID) {
        let removedProjects = projectsByServer.removeValue(forKey: serverId) != nil
        let removedHome = homePathByServer.removeValue(forKey: serverId) != nil
        if removedProjects || removedHome {
            persist()
        }
    }

    public func clearHomePath(forServerId serverId: UUID) {
        if homePathByServer.removeValue(forKey: serverId) != nil {
            persist()
        }
    }

    public func updateHomePath(_ rawHomePath: String, forServerId serverId: UUID) {
        let normalizedHome = DirectoryPathNormalizer.normalize(rawHomePath, homePath: nil)
        guard !normalizedHome.isEmpty else { return }

        homePathByServer[serverId] = normalizedHome

        if var serverProjects = projectsByServer[serverId], !serverProjects.isEmpty {
            // Step 1: Normalize and deduplicate directories within each project.
            for index in serverProjects.indices {
                var deduped: [String] = []
                var seen: Set<String> = []
                for dir in serverProjects[index].directories {
                    let norm = DirectoryPathNormalizer.normalize(dir, homePath: normalizedHome)
                    guard !norm.isEmpty else { continue }
                    if seen.insert(norm).inserted {
                        deduped.append(norm)
                    }
                }
                serverProjects[index].directories = deduped
            }

            // Step 2: Resolve cross-project physical path duplicates by keeping ownership
            // on the project with the latest `updatedAt` (tie-break: later `createdAt`, then later index).
            var ownerIndexByPath: [String: Int] = [:]
            for index in serverProjects.indices {
                for path in serverProjects[index].directories {
                    if let existingIndex = ownerIndexByPath[path] {
                        let candidate = serverProjects[index]
                        let incumbent = serverProjects[existingIndex]
                        let candidateWins: Bool
                        if candidate.updatedAt != incumbent.updatedAt {
                            candidateWins = candidate.updatedAt > incumbent.updatedAt
                        } else if candidate.createdAt != incumbent.createdAt {
                            candidateWins = candidate.createdAt > incumbent.createdAt
                        } else {
                            candidateWins = index > existingIndex
                        }
                        if candidateWins {
                            ownerIndexByPath[path] = index
                        }
                    } else {
                        ownerIndexByPath[path] = index
                    }
                }
            }

            for index in serverProjects.indices {
                serverProjects[index].directories.removeAll { path in
                    ownerIndexByPath[path] != index
                }
            }

            projectsByServer[serverId] = serverProjects
        }

        persist()
    }

    // MARK: - Validation & Persistence

    private func validateProjectName(
        _ rawName: String,
        serverId: UUID,
        excludingProjectId: UUID?
    ) throws -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectStoreError.emptyName
        }
        guard trimmed.count <= Self.maxNameLength else {
            throw ProjectStoreError.nameTooLong(max: Self.maxNameLength)
        }
        let existing = projectsByServer[serverId] ?? []
        let hasDuplicate = existing.contains { project in
            if let excludingProjectId, project.id == excludingProjectId {
                return false
            }
            return project.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame
        }
        if hasDuplicate {
            throw ProjectStoreError.duplicateName
        }
        return trimmed
    }

    private func removeDirectory(
        _ normalizedPath: String,
        from serverProjects: inout [ServerProject],
        serverHome: String?,
        now: Date
    ) {
        for index in serverProjects.indices {
            let originalCount = serverProjects[index].directories.count
            serverProjects[index].directories.removeAll { dir in
                DirectoryPathNormalizer.normalize(dir, homePath: serverHome) == normalizedPath
            }
            if serverProjects[index].directories.count != originalCount {
                serverProjects[index].updatedAt = now
            }
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else {
            projectsByServer = [:]
            homePathByServer = [:]
            return
        }
        guard let payload = try? decoder.decode(PersistedPayload.self, from: data) else {
            projectsByServer = [:]
            homePathByServer = [:]
            return
        }
        var decodedProjects: [UUID: [ServerProject]] = [:]
        for (key, value) in payload.projectsByServer {
            if let uuid = UUID(uuidString: key) {
                decodedProjects[uuid] = value
            }
        }
        var decodedHomes: [UUID: String] = [:]
        for (key, value) in payload.homePathByServer {
            if let uuid = UUID(uuidString: key) {
                decodedHomes[uuid] = value
            }
        }
        projectsByServer = decodedProjects
        homePathByServer = decodedHomes
    }

    private func persist() {
        var encodedProjects: [String: [ServerProject]] = [:]
        for (uuid, value) in projectsByServer {
            encodedProjects[uuid.uuidString] = value
        }
        var encodedHomes: [String: String] = [:]
        for (uuid, value) in homePathByServer {
            encodedHomes[uuid.uuidString] = value
        }
        let payload = PersistedPayload(
            projectsByServer: encodedProjects,
            homePathByServer: encodedHomes
        )
        guard let data = try? encoder.encode(payload) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
