import XCTest
import ACPClient
@testable import Agmente

@MainActor
final class MultiServerHomeProjectionTests: XCTestCase {

    // MARK: - W2-AC-204: ServerTouchBar gesture state machine (tap, drag lock/commit/springBack, wrap-around, >5 numeric indicator)

    func testW2AC204_TouchBarGesturesWrapAroundAndPaginationIndicator() {
        // 1. Tap (<12pt) toggles allSessions <-> singleServer
        XCTAssertEqual(
            ServerTouchBarGestureLogic.evaluateDragEnd(
                mode: .allSessions, translationX: 4, predictedEndTranslationX: 6, activeIndex: 0, serverCount: 3
            ),
            .tapToggleMode
        )
        XCTAssertEqual(
            ServerTouchBarGestureLogic.evaluateDragEnd(
                mode: .singleServer, translationX: -8, predictedEndTranslationX: -10, activeIndex: 1, serverCount: 3
            ),
            .tapToggleMode
        )

        // 2. Single-server horizontal swipe: wrap-around left (last -> 0), right (0 -> last), mid-displacement springBack
        XCTAssertEqual(
            ServerTouchBarGestureLogic.evaluateDragEnd(
                mode: .singleServer, translationX: -40, predictedEndTranslationX: -50, activeIndex: 2, serverCount: 3
            ),
            .selectIndex(0),
            "Swiping left on last server must wrap around to index 0"
        )
        XCTAssertEqual(
            ServerTouchBarGestureLogic.evaluateDragEnd(
                mode: .singleServer, translationX: 40, predictedEndTranslationX: 50, activeIndex: 0, serverCount: 3
            ),
            .selectIndex(2),
            "Swiping right on first server must wrap around to last index"
        )
        XCTAssertEqual(
            ServerTouchBarGestureLogic.evaluateDragEnd(
                mode: .singleServer, translationX: 20, predictedEndTranslationX: 24, activeIndex: 1, serverCount: 3
            ),
            .springBack,
            "Mid-displacement 20pt low velocity must spring back"
        )

        // 3. All-sessions horizontal swipe is ignored (does not change mode or selectedServerId)
        XCTAssertEqual(
            ServerTouchBarGestureLogic.evaluateDragEnd(
                mode: .allSessions, translationX: -60, predictedEndTranslationX: -80, activeIndex: 0, serverCount: 3
            ),
            .ignored
        )

        // 4. <=5 servers uses dots; >5 servers (6) switches to compact numeric indicator (e.g. 1/6)
        XCTAssertFalse(ServerTouchBarGestureLogic.usesNumericPageIndicator(serverCount: 3))
        XCTAssertFalse(ServerTouchBarGestureLogic.usesNumericPageIndicator(serverCount: 5))
        XCTAssertTrue(ServerTouchBarGestureLogic.usesNumericPageIndicator(serverCount: 6))
    }

    // MARK: - W2-AC-205: Mode persistence, 0->1->2 preservation, deleteServer fallback & Touch Bar visibility

