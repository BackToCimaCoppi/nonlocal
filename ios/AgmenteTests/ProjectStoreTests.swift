import XCTest
import ACPClient
@testable import Agmente

// SC-AC-052: ProjectStore G-6 golden regression (unique binding, atomic rebind, homePath dedup, delete preservation).
@MainActor
final class ProjectStoreTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ProjectStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - W2-AC-301: 1-to-many unique binding, atomic rebind, name validation

    func testW2AC301_UniqueBindingAtomicRebindAndNameValidation() throws {
        let store = ProjectStore(defaults: defaults)
        let serverA = UUID()

        let nonlocal = try store.createProject(name: "Nonlocal", serverId: serverA, initialDirectory: "/u/nonlocal/master")
        try store.bindDirectory("/u/nonlocal/wave2", toProjectId: nonlocal.id, serverId: serverA)

        let afterBind = try XCTUnwrap(store.project(id: nonlocal.id, forServerId: serverA))
        XCTAssertEqual(Set(afterBind.directories), Set(["/u/nonlocal/master", "/u/nonlocal/wave2"]))

        let temp = try store.createProject(name: "Temp", serverId: serverA)
        try store.bindDirectory("/u/nonlocal/wave2", toProjectId: temp.id, serverId: serverA)

        let nonlocalAfter = try XCTUnwrap(store.project(id: nonlocal.id, forServerId: serverA))
        let tempAfter = try XCTUnwrap(store.project(id: temp.id, forServerId: serverA))
        XCTAssertEqual(nonlocalAfter.directories, ["/u/nonlocal/master"], "Rebind must atomically remove directory from old project")
        XCTAssertEqual(tempAfter.directories, ["/u/nonlocal/wave2"])

        // Invalid names: empty, >40 chars, case-insensitive duplicate
        XCTAssertThrowsError(try store.createProject(name: "   ", serverId: serverA)) { error in
            XCTAssertEqual(error as? ProjectStoreError, .emptyName)
        }
        let longName = String(repeating: "a", count: 41)
        XCTAssertThrowsError(try store.createProject(name: longName, serverId: serverA)) { error in
            XCTAssertEqual(error as? ProjectStoreError, .nameTooLong(max: 40))
        }
        XCTAssertThrowsError(try store.createProject(name: "nonlocal", serverId: serverA)) { error in
            XCTAssertEqual(error as? ProjectStoreError, .duplicateName)
        }
    }

    // MARK: - W2-AC-302: Persistence, corrupt JSON fallback, endpoint change clears homePath, deleteServer cascade

    func testW2AC302_PersistenceCorruptFallbackAndServerLifecycleCascade() throws {
        let serverA = UUID()
        let serverB = UUID()

        do {
            let store = ProjectStore(defaults: defaults)
            _ = try store.createProject(name: "ProjA", serverId: serverA, initialDirectory: "/work/master")
            _ = try store.createProject(name: "ProjB", serverId: serverB, initialDirectory: "/work/master")
            store.updateHomePath("/Users/alice", forServerId: serverA)
            store.updateHomePath("/Users/bob", forServerId: serverB)
        }

        // 1. Reload restores both servers cleanly without cross-server collision
        let reloaded = ProjectStore(defaults: defaults)
        XCTAssertEqual(reloaded.projects(for: serverA).map(\.name), ["ProjA"])
        XCTAssertEqual(reloaded.projects(for: serverB).map(\.name), ["ProjB"])
        XCTAssertEqual(reloaded.homePath(for: serverA), "/Users/alice")
        XCTAssertEqual(reloaded.homePath(for: serverB), "/Users/bob")

        // 2. Corrupt JSON falls back to empty without crashing
        defaults.set(Data("{not-valid-json".utf8), forKey: ProjectStore.storageKey)
        let recovered = ProjectStore(defaults: defaults)
        XCTAssertTrue(recovered.projects(for: serverA).isEmpty)
        XCTAssertNil(recovered.homePath(for: serverA))

        // 3. AppViewModel.updateServer endpoint change clears homePathByServer[A]; deleteServer cascades
        let storage = SessionStorage.inMemory()
        let cfgA = ACPServerConfiguration(
            id: serverA, name: "A", scheme: "ws", host: "127.0.0.1:19101",
            token: "", workingDirectory: "/work"
        )
        let cfgB = ACPServerConfiguration(
            id: serverB, name: "B", scheme: "ws", host: "127.0.0.1:19102",
            token: "", workingDirectory: "/work"
        )
        storage.saveServer(cfgA)
        storage.saveServer(cfgB)

        let appVM = AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )
        _ = try appVM.projectStore.createProject(name: "ProjA", serverId: serverA, initialDirectory: "/work/master")
        _ = try appVM.projectStore.createProject(name: "ProjB", serverId: serverB, initialDirectory: "/work/master")
        appVM.projectStore.updateHomePath("/Users/alice", forServerId: serverA)
        appVM.projectStore.updateHomePath("/Users/bob", forServerId: serverB)

        // Endpoint change clears homePath for A but keeps projects
        let updatedConfig = ValidatedServerConfiguration(
            name: "A",
            scheme: "ws",
            host: "127.0.0.1:19999",
            token: "",
            workingDirectory: "/work",
            agentInfo: nil
        )
        appVM.updateServer(serverA, with: updatedConfig)
        XCTAssertNil(appVM.projectStore.homePath(for: serverA), "Changing endpoint must clear cached homePath")
        XCTAssertEqual(appVM.projectStore.homePath(for: serverB), "/Users/bob")
        XCTAssertEqual(appVM.projectStore.projects(for: serverA).count, 1)

        // Delete server A cascades projects & homePath, B remains intact
        appVM.projectStore.updateHomePath("/Users/alice2", forServerId: serverA)
        appVM.deleteServer(serverA)
        XCTAssertTrue(appVM.projectStore.projects(for: serverA).isEmpty)
        XCTAssertNil(appVM.projectStore.homePath(for: serverA))
        XCTAssertEqual(appVM.projectStore.projects(for: serverB).map(\.name), ["ProjB"])
        XCTAssertEqual(appVM.projectStore.homePath(for: serverB), "/Users/bob")
    }

    // MARK: - W2-AC-303: Normalization & updateHomePath tilde/absolute dedup

    func testW2AC303_NormalizationAndHomePathDeduplication() throws {
        // Unknown homePath preserves ~/...
        XCTAssertEqual(DirectoryPathNormalizer.normalize("  ~/repo/  ", homePath: nil), "~/repo")
        XCTAssertEqual(DirectoryPathNormalizer.normalize("/", homePath: nil), "/")
        XCTAssertEqual(DirectoryPathNormalizer.normalize("/a//b///c/", homePath: nil), "/a/b/c")
        XCTAssertNotEqual(
            DirectoryPathNormalizer.normalize("/Work/App", homePath: nil),
            DirectoryPathNormalizer.normalize("/work/app", homePath: nil)
        )

        let store = ProjectStore(defaults: defaults)
        let serverA = UUID()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_100)

        let p1 = try store.createProject(name: "P1", serverId: serverA, initialDirectory: "~/repo/master/", now: t1)
        let p2 = try store.createProject(name: "P2", serverId: serverA, initialDirectory: "/Users/demo/repo/master", now: t2)

        store.updateHomePath("/Users/demo", forServerId: serverA)
        XCTAssertEqual(store.homePath(for: serverA), "/Users/demo")

        let p1After = try XCTUnwrap(store.project(id: p1.id, forServerId: serverA))
        let p2After = try XCTUnwrap(store.project(id: p2.id, forServerId: serverA))
        XCTAssertTrue(p1After.directories.isEmpty, "Older P1 must lose duplicate directory on homePath convergence")
        XCTAssertEqual(p2After.directories, ["/Users/demo/repo/master"], "Newer P2 must keep canonical path")

        // Both raw paths resolve to P2
        XCTAssertEqual(store.project(forPath: "~/repo/master/", serverId: serverA)?.id, p2.id)
        XCTAssertEqual(store.project(forPath: "/Users/demo/repo/master", serverId: serverA)?.id, p2.id)
    }

    // MARK: - W2-AC-304: Pre-search disambiguation universe, root fallback, No Folder boundary

    func testW2AC304_DisplayDisambiguationAndNoFolderBoundary() throws {
        let store = ProjectStore(defaults: defaults)
        let serverA = UUID()
        let solo = try store.createProject(name: "Solo", serverId: serverA, initialDirectory: "/p/solo")
        let multi = try store.createProject(name: "Multi", serverId: serverA, initialDirectory: "/p/x/master")
        try store.bindDirectory("/p/y/master", toProjectId: multi.id, serverId: serverA)

        let projects = store.projects(for: serverA)
        let summaries = [
            ACPClientSessionSummary(id: "s1", title: "Solo", cwd: "/p/solo", updatedAt: nil),
            ACPClientSessionSummary(id: "s2", title: "Unassigned1", cwd: "/u/demo-app/master", updatedAt: nil),
        ]
        // Include zero-session directory in usedWorkingDirectories
        let universe = SessionListProjection.unassignedDirectoryUniverse(
            summaries: summaries,
            usedWorkingDirectories: ["/u/other/master"],
            serverDefaultDirectory: nil,
            projects: projects,
            homePath: nil
        )

        // 1. Solo project: card shows name only, project group hides dir row
        let soloCard = ProjectDisplayResolver.cardDisplayForTimeList(
            rawPath: "/p/solo", serverDefaultDirectory: nil, serverId: serverA,
            projects: projects, homePath: nil, unassignedUniverse: universe
        )
        XCTAssertEqual(soloCard, .project(name: "Solo", directoryShortName: nil))
        XCTAssertNil(
            ProjectDisplayResolver.cardDisplayForProjectGroup(
                rawPath: "/p/solo", serverDefaultDirectory: nil,
                groupKey: .project(serverId: serverA, projectId: solo.id),
                projects: projects, homePath: nil
            )
        )

        // 2. Multi-directory project: card shows "Multi" + disambiguated short name
        let multiX = ProjectDisplayResolver.cardDisplayForTimeList(
            rawPath: "/p/x/master", serverDefaultDirectory: nil, serverId: serverA,
            projects: projects, homePath: nil, unassignedUniverse: universe
        )
        let multiY = ProjectDisplayResolver.cardDisplayForTimeList(
            rawPath: "/p/y/master", serverDefaultDirectory: nil, serverId: serverA,
            projects: projects, homePath: nil, unassignedUniverse: universe
        )
        XCTAssertEqual(multiX, .project(name: "Multi", directoryShortName: "x/master"))
        XCTAssertEqual(multiY, .project(name: "Multi", directoryShortName: "y/master"))

        // 3. Unassigned disambiguation uses pre-search universe (even when searching only matches s2)
        let unassignedCard = ProjectDisplayResolver.cardDisplayForTimeList(
            rawPath: "/u/demo-app/master", serverDefaultDirectory: nil, serverId: serverA,
            projects: projects, homePath: nil, unassignedUniverse: universe
        )
        XCTAssertEqual(unassignedCard, .unassignedDirectory(label: "demo-app/master"))

        // Root penetration fallback: "/master" vs "/a/master"
        let rootDisambig = ProjectDisplayResolver.disambiguatedDirectoryNames(for: ["/master", "/a/master"])
        XCTAssertEqual(rootDisambig["/master"], "/master")
        XCTAssertEqual(rootDisambig["/a/master"], "a/master")

        // 4. Empty cwd: falls back to serverDefaultDirectory if present; otherwise empty ("No Folder") & never bound to project
        XCTAssertEqual(
            ProjectDisplayResolver.resolveEffectivePath(cwd: nil, serverDefaultDirectory: "/p/solo", homePath: nil),
            "/p/solo"
        )
        XCTAssertEqual(
            ProjectDisplayResolver.resolveEffectivePath(cwd: nil, serverDefaultDirectory: nil, homePath: nil),
            ""
        )
        XCTAssertNil(store.project(forPath: "", serverId: serverA))
        XCTAssertEqual(
            ProjectDisplayResolver.groupTitle(
                for: .folder(serverId: serverA, path: ""),
                projects: projects,
                homePath: nil,
                unassignedUniverse: universe,
                noFolderTitle: "No Folder"
            ),
            "No Folder"
        )
    }

    // MARK: - W2-AC-305: Multi-directory project grouping, empty project visibility, live rename resolution

    func testW2AC305_ProjectGroupingEmptyProjectAndLiveRename() throws {
        let store = ProjectStore(defaults: defaults)
        let serverA = UUID()
        let multi = try store.createProject(name: "Multi", serverId: serverA, initialDirectory: "/p/d1")
        try store.bindDirectory("/p/d2", toProjectId: multi.id, serverId: serverA)
        let emptyProj = try store.createProject(name: "EmptyProj", serverId: serverA)

        let now = Date()
        let s1 = ACPClientSessionSummary(id: "s1", title: "Old", cwd: "/p/d1", updatedAt: now.addingTimeInterval(-60))
        let s2 = ACPClientSessionSummary(id: "s2", title: "New", cwd: "/p/d2", updatedAt: now)
        let s3 = ACPClientSessionSummary(id: "s3", title: "Free", cwd: "/p/free", updatedAt: now.addingTimeInterval(-30))

        let groups = SessionListProjection.groupByProject(
            serverInputs: [(
                serverId: serverA,
                serverName: "SrvA",
                defaultDirectory: nil,
                homePath: nil,
                projects: store.projects(for: serverA),
                unassignedUniverse: ["/p/free"],
                summaries: [s1, s2, s3],
                statusProvider: { _ in .read }
            )]
        )

        // EmptyProj does not occupy home group
        XCTAssertFalse(groups.contains { $0.group.projectId == emptyProj.id })
        // EmptyProj is still listed in store.projects(for:) for NewSessionSheet and can be deleted
        XCTAssertTrue(store.projects(for: serverA).contains { $0.id == emptyProj.id })
        store.deleteProject(id: emptyProj.id, serverId: serverA)
        XCTAssertFalse(store.projects(for: serverA).contains { $0.id == emptyProj.id })

        // Multi aggregates s2 (newer) then s1 (older) with zero duplicates
        let multiGroup = try XCTUnwrap(groups.first { $0.group.key == .project(serverId: serverA, projectId: multi.id) })
        XCTAssertEqual(multiGroup.sessions.map(\.sessionId), ["s2", "s1"])

        // Live rename resolves via SessionGroupKey
        try store.renameProject(id: multi.id, to: "MultiV2", serverId: serverA)
        let liveTitle = ProjectDisplayResolver.groupTitle(
            for: .project(serverId: serverA, projectId: multi.id),
            projects: store.projects(for: serverA),
            homePath: nil,
            unassignedUniverse: [],
            noFolderTitle: "No Folder"
        )
        XCTAssertEqual(liveTitle, "MultiV2")
    }

    // MARK: - W2-AC-306: Delete project NEVER deletes sessions or triggers remote RPC; sortedDirectories MRU

    func testW2AC306_DeleteProjectPreservesSessionsAndZeroRemoteCalls() throws {
        let store = ProjectStore(defaults: defaults)
        let serverA = UUID()
        let multi = try store.createProject(name: "Multi", serverId: serverA, initialDirectory: "/p/d1")
        try store.bindDirectory("/p/d2", toProjectId: multi.id, serverId: serverA)

        // Check MRU directory ordering for multi-dir '+' menu
        let now = Date()
        let summaries = [
            ACPClientSessionSummary(id: "s1", title: "One", cwd: "/p/d1", updatedAt: now.addingTimeInterval(-120)),
            ACPClientSessionSummary(id: "s2", title: "Two", cwd: "/p/d2", updatedAt: now),
            ACPClientSessionSummary(id: "s3", title: "Three", cwd: "/p/d2", updatedAt: now.addingTimeInterval(-30)),
        ]
        let sortedDirs = store.sortedDirectories(
            for: store.project(id: multi.id, forServerId: serverA)!,
            recentDirectories: ["/p/d2", "/p/d1"]
        )
        XCTAssertEqual(sortedDirs, ["/p/d2", "/p/d1"], "Multi-dir '+' menu must order directories by most recently used")

        // Delete project: zero sessions removed, zero remote RPCs, sessions fall back to unassigned directories
        let remoteDeleteCalls = 0
        store.deleteProject(id: multi.id, serverId: serverA)
        XCTAssertEqual(remoteDeleteCalls, 0)
        XCTAssertNil(store.project(id: multi.id, forServerId: serverA))

        let groupsAfter = SessionListProjection.groupByProject(
            serverInputs: [(
                serverId: serverA,
                serverName: "SrvA",
                defaultDirectory: nil,
                homePath: nil,
                projects: store.projects(for: serverA),
                unassignedUniverse: ["/p/d1", "/p/d2"],
                summaries: summaries,
                statusProvider: { _ in .read }
            )]
        )
        let totalSessionsAfter = groupsAfter.reduce(0) { $0 + $1.sessions.count }
        XCTAssertEqual(totalSessionsAfter, 3, "Deleting a project must preserve all 3 sessions")
        XCTAssertTrue(groupsAfter.allSatisfy { !$0.group.isProject }, "Sessions must smoothly fall back to unassigned directories")
    }
}
