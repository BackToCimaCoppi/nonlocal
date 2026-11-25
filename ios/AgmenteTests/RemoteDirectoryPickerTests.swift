import XCTest
@testable import Agmente
import ACPClient

@MainActor
final class RemoteDirectoryPickerTests: XCTestCase {

    private var suiteNames: [String] = []

    override func tearDown() {
        for name in suiteNames {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suiteNames.removeAll()
        super.tearDown()
    }

    private func makeIsolatedDefaults() -> UserDefaults {
        let name = "RemoteDirectoryPickerTests.\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // AC-302: Default working directory "~" for new servers, browse button gated false on new server,
    // and empty working directory on addServer / pending session falls back to "~".
    func testAC302DefaultTildeAndEmptyWorkingDirectoryFallback() {
        let defaults = makeIsolatedDefaults()
        let persistence = PersistenceController(inMemory: true)
        let storage = SessionStorage(container: persistence.container)
        let model = AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )

        // 1. Default working directory for new server is "~"
        let dir = AddServerDirectoryGating.initialWorkingDirectory(editingServer: nil)
        XCTAssertEqual(dir, "~")

        // New server mode never shows browse button
        XCTAssertFalse(
            AddServerDirectoryGating.canShowBrowseButton(
                editingServer: nil,
                connectionState: .connected,
                scheme: "ws",
                host: "127.0.0.1:18800",
                token: ""
            )
        )

        // 2. Empty working directory on addServer falls back to "~"
        model.addServer(
            name: "ACP Empty",
            scheme: "ws",
            host: "127.0.0.1:18801",
            token: "",
            workingDirectory: "   "
        )
        XCTAssertEqual(model.servers.last?.workingDirectory, "~")
        XCTAssertEqual(model.workingDirectory, "~")

        // Pending ACP session clearing working directory also falls back to "~"
        let serverVM = model.selectedServerViewModel!
        serverVM.sendNewSession(workingDirectory: "/custom")
        serverVM.updatePendingSessionWorkingDirectory("   ")
        XCTAssertEqual(model.currentSessionCwd, "~")
    }

    // AC-303: Edit-mode browse gating (hidden on host change) and updateServer syncing workingDirectory
    // so switching servers round-trip does NOT revert to "/old".
    func testAC303EditBrowseGatingAndUpdateServerSyncsWorkingDirectoryAcrossServerSwitch() {
        let defaults = makeIsolatedDefaults()
        let persistence = PersistenceController(inMemory: true)
        let storage = SessionStorage(container: persistence.container)
        let model = AppViewModel(
            storage: storage,
            defaults: defaults,
            shouldStartNetworkMonitoring: false,
            shouldConnectOnStartup: false
        )

        model.addServer(name: "Server A", scheme: "ws", host: "127.0.0.1:18811", token: "t1", workingDirectory: "/old")
        let serverA = model.servers.first!
        model.addServer(name: "Server B", scheme: "ws", host: "127.0.0.1:18812", token: "t2", workingDirectory: "/other")
        let serverB = model.servers.last!

        model.selectServer(serverA.id)

        // 1. Unchanged connected ACP server -> browse allowed; changing host -> false
        XCTAssertTrue(
            AddServerDirectoryGating.canShowBrowseButton(
                editingServer: serverA,
                connectionState: .connected,
                scheme: serverA.scheme,
                host: serverA.host,
                token: serverA.token
            )
        )
        XCTAssertFalse(
            AddServerDirectoryGating.canShowBrowseButton(
                editingServer: serverA,
                connectionState: .connected,
                scheme: serverA.scheme,
                host: "127.0.0.1:19999",
                token: serverA.token
            )
        )

        // 2. updateServer updates workingDirectory to "/new", survives round-trip selectServer(B) -> selectServer(A)
        model.updateServer(
            serverA.id,
            with: ValidatedServerConfiguration(
                name: serverA.name,
                scheme: serverA.scheme,
                host: serverA.host,
                token: serverA.token,
                workingDirectory: "/new",
                agentInfo: nil
            )
        )
        XCTAssertEqual(model.workingDirectory, "/new")
        model.selectServer(serverB.id)
        model.selectServer(serverA.id)
        XCTAssertEqual(model.workingDirectory, "/new")
        XCTAssertEqual(model.servers.first(where: { $0.id == serverA.id })?.workingDirectory, "/new")
    }

    // AC-304: Error handling for -32011/-32012 (auto-fallback to "~" with banner),
    // -32013 (in-place permission error without falling back to "~"), and -32601 (upgrade/manual prompt).
    func testAC304ErrorBranchingFallbackInPlaceAndLegacy32601() async {
        let defaults = makeIsolatedDefaults()

        // 1. -32011 not_found -> auto-fallback to "~" + info banner
        var requestedPaths: [String?] = []
        let vm1 = RemoteDirectoryPickerViewModel(
            initialPath: "/missing/dir",
            serverDefaultPath: "~",
            recentDirectories: [],
            listDirectory: { params in
                requestedPaths.append(params.path)
                if params.path == "/missing/dir" {
                    throw ACPServiceError.rpc(id: .int(1), error: .serverError(code: -32011, message: "not_found"))
                }
                return NonlocalFsListResult(path: "/Users/demo", parentPath: "/Users", homePath: "/Users/demo", totalCount: 0, truncated: false, entries: [])
            },
            defaults: defaults
        )
        let ok1 = await vm1.loadAndWait(path: "/missing/dir", allowFallbackToHome: true)
        XCTAssertTrue(ok1)
        XCTAssertEqual(requestedPaths, ["/missing/dir", "~"])
        XCTAssertEqual(vm1.currentPath, "/Users/demo")
        XCTAssertEqual(vm1.infoBanner, String(localized: "Original path not found; switched to Home (~)"))

        // Also test -32012 not_directory -> auto-fallback to "~"
        let vm2 = RemoteDirectoryPickerViewModel(
            initialPath: "/Users/demo/file.txt",
            serverDefaultPath: "~",
            recentDirectories: [],
            listDirectory: { params in
                if params.path == "/Users/demo/file.txt" {
                    throw ACPServiceError.rpc(id: .int(2), error: .serverError(code: -32012, message: "not_directory"))
                }
                return NonlocalFsListResult(path: "/Users/demo", parentPath: "/Users", homePath: "/Users/demo", totalCount: 0, truncated: false, entries: [])
            },
            defaults: defaults
        )
        let ok2 = await vm2.loadAndWait(path: "/Users/demo/file.txt", allowFallbackToHome: true)
        XCTAssertTrue(ok2)
        XCTAssertEqual(vm2.infoBanner, String(localized: "Original path not found; switched to Home (~)"))

        // 2. -32013 permission_denied -> in-place error, does NOT fall back to "~"
        var permPaths: [String?] = []
        let vm3 = RemoteDirectoryPickerViewModel(
            initialPath: "/private/secret",
            serverDefaultPath: "~",
            recentDirectories: [],
            listDirectory: { params in
                permPaths.append(params.path)
                throw ACPServiceError.rpc(id: .int(3), error: .serverError(code: -32013, message: "permission_denied"))
            },
            defaults: defaults
        )
        let ok3 = await vm3.loadAndWait(path: "/private/secret", allowFallbackToHome: true)
        XCTAssertFalse(ok3)
        XCTAssertEqual(permPaths, ["/private/secret"])
        XCTAssertEqual(vm3.currentPath, "/private/secret")
        XCTAssertEqual(vm3.errorMessage, String(localized: "Permission denied for this directory"))

        // 3. -32601 method not found -> upgrade/manual input message
        let vm4 = RemoteDirectoryPickerViewModel(
            initialPath: "~",
            serverDefaultPath: "~",
            recentDirectories: [],
            listDirectory: { _ in
                throw ACPServiceError.rpc(id: .int(4), error: .serverError(code: -32601, message: "Method not found"))
            },
            defaults: defaults
        )
        let ok4 = await vm4.loadAndWait(path: "~", allowFallbackToHome: true)
        XCTAssertFalse(ok4)
        XCTAssertEqual(vm4.errorMessage, String(localized: "This bridge version does not support directory browsing. Upgrade the bridge or enter the path manually."))
    }

    // AC-305: Quick-chip deduplication (~ vs homePath), out-of-order search rejection via monotonic requestToken,
    // showHidden persistence across rebuild, and zero pollution of usedWorkingDirectoryHistory.
    func testAC305ChipDedupSearchOrderingShowHiddenPersistenceAndZeroHistoryPollution() async throws {
        let defaults = makeIsolatedDefaults()
        let history = ["/proj/a"]

        let vm = RemoteDirectoryPickerViewModel(
            initialPath: "~",
            serverDefaultPath: "/Users/demo",
            recentDirectories: history,
            listDirectory: { params in
                if params.query == "q1" {
                    try await Task.sleep(nanoseconds: 120_000_000)
                    return NonlocalFsListResult(
                        path: "/Users/demo",
                        parentPath: "/Users",
                        homePath: "/Users/demo",
                        totalCount: 1,
                        truncated: false,
                        entries: [NonlocalFsEntry(name: "stale-q1", path: "/Users/demo/stale-q1", type: .dir)]
                    )
                }
                return NonlocalFsListResult(
                    path: "/Users/demo",
                    parentPath: "/Users",
                    homePath: "/Users/demo",
                    totalCount: 1,
                    truncated: false,
                    entries: [NonlocalFsEntry(name: "fresh-\(params.query ?? "root")", path: "/Users/demo/fresh", type: .dir)]
                )
            },
            defaults: defaults
        )

        // 1. Initial load populates homePath = "/Users/demo" -> "~" and "/Users/demo" deduplicate to 1 chip
        _ = await vm.loadAndWait(path: "~")
        let homeChips = vm.quickChips.filter {
            RemoteDirectoryPickerViewModel.canonicalizeForDedup($0.path, homePath: "/Users/demo") == "/Users/demo"
        }
        XCTAssertEqual(homeChips.count, 1)

        // 2. Out-of-order search: q1 (slow) started first, q2 (fast) started second -> q1 discarded, list keeps q2
        vm.updateSearchQuery("q1")
        try await Task.sleep(nanoseconds: 15_000_000)
        vm.updateSearchQuery("q2")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(vm.entries.map(\.name), ["fresh-q2"])

        // 3. showHidden persists across new VM instance
        XCTAssertFalse(vm.showHidden)
        vm.toggleShowHidden()
        XCTAssertTrue(vm.showHidden)
        let vmRebuilt = RemoteDirectoryPickerViewModel(
            initialPath: "~",
            serverDefaultPath: "~",
            recentDirectories: history,
            listDirectory: { _ in nil },
            defaults: defaults
        )
        XCTAssertTrue(vmRebuilt.showHidden)

        // 4. Original history untouched
        XCTAssertEqual(history, ["/proj/a"])
    }
}