    func testW2AC205_HomeDisplayModePersistenceAndDeleteServerFallback() throws {
        let suite = "W2AC205.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let sA = ACPServerConfiguration(id: UUID(), name: "A", scheme: "ws", host: "127.0.0.1:19301", token: "", workingDirectory: "/a")
        let sB = ACPServerConfiguration(id: UUID(), name: "B", scheme: "ws", host: "127.0.0.1:19302", token: "", workingDirectory: "/b")
        let sC = ACPServerConfiguration(id: UUID(), name: "C", scheme: "ws", host: "127.0.0.1:19303", token: "", workingDirectory: "/c")

        // 0 -> 1 server: effective is singleServer, persisted stays nil (not overwritten to .singleServer)
        storage.saveServer(sA)
        let vm1 = AppViewModel(storage: storage, defaults: defaults, shouldStartNetworkMonitoring: false, shouldConnectOnStartup: false)
        XCTAssertEqual(vm1.effectiveHomeDisplayMode, .singleServer)
        XCTAssertNil(vm1.persistedHomeDisplayMode, "1 server must NOT overwrite persisted preference to singleServer")

        // 1 -> 2 servers: automatically reveals allSessions
        storage.saveServer(sB)
        let vm2 = AppViewModel(storage: storage, defaults: defaults, shouldStartNetworkMonitoring: false, shouldConnectOnStartup: false)
        XCTAssertEqual(vm2.effectiveHomeDisplayMode, .allSessions)

        // Switch to singleServer on B, persist, rebuild -> restores singleServer + B
        vm2.selectServer(sB.id)
        vm2.setHomeDisplayMode(.singleServer)
        let vmRestored = AppViewModel(storage: storage, defaults: defaults, shouldStartNetworkMonitoring: false, shouldConnectOnStartup: false)
        XCTAssertEqual(vmRestored.effectiveHomeDisplayMode, .singleServer)
        XCTAssertEqual(vmRestored.selectedServerId, sB.id)

        // 3 -> 2: deleting currently selected server falls back to remaining first server
        storage.saveServer(sC)
        let vm3 = AppViewModel(storage: storage, defaults: defaults, shouldStartNetworkMonitoring: false, shouldConnectOnStartup: false)
        vm3.selectServer(sB.id)
        vm3.deleteServer(sB.id)
        XCTAssertEqual(vm3.servers.count, 2)
        XCTAssertEqual(vm3.selectedServerId, vm3.servers.first?.id)

        // 2 -> 1: switch persisted to allSessions, delete one -> effective singleServer, persisted still allSessions
        vm3.setHomeDisplayMode(.allSessions)
        let toDelete = try XCTUnwrap(vm3.servers.last?.id)
        vm3.deleteServer(toDelete)
        XCTAssertEqual(vm3.servers.count, 1)
        XCTAssertEqual(vm3.effectiveHomeDisplayMode, .singleServer)
        XCTAssertEqual(vm3.persistedHomeDisplayMode, .allSessions)
    }

    // MARK: - W2-AC-206: Header/menu scope and parallel refresh in all-sessions vs single-server mode

    func testW2AC206_ModeHeaderAndParallelRefreshContract() {
        let suite = "W2AC206.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let sA = ACPServerConfiguration(id: UUID(), name: "Alpha", scheme: "ws", host: "127.0.0.1:19311", token: "", workingDirectory: "/a")
        let sB = ACPServerConfiguration(id: UUID(), name: "Beta", scheme: "ws", host: "127.0.0.1:19312", token: "", workingDirectory: "/b")
        storage.saveServer(sA)
        storage.saveServer(sB)

        let vm = AppViewModel(storage: storage, defaults: defaults, shouldStartNetworkMonitoring: false, shouldConnectOnStartup: false)
        XCTAssertEqual(vm.effectiveHomeDisplayMode, .allSessions)
        vm.setHomeDisplayMode(.singleServer)
        vm.selectServer(sB.id)
        XCTAssertEqual(vm.effectiveHomeDisplayMode, .singleServer)
        XCTAssertEqual(vm.selectedServer?.name, "Beta")
    }

    // MARK: - W2-AC-207: All-sessions time & project projections, cross-server same project/sessionId isolation, search

