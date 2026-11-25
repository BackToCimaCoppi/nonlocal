import XCTest

final class Wave2UITests: XCTestCase {
    private var env: [String: String] { ProcessInfo.processInfo.environment }
    private var ctrlURL: String { env["AGMENTE_W2_CTRL_URL"] ?? "" }
    private var hostA: String { env["AGMENTE_W2_HOST_A"] ?? "" }
    private var tokenA: String { env["AGMENTE_W2_TOKEN_A"] ?? "" }
    private var cwdA: String { env["AGMENTE_W2_CWD_A"] ?? "/tmp" }
    private var hostB: String { env["AGMENTE_W2_HOST_B"] ?? "" }
    private var tokenB: String { env["AGMENTE_W2_TOKEN_B"] ?? "" }
    private var cwdB: String { env["AGMENTE_W2_CWD_B"] ?? "/tmp" }
    private var nonBridgeHost: String { env["AGMENTE_W2_NON_BRIDGE_HOST"] ?? "" }
    private var tmpDir: String { env["AGMENTE_W2_TMP_DIR"] ?? NSTemporaryDirectory() }

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(ctrlURL.isEmpty, "Wave2UITests requires AGMENTE_W2_* environment variables against isolated nonlocal-bridge instances")
    }

    // MARK: - Helpers

    private func captureScreenshot(_ filename: String) {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        if let url = URL(string: "\(ctrlURL)/capture-named-screenshot?name=\(filename)") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req) { data, resp, _ in
                if let http = resp as? HTTPURLResponse, http.statusCode == 200, data != nil {
                    ok = true
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 15)
        }
        XCTAssertTrue(ok, "Failed to capture screenshot \(filename)")
    }

    private func setFailureMode(_ enabled: Bool) {
        let sem = DispatchSemaphore(value: 0)
        if let url = URL(string: "\(ctrlURL)/inject-failure-mode?enabled=\(enabled ? "1" : "0")") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req) { _, _, _ in sem.signal() }.resume()
            _ = sem.wait(timeout: .now() + 5)
        }
    }

    private func verifyBridgeBDeleted(_ sessionId: String) -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var resultOk = false
        if let url = URL(string: "\(ctrlURL)/verify-b-deleted?sessionId=\(sessionId)") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req) { data, _, _ in
                if let data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ok = obj["ok"] as? Bool {
                    resultOk = ok
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 10)
        }
        return resultOk
    }

    private func writeSeedJSON(_ dict: [String: Any], name: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: dict, options: [])
        return data.base64EncodedString()
    }

    private func tapMenuButton(in app: XCUIApplication, identifier: String, labels: [String]) {
        let byId = app.buttons[identifier].firstMatch
        if byId.waitForExistence(timeout: 3) {
            byId.tap()
            return
        }
        for lbl in labels {
            let byLbl = app.buttons[lbl].firstMatch
            if byLbl.exists {
                byLbl.tap()
                return
            }
        }
        // Fallback: tap menu item by predicate
        let pred = NSPredicate(format: "label IN %@", labels)
        let match = app.descendants(matching: .any).matching(pred).firstMatch
        XCTAssertTrue(match.waitForExistence(timeout: 5), "Expected menu item \(identifier) / \(labels)")
        match.tap()
    }

    private func tapTopRightMoreMenu(in app: XCUIApplication) {
        let moreBtn = app.buttons["moreMenuButton"].firstMatch
        if moreBtn.waitForExistence(timeout: 8) {
            moreBtn.tap()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.905, dy: 0.095)).tap()
        }
    }

    private func launchApp(language: String = "en", seedPath: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(\(language))"]
        if let seedPath {
            app.launchEnvironment["W2_SEED_B64"] = seedPath
        }
        addUIInterruptionMonitor(withDescription: "System Dialog") { alert in
            for title in ["Allow", "OK", "Continue", "允许", "Erlauben", "Weiter", "Allow Full Access"] {
                let btn = alert.buttons[title]
                if btn.exists { btn.tap(); return true }
            }
            return false
        }
        app.launch()
        return app
    }

    // MARK: - W2-CASE-UI-01 (W2-AC-601..604): 0/1/3/6 servers, Touch Bar, menu scope, search hide

    func testW2CaseUI01_HomeEmptySingleMultiTouchBarAndMenu() throws {
        // STEP-01: 0-server empty state -> w2-ui-01-empty.png (W2-AC-601)
        let emptySeed = try writeSeedJSON(["servers": []], name: "seed-empty.json")
        let app0 = launchApp(language: "en", seedPath: emptySeed)
        XCTAssertTrue(app0.buttons["emptyStateAddServerButton"].waitForExistence(timeout: 15))
        XCTAssertTrue(app0.staticTexts["Nonlocal"].exists, "W2-AC-601: Empty state brand must be Nonlocal")
        XCTAssertFalse(app0.staticTexts["Agmente"].exists, "W2-AC-601: Must not show legacy Agmente")
        XCTAssertFalse(app0.staticTexts["/aɡˈmen.te/"].exists)
        captureScreenshot("w2-ui-01-empty.png")
        app0.terminate()

        // 1-server single mode -> summaryCard visible, serverTouchBar hidden -> w2-ui-02-single-1server.png
        let singleSeed = try writeSeedJSON([
            "homeDisplayMode": "allSessions",
            "servers": [[
                "name": "MacMini",
                "scheme": "ws",
                "host": hostA,
                "token": tokenA,
                "workingDirectory": cwdA,
                "sessions": [
                    ["sessionId": "S_A_MAIN", "title": "Alpha Main Session", "cwd": cwdA, "updatedAtOffsetSeconds": -30]
                ]
            ]]
        ], name: "seed-1server.json")
        let app1 = launchApp(language: "en", seedPath: singleSeed)
        XCTAssertTrue(app1.buttons["newSessionButton"].waitForExistence(timeout: 15))
        XCTAssertFalse(app1.descendants(matching: .any).matching(identifier: "serverTouchBar").firstMatch.exists, "W2-AC-601: Touch Bar must be hidden with 1 server")
        captureScreenshot("w2-ui-02-single-1server.png")
        app1.terminate()

        // STEP-02 & 03 & 04: 3 servers (A online, B online w/ unread & multi-dir project & unassigned, C offline)
        let threeSeed = try writeSeedJSON([
            "homeDisplayMode": "allSessions",
            "selectedServerIndex": 0,
            "servers": [
                [
                    "name": "MacMini",
                    "scheme": "ws",
                    "host": hostA,
                    "token": tokenA,
                    "workingDirectory": cwdA,
                    "projects": [["name": "Nonlocal", "directories": [cwdA]]],
                    "sessions": [
                        ["sessionId": "S_A_MAIN", "title": "Alpha Main Session", "cwd": cwdA, "updatedAtOffsetSeconds": -20],
                        ["sessionId": "S_A_READ", "title": "Older Alpha Session", "cwd": cwdA, "updatedAtOffsetSeconds": -7200]
                    ]
                ],
                [
                    "name": "OfficeMac",
                    "scheme": "ws",
                    "host": hostB,
                    "token": tokenB,
                    "workingDirectory": cwdB,
                    "projects": [["name": "Nonlocal", "directories": [cwdB, "/u/nonlocal/wave2"]]],
                    "sessions": [
                        ["sessionId": "S_B_UNREAD", "title": "Unread Update B", "cwd": cwdB, "updatedAtOffsetSeconds": -10, "isUnread": true],
                        ["sessionId": "S_B_MORE1", "title": "Unassigned Master", "cwd": "/u/demo-app/master", "updatedAtOffsetSeconds": -1800]
                    ]
                ],
                [
                    "name": "OfflineBox",
                    "scheme": "ws",
                    "host": "127.0.0.1:19999",
                    "token": "",
                    "workingDirectory": "/offline",
                    "sessions": []
                ]
            ]
        ], name: "seed-3servers.json")
        let app3 = launchApp(language: "en", seedPath: threeSeed)
        let touchBar = app3.descendants(matching: .any).matching(identifier: "serverTouchBar").firstMatch
        XCTAssertTrue(touchBar.waitForExistence(timeout: 15), "W2-AC-602: serverTouchBar must be visible with 3 servers")
        sleep(2)
        // W2-AC-602: All Sessions by time -> w2-ui-03-all-time.png
        captureScreenshot("w2-ui-03-all-time.png")

        // Verify moreMenuButton hides single-server edit/delete/disconnect in All Sessions mode
        let moreBtn = app3.buttons["moreMenuButton"]
        if moreBtn.waitForExistence(timeout: 5) {
            moreBtn.tap()
            XCTAssertTrue(app3.buttons["addACPServerMenuAction"].waitForExistence(timeout: 4))
            // Dismiss menu
            app3.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        }

        // STEP-03: Toggle grouping -> All Sessions by project -> w2-ui-04-all-project.png (W2-AC-603)
        let groupToggle = app3.buttons["sessionGroupingToggle"]
        if groupToggle.waitForExistence(timeout: 8) {
            groupToggle.tap()
            sleep(1)
        }
        captureScreenshot("w2-ui-04-all-project.png")

        // STEP-04: Swipe in allSessions (ignored), then tap to enter singleServer -> w2-ui-05-single-touchbar.png (W2-AC-604)
        touchBar.swipeLeft()
        sleep(1)
        touchBar.tap()
        sleep(1)
        captureScreenshot("w2-ui-05-single-touchbar.png")

        // Swipe 3 times for wrap-around A -> B -> C -> A
        touchBar.swipeLeft()
        usleep(400_000)
        touchBar.swipeLeft()
        usleep(400_000)
        touchBar.swipeLeft()
        usleep(400_000)

        // Activate search bar -> serverTouchBar hides -> w2-ui-06-search-hide.png
        let searchField = app3.searchFields.firstMatch
        if searchField.waitForExistence(timeout: 5) {
            searchField.tap()
            sleep(1)
        }
        captureScreenshot("w2-ui-06-search-hide.png")
        app3.terminate()

        // 6 servers in singleServer mode -> compact numeric page counter (1/6) -> w2-ui-07-6servers-counter.png
        var sixServers: [[String: Any]] = []
        for idx in 1...6 {
            sixServers.append([
                "name": "Server \(idx)",
                "scheme": "ws",
                "host": idx == 1 ? hostA : "127.0.0.1:\(19990 + idx)",
                "token": idx == 1 ? tokenA : "",
                "workingDirectory": idx == 1 ? cwdA : "/srv\(idx)",
                "sessions": idx == 1 ? [["sessionId": "S_A_MAIN", "title": "Alpha Main", "cwd": cwdA, "updatedAtOffsetSeconds": -60]] : []
            ])
        }
        let sixSeed = try writeSeedJSON([
            "homeDisplayMode": "singleServer",
            "selectedServerIndex": 0,
            "servers": sixServers
        ], name: "seed-6servers.json")
        let app6 = launchApp(language: "en", seedPath: sixSeed)
        XCTAssertTrue(app6.descendants(matching: .any).matching(identifier: "serverTouchBar").firstMatch.waitForExistence(timeout: 15))
        sleep(1)
        captureScreenshot("w2-ui-07-6servers-counter.png")
        app6.terminate()
    }

    // MARK: - W2-CASE-UI-02 (W2-AC-605..607): Native List swipe delete, FolderSessionsView, real Bridge B delete

    func testW2CaseUI02_NativeListSwipeDeleteAndCrossServerIsolation() throws {
        let seed = try writeSeedJSON([
            "homeDisplayMode": "singleServer",
            "selectedServerIndex": 1,
            "servers": [
                [
                    "name": "MacMini",
                    "scheme": "ws",
                    "host": hostA,
                    "token": tokenA,
                    "workingDirectory": cwdA,
                    "sessions": [["sessionId": "S_A_MAIN", "title": "Alpha Main Session", "cwd": cwdA, "updatedAtOffsetSeconds": -120]]
                ],
                [
                    "name": "OfficeMac",
                    "scheme": "ws",
                    "host": hostB,
                    "token": tokenB,
                    "workingDirectory": cwdB,
                    "sessions": [
                        ["sessionId": "S_DEL", "title": "Delete Target Session", "cwd": cwdB, "updatedAtOffsetSeconds": -10],
                        ["sessionId": "S_B_MORE1", "title": "Extra Folder Session 1", "cwd": cwdB, "updatedAtOffsetSeconds": -100],
                        ["sessionId": "S_B_MORE2", "title": "Extra Folder Session 2", "cwd": cwdB, "updatedAtOffsetSeconds": -200],
                        ["sessionId": "S_B_MORE3", "title": "Extra Folder Session 3", "cwd": cwdB, "updatedAtOffsetSeconds": -300],
                        ["sessionId": "S_B_MORE4", "title": "Extra Folder Session 4", "cwd": cwdB, "updatedAtOffsetSeconds": -400],
                        ["sessionId": "S_B_MORE5", "title": "Extra Folder Session 5", "cwd": cwdB, "updatedAtOffsetSeconds": -500]
                    ]
                ]
            ]
        ], name: "seed-ui02.json")

        let app = launchApp(language: "en", seedPath: seed)
        sleep(2)
        // Ensure we are on OfficeMac (index 1) and scroll slightly so S_DEL row is clearly visible
        var delRow = app.descendants(matching: .any).matching(identifier: "sessionRow_S_DEL").firstMatch
        if !delRow.waitForExistence(timeout: 8) {
            app.swipeUp()
            delRow = app.descendants(matching: .any).matching(identifier: "sessionRow_S_DEL").firstMatch
        }
        XCTAssertTrue(delRow.waitForExistence(timeout: 15), "W2-AC-605: Expected S_DEL row")
        sleep(1)

        // STEP-01: Swipe left (full swipe disabled) -> w2-ui-08-swipe-delete.png
        delRow.swipeLeft()
        sleep(1)
        captureScreenshot("w2-ui-08-swipe-delete.png")
        // Swipe right to close swipe action without deleting yet
        delRow.swipeRight()
        usleep(400_000)

        // STEP-02: Toggle to project view -> tap Show More Sessions -> FolderSessionsView -> w2-ui-09-folder-list-swipe.png (W2-AC-606)
        let groupToggle = app.buttons["sessionGroupingToggle"]
        if groupToggle.waitForExistence(timeout: 5) {
            groupToggle.tap()
            sleep(1)
        }
        let showMoreBtn = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Show More")).firstMatch
        if showMoreBtn.waitForExistence(timeout: 6) {
            showMoreBtn.tap()
            sleep(1)
            let folderRow = app.descendants(matching: .any).matching(identifier: "sessionRow_S_DEL").firstMatch
            if folderRow.waitForExistence(timeout: 6) {
                folderRow.swipeLeft()
                sleep(1)
            }
        }
        captureScreenshot("w2-ui-09-folder-list-swipe.png")

        // STEP-03: Open S_DEL detail -> tap ... menu -> acp-session-delete-button -> confirm -> verify real Bridge B disk/DB deletion (W2-AC-607)
        let backBtn = app.navigationBars.buttons.element(boundBy: 0)
        if backBtn.exists && backBtn.isHittable { backBtn.tap(); sleep(1) }
        let rowToOpen = app.descendants(matching: .any).matching(identifier: "sessionRow_S_DEL").firstMatch
        XCTAssertTrue(rowToOpen.waitForExistence(timeout: 10))
        rowToOpen.tap()
        if !app.buttons["acp-session-more-button"].waitForExistence(timeout: 5) {
            rowToOpen.tap()
        }

        let moreMenu = app.buttons["acp-session-more-button"]
        XCTAssertTrue(moreMenu.waitForExistence(timeout: 15), "W2-AC-607: Expected acp-session-more-button")
        moreMenu.tap()
        let deleteMenuBtn = app.buttons["acp-session-delete-button"]
        XCTAssertTrue(deleteMenuBtn.waitForExistence(timeout: 8), "W2-AC-607: Expected acp-session-delete-button")
        deleteMenuBtn.tap()

        let confirmDialog = app.sheets.firstMatch.waitForExistence(timeout: 5) ? app.sheets.firstMatch : app.alerts.firstMatch
        let confirmDelete = confirmDialog.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Delete")).firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 8), "W2-AC-607: Expected destructive delete confirmation dialog")
        confirmDelete.tap()

        // Wait for detail view to pop back and real Bridge B disk + 3-table SQLite cleanup
        sleep(3)
        XCTAssertTrue(verifyBridgeBDeleted("S_DEL"), "W2-AC-607: S_DEL and its 2 subagents must be deleted from Bridge B disk & SQLite")
        app.terminate()
    }

    // MARK: - W2-CASE-UI-03 (W2-AC-608..609): Unified '+' NewSessionSheet, ProjectDirectoriesSheet, multi-dir '+' menu

    func testW2CaseUI03_UnifiedNewSessionAndProjectManagement() throws {
        let seed = try writeSeedJSON([
            "homeDisplayMode": "allSessions",
            "selectedServerIndex": 0,
            "servers": [
                [
                    "name": "MacMini",
                    "scheme": "ws",
                    "host": hostA,
                    "token": tokenA,
                    "workingDirectory": cwdA,
                    "projects": [["name": "Wave2Proj", "directories": [cwdA, "/u/nonlocal/wave2"]]],
                    "sessions": [
                        ["sessionId": "S_A_MAIN", "title": "Alpha Main Session", "cwd": cwdA, "updatedAtOffsetSeconds": -20],
                        ["sessionId": "S_A_READ", "title": "Wave2 Branch Session", "cwd": "/u/nonlocal/wave2", "updatedAtOffsetSeconds": -90]
                    ]
                ],
                [
                    "name": "OfficeMac",
                    "scheme": "ws",
                    "host": hostB,
                    "token": tokenB,
                    "workingDirectory": cwdB,
                    "sessions": [
                        ["sessionId": "S_B_UNREAD", "title": "Unread Update B", "cwd": cwdB, "updatedAtOffsetSeconds": -50]
                    ]
                ]
            ]
        ], name: "seed-ui03.json")

        let app = launchApp(language: "en", seedPath: seed)
        let newBtn = app.buttons["newSessionButton"]
        XCTAssertTrue(newBtn.waitForExistence(timeout: 15))
        newBtn.tap()

        // W2-AC-608: NewSessionSheet with server picker & project picker -> w2-ui-10-new-session-sheet.png
        XCTAssertTrue(app.textFields["NewSessionWorkingDirectoryField"].waitForExistence(timeout: 8))
        sleep(1)
        captureScreenshot("w2-ui-10-new-session-sheet.png")
        let cancelBtn = app.navigationBars.buttons["Cancel"]
        if cancelBtn.exists { cancelBtn.tap() }

        // Ensure project/folder grouping is active regardless of persisted @AppStorage state
        let projectPlus = app.buttons["newSessionInProject_Wave2Proj"].firstMatch
        if !projectPlus.waitForExistence(timeout: 3) {
            let groupToggle = app.buttons["sessionGroupingToggle"]
            if groupToggle.waitForExistence(timeout: 6) {
                groupToggle.tap()
                sleep(1)
            }
        }

        // Open multi-dir '+' menu on Wave2Proj -> w2-ui-12-multi-dir-menu.png (SC-AC-064/066 hard assertion, zero dead locator)
        if !projectPlus.waitForExistence(timeout: 5) {
            app.swipeUp()
        }
        XCTAssertTrue(projectPlus.waitForExistence(timeout: 8), "SC-AC-064: Expected newSessionInProject_Wave2Proj button")
        projectPlus.tap()
        sleep(1)
        captureScreenshot("w2-ui-12-multi-dir-menu.png")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.2)).tap()
        usleep(400_000)

        // Open project manage menu -> Manage Directories -> w2-ui-11-project-dirs.png
        let manageMenu = app.buttons["folderMenu_Wave2Proj"].firstMatch
        XCTAssertTrue(manageMenu.waitForExistence(timeout: 8), "SC-AC-064: Expected folderMenu_Wave2Proj button")
        manageMenu.tap()
        let manageDirs = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Manage Directories")).firstMatch
        XCTAssertTrue(manageDirs.waitForExistence(timeout: 5), "SC-AC-064: Expected Manage Directories action in folderMenu_Wave2Proj")
        manageDirs.tap()
        sleep(1)
        captureScreenshot("w2-ui-11-project-dirs.png")
        app.terminate()
    }

    // MARK: - W2-CASE-UI-04 (W2-AC-610..611): #4b failed retry button & manual restore

    func testW2CaseUI04_FailedDeliveryRetryButtonAndManualRestore() throws {
        let seed = try writeSeedJSON([
            "homeDisplayMode": "singleServer",
            "selectedServerIndex": 0,
            "servers": [[
                "name": "MacMini",
                "scheme": "ws",
                "host": hostA,
                "token": tokenA,
                "workingDirectory": cwdA,
                "sessions": [["sessionId": "S_A_MAIN", "title": "Alpha Main Session", "cwd": cwdA, "updatedAtOffsetSeconds": -20]]
            ]]
        ], name: "seed-ui04.json")

        let app = launchApp(language: "en", seedPath: seed)
        let row = app.descendants(matching: .any).matching(identifier: "sessionRow_S_A_MAIN").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        sleep(2)
        row.tap()

        let composer = app.textViews["acp-prompt-editor"].exists ? app.textViews["acp-prompt-editor"] : app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))

        // Inject failure on Bridge A so prompt lands as failed bubble with retry button
        setFailureMode(true)
        composer.tap()
        composer.typeText("Long failed prompt message to verify left-side circular retry button placement without clipping")
        let sendBtn = app.buttons["acp-send-button"]
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 8))
        sendBtn.tap()

        // Wait for retry-failed-message-<uuid> button to appear -> w2-ui-13-failed-retry-btn.png (W2-AC-610)
        let retryBtn = app.buttons.containing(NSPredicate(format: "identifier BEGINSWITH %@", "retry-failed-message-")).firstMatch
        XCTAssertTrue(retryBtn.waitForExistence(timeout: 15), "W2-AC-610: Expected retry-failed-message-<uuid> button")
        sleep(1)
        captureScreenshot("w2-ui-13-failed-retry-btn.png")

        // Disable failure mode, type draft, tap retry button -> verify restore without auto-send -> w2-ui-14-after-retry-restore.png (W2-AC-611)
        setFailureMode(false)
        composer.tap()
        composer.typeText("Draft:")
        retryBtn.tap()
        sleep(1)
        captureScreenshot("w2-ui-14-after-retry-restore.png")
        XCTAssertFalse(retryBtn.exists, "W2-AC-611: Restoring failed delivery must remove failed bubble & retry button")

        // Manual send succeeds
        sendBtn.tap()
        sleep(2)
        app.terminate()
    }

    // MARK: - W2-CASE-UI-05 (W2-AC-612..616): German long-text full UI + Japanese fallback to English + Settings jump

    func testW2CaseUI05_LocalizationGermanLongTextAndJapaneseFallback() throws {
        // STEP-01: German empty, settings, add-server -> w2-ui-15, 17, 16 (W2-AC-612)
        let emptySeed = try writeSeedJSON(["servers": []], name: "seed-de-empty.json")
        let appDe0 = launchApp(language: "de", seedPath: emptySeed)
        XCTAssertTrue(appDe0.buttons["emptyStateAddServerButton"].waitForExistence(timeout: 15))
        XCTAssertTrue(appDe0.staticTexts["Nonlocal"].exists)
        captureScreenshot("w2-ui-15-de-empty.png")

        tapTopRightMoreMenu(in: appDe0)
        tapMenuButton(in: appDe0, identifier: "settingsMenuAction", labels: ["Einstellungen", "Settings", "设置"])
        let langBtn = appDe0.buttons["settings-language-button"]
        XCTAssertTrue(langBtn.waitForExistence(timeout: 8), "W2-AC-612: settings-language-button must exist")
        XCTAssertTrue(appDe0.staticTexts["Deutsch"].exists, "W2-AC-612: Must show Deutsch autonym")
        captureScreenshot("w2-ui-17-de-settings.png")
        appDe0.swipeDown(velocity: .fast)
        XCTAssertTrue(appDe0.buttons["emptyStateAddServerButton"].waitForExistence(timeout: 8))

        appDe0.buttons["emptyStateAddServerButton"].tap()
        sleep(1)
        captureScreenshot("w2-ui-16-de-add-server.png")
        appDe0.terminate()

        // STEP-02 & 03: German multi-server home, summaryCard, UIKit gallery & preview -> w2-ui-18, 19, 20, 21 (W2-AC-613, 614)
        let deMultiSeed = try writeSeedJSON([
            "homeDisplayMode": "allSessions",
            "selectedServerIndex": 0,
            "servers": [
                [
                    "name": "MacMini",
                    "scheme": "ws",
                    "host": hostA,
                    "token": tokenA,
                    "workingDirectory": cwdA,
                    "projects": [["name": "Nonlocal", "directories": [cwdA]]],
                    "sessions": [
                        [
                            "sessionId": "de-sess-1",
                            "title": "Deutsche Sitzung Übersicht",
                            "cwd": cwdA,
                            "updatedAtOffsetSeconds": -10,
                            "messages": [
                                [
                                    "role": "user",
                                    "content": "Bitte fasse den aktuellen Projektstatus zusammen und prüfe alle Konfigurationsdateien."
                                ],
                                [
                                    "role": "assistant",
                                    "content": "Alle acht Sprachen sind vollständig übersetzt und die Verbindung zur Nonlocal-Bridge ist stabil aktiv."
                                ]
                            ]
                        ],
                        ["sessionId": "S_A_MAIN", "title": "Alpha Main Session", "cwd": cwdA, "updatedAtOffsetSeconds": -45]
                    ]
                ],
                [
                    "name": "OfficeMac",
                    "scheme": "ws",
                    "host": hostB,
                    "token": tokenB,
                    "workingDirectory": cwdB,
                    "sessions": [
                        ["sessionId": "S_B_UNREAD", "title": "Unread Update B", "cwd": cwdB, "updatedAtOffsetSeconds": -15, "isUnread": true]
                    ]
                ]
            ]
        ], name: "seed-de-multi.json")
        let appDeMulti = launchApp(language: "de", seedPath: deMultiSeed)
        let touchBarDe = appDeMulti.descendants(matching: .any).matching(identifier: "serverTouchBar").firstMatch
        XCTAssertTrue(touchBarDe.waitForExistence(timeout: 15))
        sleep(2)
        captureScreenshot("w2-ui-18-de-multi-home.png")

        // Tap Touch Bar to singleServer -> summaryCard -> w2-ui-19-de-summary-card.png
        touchBarDe.tap()
        sleep(1)
        captureScreenshot("w2-ui-19-de-summary-card.png")

        // SC-AC-065: Open seeded non-empty German session for UIKit chat controls -> w2-ui-20-de-chat-uikit.png
        let deSessionRow = appDeMulti.descendants(matching: .any).matching(identifier: "sessionRow_de-sess-1").firstMatch
        XCTAssertTrue(deSessionRow.waitForExistence(timeout: 10), "SC-AC-065: Expected seeded German session row sessionRow_de-sess-1")
        deSessionRow.tap()
        let deComposer = appDeMulti.descendants(matching: .any).matching(identifier: "acp-prompt-editor").firstMatch
        XCTAssertTrue(deComposer.waitForExistence(timeout: 12), "SC-AC-065: Expected German chat composer inside de-sess-1")
        let deMsgPredicate = NSPredicate(format: "label CONTAINS %@", "Nonlocal-Bridge")
        XCTAssertTrue(
            appDeMulti.descendants(matching: .any).matching(deMsgPredicate).firstMatch.waitForExistence(timeout: 10),
            "SC-AC-065: Expected non-empty German assistant message rendered in de-sess-1"
        )
        sleep(1)
        captureScreenshot("w2-ui-20-de-chat-uikit.png")
        let backDe = appDeMulti.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backDe.waitForExistence(timeout: 6))
        backDe.tap()
        sleep(1)

        // Open Server Files -> README.md preview with segmented picker -> w2-ui-21-de-preview-segments.png
        let filesBtn = appDeMulti.buttons["serverCardFilesButton"]
        XCTAssertTrue(filesBtn.waitForExistence(timeout: 8), "SC-AC-064: serverCardFilesButton must exist in German single-server view")
        filesBtn.tap()
        let readmeCell = appDeMulti.staticTexts["README.md"]
        XCTAssertTrue(readmeCell.waitForExistence(timeout: 8), "SC-AC-064: README.md must appear in server file browser")
        readmeCell.tap()
        sleep(2)
        captureScreenshot("w2-ui-21-de-preview-segments.png")
        appDeMulti.terminate()

        // STEP-04 & 05: Japanese (-AppleLanguages (ja)) falls back to English + remote Chinese title intact + Settings jump & activate (W2-AC-615, 616)
        let jaSeed = try writeSeedJSON([
            "homeDisplayMode": "allSessions",
            "selectedServerIndex": 0,
            "servers": [
                [
                    "name": "MacMini",
                    "scheme": "ws",
                    "host": "127.0.0.1:19998",
                    "token": "",
                    "workingDirectory": cwdA,
                    "sessions": [
                        ["sessionId": "S_A_READ", "title": "中文标题会话 Alpha", "cwd": cwdA, "updatedAtOffsetSeconds": -120]
                    ]
                ],
                [
                    "name": "OfficeMac",
                    "scheme": "ws",
                    "host": hostB,
                    "token": tokenB,
                    "workingDirectory": cwdB,
                    "sessions": []
                ]
            ]
        ], name: "seed-ja.json")
        let appJa = launchApp(language: "ja", seedPath: jaSeed)
        XCTAssertTrue(appJa.descendants(matching: .any).matching(identifier: "serverTouchBar").firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(appJa.staticTexts["中文标题会话 Alpha"].waitForExistence(timeout: 8), "W2-AC-615: Remote Chinese title must stay intact")
        sleep(1)

        // Open Settings and verify English autonym + capture w2-ui-22-ja-fallback-en.png
        tapTopRightMoreMenu(in: appJa)
        tapMenuButton(in: appJa, identifier: "settingsMenuAction", labels: ["Settings", "Einstellungen", "设置"])
        let jaLangBtn = appJa.buttons["settings-language-button"]
        XCTAssertTrue(jaLangBtn.waitForExistence(timeout: 8), "W2-AC-615: settings-language-button must exist")
        XCTAssertTrue(appJa.staticTexts["English"].exists, "W2-AC-615: Japanese system must fall back to English autonym")
        captureScreenshot("w2-ui-22-ja-fallback-en.png")

        // STEP-05 (W2-AC-616 + AR-9): Tap settings-language-button -> Preferences -> app.activate() back to foreground
        jaLangBtn.tap()
        let prefs = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        XCTAssertTrue(prefs.wait(for: .runningForeground, timeout: 10), "W2-AC-616: Must open com.apple.Preferences")
        appJa.activate()
        XCTAssertTrue(appJa.wait(for: .runningForeground, timeout: 10), "W2-AC-616 / AR-9: Tested app must return to foreground")
        appJa.terminate()
    }

    // MARK: - AC-6: Two-stage real cold launch (selectedServerIndex: 1) + background/foreground resume with zero 4001 preemption

    private func markBridgeLogOffsets() -> Bool {
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        if let url = URL(string: "\(ctrlURL)/mark-log-offset") {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            URLSession.shared.dataTask(with: req) { data, _, _ in
                if let data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let resOk = obj["ok"] as? Bool {
                    ok = resOk
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 10)
        }
        return ok
    }

    private func assertZeroPreemptSinceMark(minInit: Int, minSync: Int) -> (ok: Bool, detail: String) {
        let sem = DispatchSemaphore(value: 0)
        var resultOk = false
        var detail = ""
        if let url = URL(string: "\(ctrlURL)/assert-zero-preempt?minInit=\(minInit)&minSync=\(minSync)") {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            URLSession.shared.dataTask(with: req) { data, _, _ in
                if let data {
                    detail = String(data: data, encoding: .utf8) ?? ""
                    if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let ok = obj["ok"] as? Bool {
                        resultOk = ok
                    }
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 10)
        }
        return (resultOk, detail)
    }

    // SC-AC-060: Two-stage real cold launch (selectedServerIndex: 1) + background/foreground resume with zero 4001 preemption
    func testW2CaseUI06_SecondServerColdLaunchAndBackgroundResumeZeroPreempt() throws {
        // Stage 1: Seed [MacMini (Bridge A), OfficeMac (Bridge B)] with selectedServerIndex = 1, persist to Core Data & UserDefaults, then terminate.
        let seed = try writeSeedJSON([
            "homeDisplayMode": "singleServer",
            "selectedServerIndex": 1,
            "servers": [
                [
                    "name": "MacMini",
                    "scheme": "ws",
                    "host": hostA,
                    "token": tokenA,
                    "workingDirectory": cwdA,
                    "sessions": [["sessionId": "S_A_MAIN", "title": "Alpha Main Session", "cwd": cwdA, "updatedAtOffsetSeconds": -120]]
                ],
                [
                    "name": "OfficeMac",
                    "scheme": "ws",
                    "host": hostB,
                    "token": tokenB,
                    "workingDirectory": cwdB,
                    "sessions": [["sessionId": "S_DEL", "title": "Delete Target Session", "cwd": cwdB, "updatedAtOffsetSeconds": -10]]
                ]
            ]
        ], name: "seed-ui06-stage1.json")

        let appStage1 = launchApp(language: "en", seedPath: seed)
        XCTAssertTrue(
            appStage1.descendants(matching: .any).matching(identifier: "serverTouchBar").firstMatch.waitForExistence(timeout: 15),
            "AC-6 Stage 1: Expected serverTouchBar after seeding [A, B]"
        )
        sleep(2)
        appStage1.terminate()
        sleep(1)

        // Record Stage-2 byte offsets on both isolated bridges after Stage 1 exits cleanly.
        XCTAssertTrue(markBridgeLogOffsets(), "AC-6: Failed to mark Stage-2 bridge log offsets")

        // Stage 2: True cold launch WITHOUT W2_SEED_B64 so AppViewModel.init(shouldConnectOnStartup: true) restores [A, B] with Server B selected.
        let appStage2 = launchApp(language: "en", seedPath: nil)
        XCTAssertTrue(
            appStage2.descendants(matching: .any).matching(identifier: "serverTouchBar").firstMatch.waitForExistence(timeout: 15),
            "AC-6 Stage 2: Expected serverTouchBar on true cold launch"
        )
        XCTAssertTrue(
            appStage2.descendants(matching: .any).matching(identifier: "homeNavigationTitle").firstMatch.label == "OfficeMac"
                || appStage2.staticTexts["OfficeMac"].waitForExistence(timeout: 8),
            "AC-6 Stage 2: Second server (OfficeMac) must remain selected on cold launch"
        )

        // Wait for both bridges to complete cold-launch initialize + nonlocal/sync with zero preemption.
        var coldCheck = (ok: false, detail: "")
        for _ in 0..<10 {
            sleep(1)
            coldCheck = assertZeroPreemptSinceMark(minInit: 1, minSync: 1)
            if coldCheck.ok { break }
        }
        XCTAssertTrue(coldCheck.ok, "AC-6 Stage 2 cold launch failed zero-preempt assertion: \(coldCheck.detail)")

        // Send app to background, wait for sockets to close cleanly, then return to foreground.
        XCUIDevice.shared.press(.home)
        sleep(2)
        appStage2.activate()
        XCTAssertTrue(appStage2.wait(for: .runningForeground, timeout: 10), "AC-6 Stage 2: App must return to foreground")

        // Wait for both bridges to complete foreground-resume initialize + nonlocal/sync with zero preemption.
        var resumeCheck = (ok: false, detail: "")
        for _ in 0..<12 {
            sleep(1)
            resumeCheck = assertZeroPreemptSinceMark(minInit: 2, minSync: 2)
            if resumeCheck.ok { break }
        }
        XCTAssertTrue(resumeCheck.ok, "AC-6 Stage 2 background->foreground failed zero-preempt assertion: \(resumeCheck.detail)")
        appStage2.terminate()
    }

    // MARK: - SC-AC-057, SC-AC-058, SC-AC-059: Non-bridge red top banner, devModeEnabled=false, background->foreground 0 reconnects, manual edit unlock

    private func getNonBridgeConnectCount() -> Int {
        let sem = DispatchSemaphore(value: 0)
        var count = -1
        if let url = URL(string: "\(ctrlURL)/non-bridge-connect-count") {
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            URLSession.shared.dataTask(with: req) { data, _, _ in
                if let data,
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let val = obj["connectCount"] as? Int {
                    count = val
                }
                sem.signal()
            }.resume()
            _ = sem.wait(timeout: .now() + 10)
        }
        return count
    }

    private func replaceFieldText(in element: XCUIElement, with value: String) {
        if element.elementType == .secureTextField {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            let existingCount = (element.value as? String)?.count ?? 0
            let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: max(existingCount + 8, 48))
            element.typeText(deletes)
        } else if let existing = element.value as? String,
                  !existing.isEmpty,
                  existing != element.placeholderValue {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            let deletes = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count + 4)
            element.typeText(deletes)
        } else {
            element.tap()
        }
        element.typeText(value)
    }

    func testNonBridgeBannerAndManualUnlockFlow() throws {
        XCTAssertFalse(nonBridgeHost.isEmpty, "SC-AC-057: Missing AGMENTE_W2_NON_BRIDGE_HOST environment variable")

        let serverAId = "11111111-1111-4111-8111-111111111111"
        let serverBId = "22222222-2222-4222-8222-222222222222"

        let seed = try writeSeedJSON([
            "homeDisplayMode": "allSessions",
            "selectedServerIndex": 0,
            "devModeEnabled": false,
            "servers": [
                [
                    "id": serverAId,
                    "name": "ServerA",
                    "scheme": "ws",
                    "host": hostA,
                    "token": tokenA,
                    "workingDirectory": cwdA,
                    "sessions": [
                        ["sessionId": "S_A_MAIN", "title": "Alpha Main Session", "cwd": cwdA, "updatedAtOffsetSeconds": -30]
                    ]
                ],
                [
                    "id": serverBId,
                    "name": "ServerB",
                    "scheme": "ws",
                    "host": nonBridgeHost,
                    "token": "stub-token-123",
                    "workingDirectory": cwdB,
                    "sessions": []
                ]
            ]
        ], name: "seed-nonbridge.json")

        let app = launchApp(language: "en", seedPath: seed)
        let touchBar = app.descendants(matching: .any).matching(identifier: "serverTouchBar").firstMatch
        XCTAssertTrue(touchBar.waitForExistence(timeout: 15), "SC-AC-057: Expected serverTouchBar")

        // STEP-01 (SC-AC-057): Wait for nonBridgeLockoutBanner & nonBridgeEditButton_<serverBId> in All Sessions mode with devModeEnabled=false
        let banner = app.descendants(matching: .any).matching(identifier: "nonBridgeLockoutBanner").firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "SC-AC-057: Expected nonBridgeLockoutBanner in All Sessions mode")
        let editBtn = app.buttons["nonBridgeEditButton_\(serverBId)"].firstMatch
        XCTAssertTrue(editBtn.waitForExistence(timeout: 8), "SC-AC-057: Expected nonBridgeEditButton_\(serverBId)")
        XCTAssertTrue(app.staticTexts["ServerB"].exists, "SC-AC-057: Banner must name ServerB in All Sessions mode")
        XCTAssertFalse(
            app.descendants(matching: .any).matching(identifier: "preemptedReconnectBanner").firstMatch.exists,
            "SC-AC-057: Orange 4001 preemptedReconnectBanner must NOT appear for protocol lockout"
        )
        XCTAssertFalse(app.buttons["devRowLogsButton"].exists, "SC-AC-057: devModeEnabled=false must hide devRowLogsButton")

        sleep(1)
        captureScreenshot("sc-ui-nonbridge-multi-banner.png")

        // Verify background -> foreground produces 0 additional dials to non-bridge stub
        let countBefore = getNonBridgeConnectCount()
        XCTAssertGreaterThanOrEqual(countBefore, 1, "SC-AC-057: Expected >=1 initial dial to non-bridge stub")

        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(3)

        let countAfter = getNonBridgeConnectCount()
        XCTAssertEqual(countAfter, countBefore, "SC-AC-057: Background->foreground must produce 0 reconnect dials to locked non-bridge stub (before=\(countBefore), after=\(countAfter))")

        // STEP-02 (SC-AC-058): Switch to single-server view -> verify ServerA stays connected (serverCardFilesButton), then swipe to ServerB
        touchBar.tap() // allSessions -> singleServer (ServerA)
        sleep(1)
        XCTAssertTrue(app.buttons["serverCardFilesButton"].waitForExistence(timeout: 10), "SC-AC-057: ServerA must stay online (.connected) while ServerB is locked")
        XCTAssertFalse(app.buttons["devRowLogsButton"].exists, "SC-AC-057/058: devModeEnabled=false confirmed in single-server view")
        touchBar.swipeLeft() // ServerA -> ServerB
        sleep(1)

        XCTAssertTrue(banner.waitForExistence(timeout: 8), "SC-AC-058: Expected nonBridgeLockoutBanner in single-server view for ServerB")
        XCTAssertTrue(editBtn.waitForExistence(timeout: 5), "SC-AC-058: Expected nonBridgeEditButton_\(serverBId) in single-server view")
        XCTAssertTrue(app.staticTexts["antigravityCardTitle"].waitForExistence(timeout: 8), "SC-AC-058: Expected antigravityCardTitle in single-server view")
        XCTAssertFalse(app.buttons["devRowLogsButton"].exists, "SC-AC-058: devRowLogsButton must remain hidden when devModeEnabled=false")
        captureScreenshot("sc-ui-nonbridge-single-banner.png")

        // STEP-03 (SC-AC-059): Switch back to ServerA -> All Sessions -> tap nonBridgeEditButton_<serverBId> -> verify ServerB form -> fix to Bridge B -> unlock
        touchBar.swipeRight() // ServerB -> ServerA (ensure selectedServerId == ServerA!)
        usleep(500_000)
        touchBar.tap() // singleServer -> allSessions (with selectedServerId == ServerA)
        sleep(1)

        XCTAssertTrue(editBtn.waitForExistence(timeout: 8), "SC-AC-059: Expected nonBridgeEditButton_\(serverBId) in All Sessions mode")
        editBtn.tap()

        let nameField = app.textFields["ServerNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8), "SC-AC-059: Expected Edit Server form")
        XCTAssertEqual(nameField.value as? String, "ServerB", "SC-AC-059: Edit form must bind to ServerB (not selected ServerA)")

        let hostField = app.textFields["HostField"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 5))
        replaceFieldText(in: hostField, with: hostB)

        let tokenField = app.secureTextFields["TokenField"].exists
            ? app.secureTextFields["TokenField"]
            : app.textFields["TokenField"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: 5))
        replaceFieldText(in: tokenField, with: tokenB)

        let saveBtn = app.buttons["saveToolbarButton"]
        XCTAssertTrue(saveBtn.waitForExistence(timeout: 5))
        saveBtn.tap()

        XCTAssertFalse(app.buttons["serverSummaryConfirmButton"].waitForExistence(timeout: 2), "SC-AC-059: Unlock save must not show serverSummaryConfirmButton")

        // Wait for nonBridgeLockoutBanner to disappear after unlocking, then verify ServerB genuinely connects to healthy Bridge B
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline && banner.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        XCTAssertFalse(banner.exists, "SC-AC-059: nonBridgeLockoutBanner must disappear after fixing ServerB to healthy Bridge B")

        // Switch to ServerB single-server view and assert serverCardFilesButton (only rendered when .connected to Bridge B!)
        touchBar.tap() // allSessions -> singleServer (ServerA)
        usleep(400_000)
        touchBar.swipeLeft() // ServerA -> ServerB
        XCTAssertTrue(
            app.buttons["serverCardFilesButton"].waitForExistence(timeout: 15),
            "SC-AC-059: ServerB must genuinely connect (.connected) to healthy Bridge B after manual edit unlock"
        )
        XCTAssertFalse(banner.exists, "SC-AC-059: nonBridgeLockoutBanner must remain absent on connected ServerB")
        app.terminate()
    }
}