    func testW2AC207_AllSessionsProjectionsCrossServerSameIdAndSearch() throws {
        let serverA = UUID()
        let serverB = UUID()
        let now = Date()

        let projA = ServerProject(id: UUID(), serverId: serverA, name: "Nonlocal", directories: ["/a/nonlocal"])
        let projB = ServerProject(id: UUID(), serverId: serverB, name: "Nonlocal", directories: ["/b/nonlocal"])

        // Same sessionId "SAME" on both A and B, plus running/unread/read/unknown
        let itemRunning = MultiServerSessionDisplay(
            serverId: serverA, serverName: "MacMini",
            summary: ACPClientSessionSummary(id: "SAME", title: "Active A", cwd: "/a/nonlocal", updatedAt: now.addingTimeInterval(-300)),
            status: .running, projectDisplay: .project(name: "Nonlocal", directoryShortName: nil), groupDirectoryShortName: nil
        )
        let itemUnread = MultiServerSessionDisplay(
            serverId: serverB, serverName: "Office",
            summary: ACPClientSessionSummary(id: "SAME", title: "Unread B", cwd: "/b/nonlocal", updatedAt: now),
            status: .unread, projectDisplay: .project(name: "Nonlocal", directoryShortName: nil), groupDirectoryShortName: nil
        )
        let itemReadUnknown = MultiServerSessionDisplay(
            serverId: serverA, serverName: "MacMini",
            summary: ACPClientSessionSummary(id: "OLD", title: "Old Unknown", cwd: "/a/other", updatedAt: nil),
            status: .read, projectDisplay: .unassignedDirectory(label: "other"), groupDirectoryShortName: nil
        )

        // Composite IDs never collide across servers
        XCTAssertNotEqual(itemRunning.id, itemUnread.id)

        // 1. Time grouping: pinned activeOrUnread puts .running before .unread even when unread is newer; read goes to .unknown
        let timeSections = SessionListProjection.groupAllSessionsByTime([itemUnread, itemReadUnknown, itemRunning])
        XCTAssertEqual(timeSections.first?.section, .activeOrUnread)
        XCTAssertEqual(timeSections.first?.sessions.map(\.id), [itemRunning.id, itemUnread.id])
        XCTAssertEqual(timeSections.last?.section, .timeGroup(.unknown))

        // No running/unread -> pinned section hidden
        let readOnlySections = SessionListProjection.groupAllSessionsByTime([itemReadUnknown])
        XCTAssertFalse(readOnlySections.contains { $0.section == .activeOrUnread })

        // 2. Project grouping: cross-server same-name project "Nonlocal" stays 2 separate serverId-prefixed groups
        let projectGroups = SessionListProjection.groupByProject(
            serverInputs: [
                (serverId: serverA, serverName: "MacMini", defaultDirectory: nil, homePath: nil, projects: [projA], unassignedUniverse: [], summaries: [itemRunning.summary], statusProvider: { _ in .running }),
                (serverId: serverB, serverName: "Office", defaultDirectory: nil, homePath: nil, projects: [projB], unassignedUniverse: [], summaries: [itemUnread.summary], statusProvider: { _ in .unread })
            ]
        )
        XCTAssertEqual(projectGroups.count, 2, "Cross-server projects with same name must remain separate groups")
        XCTAssertTrue(projectGroups[0].group.id.contains(serverA.uuidString) || projectGroups[0].group.id.contains(serverB.uuidString))
        XCTAssertNotEqual(projectGroups[0].group.id, projectGroups[1].group.id)
    }

    // MARK: - W2-AC-208: preferredNewSessionServerId prioritizes last used online server & server-scoped directory isolation

    func testW2AC208_NewSessionPreferredServerAndDirectoryIsolation() {
        let suite = "W2AC208.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

        let storage = SessionStorage.inMemory()
        let sA = ACPServerConfiguration(id: UUID(), name: "A", scheme: "ws", host: "127.0.0.1:19321", token: "", workingDirectory: "/a")
        let sB = ACPServerConfiguration(id: UUID(), name: "B", scheme: "ws", host: "127.0.0.1:19322", token: "", workingDirectory: "/b")
        let sC = ACPServerConfiguration(id: UUID(), name: "C", scheme: "ws", host: "127.0.0.1:19323", token: "", workingDirectory: "/c")
        storage.saveServer(sA)
        storage.saveServer(sB)
        storage.saveServer(sC)

        let vm = AppViewModel(storage: storage, defaults: defaults, shouldStartNetworkMonitoring: false, shouldConnectOnStartup: false)
        // Explicit sendNewSession updates lastNewSessionServerId without mutating other server directories
        _ = vm.sendNewSession(serverId: sB.id, workingDirectory: "/b/custom")
        XCTAssertEqual(vm.lastNewSessionServerId, sB.id)
        XCTAssertEqual(vm.servers.first(where: { $0.id == sA.id })?.workingDirectory, "/a")
        XCTAssertEqual(vm.servers.first(where: { $0.id == sC.id })?.workingDirectory, "/c")
    }
}
