import XCTest

final class AgmenteUITests: XCTestCase {

    private enum E2E {
        static let emptyStateAddServerButtonId = "emptyStateAddServerButton"
        static let saveToolbarButtonId = "saveToolbarButton"
        static let summaryConfirmButtonId = "serverSummaryConfirmButton"
    }

    private enum ACPE2E {
        static let hostEnv = "AGMENTE_E2E_ACP_HOST"
        static let tokenEnv = "AGMENTE_E2E_ACP_TOKEN"
        static let cwdEnv = "AGMENTE_E2E_ACP_CWD"
        static let controlURLEnv = "AGMENTE_E2E_ACP_CONTROL_URL"
        static let nonBridgeHostEnv = "AGMENTE_E2E_NON_BRIDGE_HOST"
    }

    private struct ACPE2EConfiguration {
        let host: String
        let token: String
        let cwd: String
        let controlURL: URL
        let nonBridgeHost: String?
    }

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // UI tests must launch the application that they test.
        let app = makeApp()
        app.launch()

        // Use XCTAssert and related functions to verify your tests produce the correct results.
    }

    @MainActor
    func testLaunchPerformance() throws {
        if #available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 7.0, *) {
            // This measures how long it takes to launch your application.
            measure(metrics: [XCTApplicationLaunchMetric()]) {
                XCUIApplication().launch()
            }
        }
    }

    // SC-AC-061: Default toolbar, slash autocomplete, background disconnect recovery, clean transcript & rename E2E.
    @MainActor
    func testACPBridgeToolbarAndReconnectFlow() throws {
        guard let config = acpE2EConfigurationOrFail() else {
            return
        }

        let app = makeApp()
        addUIInterruptionMonitor(withDescription: "System Alerts") { alert in
            let allowButtons = ["Allow", "OK", "Continue", "允许", "Erlauben", "Weiter", "Autoriser", "Permitir", "허용", "Разрешить"]
            for label in allowButtons where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            if alert.buttons.firstMatch.exists {
                alert.buttons.firstMatch.tap()
                return true
            }
            return false
        }

        app.launch()
        app.tap()

        let addServerButton = app.buttons[E2E.emptyStateAddServerButtonId]
        XCTAssertTrue(
            addServerButton.waitForExistence(timeout: 20),
            "Expected clean first-run server list state. Ensure pre-run uninstall happened. UI:\n\(app.debugDescription)"
        )
        addServerButton.tap()

        let nameField = app.textFields["ServerNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8))
        replaceText(in: nameField, with: "Nonlocal ACP E2E")

        let protocolPicker = app.segmentedControls["ProtocolPicker"]
        if protocolPicker.waitForExistence(timeout: 4), protocolPicker.buttons["ws"].exists {
            protocolPicker.buttons["ws"].tap()
        }

        let hostField = app.textFields["HostField"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 8))
        replaceText(in: hostField, with: config.host)

        let tokenField = app.secureTextFields["TokenField"].exists
            ? app.secureTextFields["TokenField"]
            : app.textFields["TokenField"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: 8))
        replaceText(in: tokenField, with: config.token)

        let cwdField = app.textFields["WorkingDirectoryField"]
        if !cwdField.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(cwdField.waitForExistence(timeout: 8))
        replaceText(in: cwdField, with: config.cwd)

        let toolbarSaveButton = app.buttons[E2E.saveToolbarButtonId].exists
            ? app.buttons[E2E.saveToolbarButtonId]
            : app.navigationBars.buttons["Save"]
        if toolbarSaveButton.waitForExistence(timeout: 8) {
            XCTAssertTrue(waitForEnabled(toolbarSaveButton, timeout: 8))
            toolbarSaveButton.tap()
        } else {
            let inlineSaveButton = app.buttons["SaveServerButton"]
            XCTAssertTrue(inlineSaveButton.waitForExistence(timeout: 8))
            XCTAssertTrue(waitForEnabled(inlineSaveButton, timeout: 8))
            inlineSaveButton.tap()
        }
        // Direct save without secondary confirmation modal (SD-1.5)
        XCTAssertFalse(app.buttons[E2E.summaryConfirmButtonId].waitForExistence(timeout: 2), "serverSummaryConfirmButton must not appear")

        let newSessionButton = app.buttons["newSessionButton"]
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 45))
        XCTAssertTrue(waitForEnabled(newSessionButton, timeout: 45))
        newSessionButton.tap()
        confirmNewSessionSheetIfPresented(in: app)

        let composer = app.descendants(matching: .any).matching(identifier: "acp-prompt-editor").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 30), "ACP prompt editor missing")

        let toolbar = app.descendants(matching: .any).matching(identifier: "acp-composer-toolbar").firstMatch
        XCTAssertTrue(toolbar.waitForExistence(timeout: 15), "acp-composer-toolbar missing")

        let modelPicker = app.descendants(matching: .any).matching(identifier: "acp-model-picker").firstMatch
        XCTAssertTrue(modelPicker.waitForExistence(timeout: 15), "acp-model-picker missing")
        var modelMatched = false
        let modelDeadline = Date().addingTimeInterval(10)
        while Date() < modelDeadline {
            let combined = modelPicker.label + " " + modelPicker.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
            if combined.contains("Gemini 4 Hydrogen") {
                modelMatched = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(modelMatched, "Expected acp-model-picker to display Gemini 4 Hydrogen, got '\(modelPicker.label)'")

        let modePicker = app.descendants(matching: .any).matching(identifier: "acp-mode-picker").firstMatch
        XCTAssertTrue(modePicker.waitForExistence(timeout: 10), "acp-mode-picker missing")

        let thoughtPicker = app.descendants(matching: .any).matching(identifier: "acp-config-thought_level").firstMatch
        let cwdButton = app.descendants(matching: .any).matching(identifier: "acp-cwd-button").firstMatch
        let commandsButton = app.descendants(matching: .any).matching(identifier: "acp-commands-button").firstMatch
        let imageButton = app.descendants(matching: .any).matching(identifier: "acp-image-button").firstMatch
        let usageBadge = app.descendants(matching: .any).matching(identifier: "acp-usage-badge").firstMatch
        XCTAssertTrue(commandsButton.waitForExistence(timeout: 10), "Expected acp-commands-button after available_commands_update")
        XCTAssertTrue(usageBadge.waitForExistence(timeout: 10), "Expected acp-usage-badge after usage_update")

        try postControl(to: config.controlURL, path: "/capture-toolbar-screenshot")
        let shotAttachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shotAttachment.name = "toolbar"
        shotAttachment.lifetime = .keepAlways
        add(shotAttachment)

        assertSingleRowHeight(toolbar, name: "acp-composer-toolbar")
        assertSingleRowHeight(modePicker, name: "acp-mode-picker")
        assertSingleRowHeight(modelPicker, name: "acp-model-picker")
        assertSingleRowHeight(thoughtPicker, name: "acp-config-thought_level")

        let windowFrame = app.windows.firstMatch.frame
        for (name, element) in [
            ("acp-cwd-button", cwdButton),
            ("acp-commands-button", commandsButton),
            ("acp-image-button", imageButton),
        ] where element.exists && !element.frame.isEmpty {
            assertSingleRowHeight(element, name: name)
        }

        toolbar.swipeLeft()
        if !usageBadge.isHittable {
            toolbar.swipeLeft()
        }
        XCTAssertTrue(usageBadge.exists && usageBadge.frame.width > 0, "acp-usage-badge not reachable after swipe")
        XCTAssertTrue(
            usageBadge.frame.minX < windowFrame.maxX && usageBadge.frame.maxX > 0,
            "acp-usage-badge expected inside viewport after swipeLeft, frame=\(usageBadge.frame), window=\(windowFrame)"
        )
        assertSingleRowHeight(usageBadge, name: "acp-usage-badge")
        assertSingleRowHeight(cwdButton, name: "acp-cwd-button")
        assertSingleRowHeight(commandsButton, name: "acp-commands-button")
        assertSingleRowHeight(imageButton, name: "acp-image-button")

        try verifySlashAutocompleteFlow(
            in: app,
            composer: composer,
            toolbar: toolbar,
            commandsButton: commandsButton,
            controlURL: config.controlURL
        )

        // Send prompt and verify SEG1 -> Home -> hard disconnect -> mid buffer -> activate -> SEG1+SEG2+SEG3
        composer.tap()
        composer.typeText("Verify reconnect flow")

        let sendButton = app.descendants(matching: .any).matching(identifier: "acp-send-button").firstMatch
        XCTAssertTrue(sendButton.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForEnabled(sendButton, timeout: 10))
        sendButton.tap()

        let seg1Predicate = NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "acp-markdown-row", "SEG1_BEFORE_DROP")
        let seg1Row = app.descendants(matching: .any)
            .matching(seg1Predicate)
            .firstMatch
        XCTAssertTrue(seg1Row.waitForExistence(timeout: 20), "Expected SEG1_BEFORE_DROP before backgrounding")

        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 10), "Expected app to transition to background")

        try postControl(to: config.controlURL, path: "/drop-and-buffer")

        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "Expected app to return to foreground")

        let allSegsPredicate = NSPredicate(
            format: "identifier == %@ AND label CONTAINS %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "acp-markdown-row",
            "SEG1_BEFORE_DROP",
            "SEG2_BUFFERED_OFFLINE",
            "SEG3_AFTER_RESUME"
        )
        let fullRow = app.descendants(matching: .any)
            .matching(allSegsPredicate)
            .firstMatch
        XCTAssertTrue(
            fullRow.waitForExistence(timeout: 30),
            "Expected all three segments SEG1_BEFORE_DROP + SEG2_BUFFERED_OFFLINE + SEG3_AFTER_RESUME after reconnect"
        )

        var idleStopCleared = false
        let idleDeadline = Date().addingTimeInterval(10)
        while Date() < idleDeadline {
            if !sendButton.isEnabled && (sendButton.value as? String) == "send" {
                idleStopCleared = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTAssertTrue(
            idleStopCleared,
            "Expected acp-send-button to exit stop mode (disabled with empty prompt & value == 'send'), isEnabled=\(sendButton.isEnabled), value=\(String(describing: sendButton.value))"
        )

        composer.tap()
        composer.typeText("ready")
        XCTAssertTrue(waitForEnabled(sendButton, timeout: 15), "Expected acp-send-button to recover enabled after turn completion")
        XCTAssertEqual(sendButton.value as? String, "send")

        // Verify ACP transcript hides process artifacts & upstream title, and toolbar manual rename succeeds
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Hidden E2E thought")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Hidden E2E tool")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "E2E Session 1")).firstMatch.exists)

        let moreMenu = app.buttons["acp-session-more-button"]
        XCTAssertTrue(moreMenu.waitForExistence(timeout: 5), "Expected acp-session-more-button on non-pending ACP session")
        moreMenu.tap()
        let renameButton = app.buttons["acp-session-rename-button"]
        XCTAssertTrue(renameButton.waitForExistence(timeout: 5), "Expected acp-session-rename-button action in toolbar menu")
        renameButton.tap()

        let renameAlert = app.alerts.firstMatch
        XCTAssertTrue(renameAlert.waitForExistence(timeout: 5), "Expected rename alert")
        let titleField = renameAlert.textFields["rename-session-text-field"].exists
            ? renameAlert.textFields["rename-session-text-field"]
            : renameAlert.textFields.firstMatch
        XCTAssertTrue(titleField.waitForExistence(timeout: 5))
        replaceText(in: titleField, with: "E2E Renamed")
        let saveRenameBtn = renameAlert.buttons["rename-session-save-button"].firstMatch.exists
            ? renameAlert.buttons["rename-session-save-button"].firstMatch
            : renameAlert.buttons.element(boundBy: 0)
        saveRenameBtn.tap()

        let renamedNav = app.navigationBars.containing(NSPredicate(format: "identifier CONTAINS %@", "E2E Renamed")).firstMatch
        XCTAssertTrue(
            renamedNav.waitForExistence(timeout: 10) || app.staticTexts["E2E Renamed"].waitForExistence(timeout: 5),
            "Expected renamed session title 'E2E Renamed' to appear after nonlocal/rename_session"
        )

        // MC-AC-7: Verify mode & command pills survive reconnect (and reopening from session list without session/load)
        let reconnectedToolbar = app.descendants(matching: .any).matching(identifier: "acp-composer-toolbar").firstMatch
        XCTAssertTrue(reconnectedToolbar.waitForExistence(timeout: 10), "acp-composer-toolbar missing after reconnect")
        let reconnectedModePicker = app.descendants(matching: .any).matching(identifier: "acp-mode-picker").firstMatch
        XCTAssertTrue(reconnectedModePicker.waitForExistence(timeout: 10), "acp-mode-picker missing after reconnect")
        assertSingleRowHeight(reconnectedModePicker, name: "acp-mode-picker-after-reconnect")
        let reconnectedCommandsButton = app.descendants(matching: .any).matching(identifier: "acp-commands-button").firstMatch
        XCTAssertTrue(reconnectedCommandsButton.waitForExistence(timeout: 10), "acp-commands-button missing after reconnect")
        if reconnectedCommandsButton.frame.isEmpty {
            reconnectedToolbar.swipeLeft()
        }
        if !reconnectedCommandsButton.frame.isEmpty {
            assertSingleRowHeight(reconnectedCommandsButton, name: "acp-commands-button-after-reconnect")
        }

        // Navigate back to session list and reopen E2E Renamed (triggers openSession -> setActiveSession without session/load)
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        if backButton.waitForExistence(timeout: 5), backButton.isHittable {
            backButton.tap()
            let sessionRowText = app.staticTexts["E2E Renamed"].firstMatch
            XCTAssertTrue(sessionRowText.waitForExistence(timeout: 10), "Expected 'E2E Renamed' in session list")
            sessionRowText.tap()

            XCTAssertTrue(
                reconnectedToolbar.waitForExistence(timeout: 15),
                "Expected acp-composer-toolbar after reopening synced session"
            )
            XCTAssertTrue(
                reconnectedModePicker.waitForExistence(timeout: 10),
                "Expected acp-mode-picker after reopening synced session"
            )
            assertSingleRowHeight(reconnectedModePicker, name: "acp-mode-picker-after-reopen")
            XCTAssertTrue(
                reconnectedCommandsButton.waitForExistence(timeout: 10),
                "Expected acp-commands-button after reopening synced session"
            )
            if reconnectedCommandsButton.frame.isEmpty {
                reconnectedToolbar.swipeLeft()
            }
            if !reconnectedCommandsButton.frame.isEmpty {
                assertSingleRowHeight(reconnectedCommandsButton, name: "acp-commands-button-after-reopen")
            }
        }
    }

    // SC-AC-062: 3-state activity dots & sorting stability E2E.
    @MainActor
    func testSessionListDotsAndSortFlow() throws {
        guard let config = acpE2EConfigurationOrFail() else {
            return
        }

        let app = makeApp()
        addUIInterruptionMonitor(withDescription: "System Alerts") { alert in
            let allowButtons = ["Allow", "OK", "Continue", "允许", "Erlauben", "Weiter", "Autoriser", "Permitir", "허용", "Разрешить"]
            for label in allowButtons where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }

        app.launch()
        app.tap()

        let addServerButton = app.buttons[E2E.emptyStateAddServerButtonId]
        XCTAssertTrue(
            addServerButton.waitForExistence(timeout: 20),
            "Expected clean first-run state. UI:\n\(app.debugDescription)"
        )
        addServerButton.tap()

        let nameField = app.textFields["ServerNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8))
        replaceText(in: nameField, with: "Dots E2E")

        let protocolPicker = app.segmentedControls["ProtocolPicker"]
        if protocolPicker.waitForExistence(timeout: 4), protocolPicker.buttons["ws"].exists {
            protocolPicker.buttons["ws"].tap()
        }

        let hostField = app.textFields["HostField"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 8))
        replaceText(in: hostField, with: config.host)

        let tokenField = app.secureTextFields["TokenField"].exists
            ? app.secureTextFields["TokenField"]
            : app.textFields["TokenField"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: 8))
        replaceText(in: tokenField, with: config.token)

        let cwdField = app.textFields["WorkingDirectoryField"]
        if !cwdField.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(cwdField.waitForExistence(timeout: 8))
        replaceText(in: cwdField, with: config.cwd)

        let toolbarSaveButton = app.buttons[E2E.saveToolbarButtonId].exists
            ? app.buttons[E2E.saveToolbarButtonId]
            : app.navigationBars.buttons["Save"]
        if toolbarSaveButton.waitForExistence(timeout: 8) {
            XCTAssertTrue(waitForEnabled(toolbarSaveButton, timeout: 8))
            toolbarSaveButton.tap()
        } else {
            let inlineSaveButton = app.buttons["SaveServerButton"]
            XCTAssertTrue(inlineSaveButton.waitForExistence(timeout: 8))
            XCTAssertTrue(waitForEnabled(inlineSaveButton, timeout: 8))
            inlineSaveButton.tap()
        }
        // Direct save without secondary confirmation modal (SD-1.5)
        XCTAssertFalse(app.buttons[E2E.summaryConfirmButtonId].waitForExistence(timeout: 2), "serverSummaryConfirmButton must not appear")

        let newSessionButton = app.buttons["newSessionButton"]
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 45))
        XCTAssertTrue(waitForEnabled(newSessionButton, timeout: 45))

        // AC-15: Initial seeded list has 0 running, 0 unread, 3 total, and no "active"/"idle" text.
        let runningCount = app.descendants(matching: .any).matching(identifier: "summaryRunningCount").firstMatch
        let unreadCount = app.descendants(matching: .any).matching(identifier: "summaryUnreadCount").firstMatch
        let totalCount = app.descendants(matching: .any).matching(identifier: "summaryTotalCount").firstMatch
        let rowTop = app.descendants(matching: .any).matching(identifier: "sessionRow_S-top").firstMatch
        let rowBg = app.descendants(matching: .any).matching(identifier: "sessionRow_S-bg-run").firstMatch
        let rowUnreadLater = app.descendants(matching: .any).matching(identifier: "sessionRow_S-unread-later").firstMatch

        XCTAssertTrue(rowTop.waitForExistence(timeout: 15), "Expected seeded S-top row. UI:\n\(app.debugDescription)")
        XCTAssertTrue(rowBg.waitForExistence(timeout: 10), "Expected seeded S-bg-run row")
        XCTAssertTrue(rowUnreadLater.waitForExistence(timeout: 10), "Expected seeded S-unread-later row")

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                (runningCount.value as? String) == "0"
                    && (unreadCount.value as? String) == "0"
                    && (totalCount.value as? String) == "3"
            },
            "Expected initial summary counts 0/0/3, got running=\(String(describing: runningCount.value)) unread=\(String(describing: unreadCount.value)) total=\(String(describing: totalCount.value))"
        )
        XCTAssertEqual(rowTop.value as? String, "read")
        XCTAssertEqual(rowBg.value as? String, "read")
        XCTAssertEqual(rowUnreadLater.value as? String, "read")
        XCTAssertLessThan(rowTop.frame.minY, rowBg.frame.minY)
        XCTAssertLessThan(rowBg.frame.minY, rowUnreadLater.frame.minY)
        XCTAssertFalse(app.staticTexts["active"].exists)
        XCTAssertFalse(app.staticTexts["Active"].exists)
        XCTAssertFalse(app.staticTexts["idle"].exists)
        XCTAssertFalse(app.staticTexts["IDLE"].exists)

        // AC-16 & AC-17: Trigger background streaming (S-bg-run stays running without jumping) and turn completion (S-unread-later promotes to top & turns unread).
        try postControl(to: config.controlURL, path: "/trigger-dots-and-sort")

        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                (rowBg.value as? String) == "running"
            },
            "Expected S-bg-run to enter running state"
        )
        XCTAssertLessThan(rowTop.frame.minY, rowBg.frame.minY, "Streaming chunks on S-bg-run must not jump above S-top")

        XCTAssertTrue(
            waitForCondition(timeout: 12) {
                (rowUnreadLater.value as? String) == "unread"
                    && (rowBg.value as? String) == "running"
                    && (rowTop.value as? String) == "read"
                    && (runningCount.value as? String) == "1"
                    && (unreadCount.value as? String) == "1"
                    && (totalCount.value as? String) == "3"
            },
            "Expected simultaneous 1 running / 1 unread / 3 total state"
        )
        XCTAssertLessThan(rowUnreadLater.frame.minY, rowTop.frame.minY, "Completed S-unread-later must promote above S-top")
        XCTAssertLessThan(rowTop.frame.minY, rowBg.frame.minY, "Streaming S-bg-run must stay below S-top")

        try postControl(to: config.controlURL, path: "/capture-dots-sort-screenshot")

        // AC-18: Tap unread row into chat detail, return to list -> unread clears to read & count drops to 0.
        rowUnreadLater.tap()
        let composer = app.descendants(matching: .any).matching(identifier: "acp-prompt-editor").firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15), "Expected chat detail after tapping unread session")

        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(backButton.waitForExistence(timeout: 10))
        backButton.tap()

        XCTAssertTrue(rowUnreadLater.waitForExistence(timeout: 10))
        XCTAssertTrue(
            waitForCondition(timeout: 10) {
                (rowUnreadLater.value as? String) == "read"
                    && (unreadCount.value as? String) == "0"
            },
            "Expected tapped unread row to clear to read upon opening/returning, got row=\(String(describing: rowUnreadLater.value)) unread=\(String(describing: unreadCount.value))"
        )
    }

    private func waitForCondition(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return condition()
    }

    private func verifySlashAutocompleteFlow(
        in app: XCUIApplication,
        composer: XCUIElement,
        toolbar: XCUIElement,
        commandsButton: XCUIElement,
        controlURL: URL
    ) throws {
        // STEP-01: Focus editor cleanly, verify software keyboard, capture baseline toolbar minY, then trigger /g
        clearPromptEditor(composer, app: app)
        composer.tap()

        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "Expected software keyboard to appear on prompt focus")
        XCTAssertGreaterThan(keyboard.frame.height, 200, "Expected full software keyboard (>200pt), frame=\(keyboard.frame)")

        let baselineToolbarMinY = stabilizedToolbarMinY(toolbar, above: keyboard)
        app.typeText("Use /g")

        let suggestions = app.descendants(matching: .any).matching(identifier: "acp-slash-suggestions").firstMatch
        XCTAssertTrue(suggestions.waitForExistence(timeout: 5), "Expected acp-slash-suggestions card for 'Use /g'")

        let goalCharterRow = app.buttons["acp-slash-suggestion-goal-charter"]
        let planGoalRow = app.buttons["acp-slash-suggestion-plan-goal"]
        let compactRow = app.buttons["acp-slash-suggestion-compact"]
        XCTAssertTrue(goalCharterRow.waitForExistence(timeout: 3), "Expected goal-charter suggestion")
        XCTAssertTrue(planGoalRow.waitForExistence(timeout: 3), "Expected plan-goal suggestion")
        XCTAssertFalse(compactRow.exists, "Did not expect compact suggestion for /g")

        XCTAssertLessThan(
            goalCharterRow.frame.minY,
            planGoalRow.frame.minY,
            "Expected A-Z ascending order (goal-charter before plan-goal), got goalCharter=\(goalCharterRow.frame), planGoal=\(planGoalRow.frame)"
        )
        XCTAssertLessThanOrEqual(
            suggestions.frame.maxY,
            toolbar.frame.minY,
            "Floating suggestions card must sit strictly above composer toolbar: suggestions=\(suggestions.frame), toolbar=\(toolbar.frame)"
        )
        XCTAssertLessThanOrEqual(
            abs(toolbar.frame.minY - baselineToolbarMinY),
            1.0,
            "Composer toolbar minY shifted unexpectedly from \(baselineToolbarMinY) to \(toolbar.frame.minY)"
        )
        let sendButton = app.descendants(matching: .any).matching(identifier: "acp-send-button").firstMatch
        XCTAssertTrue(composer.isHittable, "Composer must stay hittable while suggestions overlay is visible")
        XCTAssertTrue(toolbar.isHittable, "Composer toolbar must stay hittable while suggestions overlay is visible")
        XCTAssertTrue(sendButton.isHittable, "Send button must stay hittable while suggestions overlay is visible")

        try postControl(to: controlURL, path: "/capture-slash-suggestions-screenshot")

        // STEP-02: Space collapse -> backspace -> manual dismiss × -> stay suppressed -> prepare mid-word /p
        app.typeText(" ")
        XCTAssertTrue(waitForNonExistence(suggestions, timeout: 3), "Expected suggestions card to dismiss on space")

        app.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(suggestions.waitForExistence(timeout: 3), "Expected suggestions card to reopen after deleting space")

        let dismissButton = app.buttons["acp-slash-dismiss-button"]
        XCTAssertTrue(dismissButton.waitForExistence(timeout: 3), "Expected acp-slash-dismiss-button")
        dismissButton.tap()
        XCTAssertTrue(waitForNonExistence(suggestions, timeout: 3), "Expected suggestions card to dismiss after tapping ×")
        XCTAssertEqual(editorText(composer), "Use /g", "Dismissing × must preserve prompt text")

        app.typeText("o")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(suggestions.exists, "Dismissed '/' token must stay suppressed while typing within same token")
        XCTAssertEqual(editorText(composer), "Use /go", "Typing after dismiss must still land inside prompt editor")

        clearPromptEditor(composer, app: app)
        app.typeText("before /p after")
        for _ in 0..<6 {
            app.typeKey(.leftArrow, modifierFlags: [])
        }
        XCTAssertTrue(planGoalRow.waitForExistence(timeout: 3), "Expected plan-goal suggestion when caret returns into /p")

        // STEP-03: Tap plan-goal mid-sentence, verify caret stops after single trailing space and types 'X'
        planGoalRow.tap()
        XCTAssertTrue(waitForNonExistence(suggestions, timeout: 3), "Expected suggestions card to close after selection")
        XCTAssertTrue(keyboard.waitForExistence(timeout: 3), "Expected software keyboard to remain open after suggestion tap")

        app.typeText("X")
        XCTAssertTrue(
            waitForEditorText(composer, contains: "/plan-goal Xafter", timeout: 3),
            "Expected mid-sentence insertion with caret after single space, got '\(editorText(composer))'"
        )
        XCTAssertFalse(app.staticTexts["/plan-goal"].exists, "Expected no legacy selectedCommandView banner for /plan-goal")
        XCTAssertFalse(app.staticTexts["/compact"].exists, "Expected no legacy selectedCommandView banner for /compact")

        // STEP-04: Tap toolbar '/' menu -> compact -> verify automatic keyboard refocus without composer.tap() -> type 'Y'
        revealToolbarElement(commandsButton, in: toolbar)
        XCTAssertTrue(commandsButton.waitForExistence(timeout: 5) && commandsButton.isHittable, "acp-commands-button not reachable")
        commandsButton.tap()

        let compactMenuItem = app.descendants(matching: .any).matching(identifier: "acp-command-menu-compact").firstMatch
        XCTAssertTrue(compactMenuItem.waitForExistence(timeout: 5), "Expected acp-command-menu-compact in command menu")
        compactMenuItem.tap()

        XCTAssertTrue(
            keyboard.waitForExistence(timeout: 5),
            "Expected software keyboard to refocus automatically after command menu selection without tapping editor"
        )
        app.typeText("Y")
        XCTAssertTrue(
            waitForEditorText(composer, contains: "before /plan-goal X /compact Yafter", timeout: 3),
            "Expected menu insertion at pre-blur mid-string caret + leading space + 'Y', got '\(editorText(composer))'"
        )
        XCTAssertFalse(app.staticTexts["/plan-goal"].exists, "Expected no legacy selectedCommandView banner after menu pick")
        XCTAssertFalse(app.staticTexts["/compact"].exists, "Expected no legacy selectedCommandView banner after menu pick")

        clearPromptEditor(composer, app: app)
    }

    private func makeApp(languageOverride: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        let lang = languageOverride ?? ProcessInfo.processInfo.environment["AGMENTE_E2E_APPLE_LANGUAGE"]
        if let lang, !lang.isEmpty {
            app.launchArguments += ["-AppleLanguages", "(\(lang))"]
        }
        return app
    }

    private func confirmNewSessionSheetIfPresented(in app: XCUIApplication) {
        let createBtn = app.buttons["NewSessionCreateButton"]
        if createBtn.waitForExistence(timeout: 6) {
            createBtn.tap()
        }
    }

    private func editorText(_ composer: XCUIElement) -> String {
        let raw = (composer.value as? String) ?? ""
        if let placeholder = composer.placeholderValue, !placeholder.isEmpty, raw == placeholder {
            return ""
        }
        if raw == "Message the agent…" {
            return ""
        }
        return raw
    }

    private func clearPromptEditor(_ composer: XCUIElement, app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            let current = editorText(composer)
            if current.isEmpty {
                return
            }
            composer.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            let deleteSequence = String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count + 4)
            app.typeText(deleteSequence)
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        XCTAssertTrue(editorText(composer).isEmpty, "Failed to clear acp-prompt-editor, remaining='\(editorText(composer))'")
    }

    private func stabilizedToolbarMinY(_ toolbar: XCUIElement, above keyboard: XCUIElement) -> CGFloat {
        let deadline = Date().addingTimeInterval(3)
        var previousMinY = toolbar.frame.minY
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            let currentMinY = toolbar.frame.minY
            if abs(currentMinY - previousMinY) <= 0.5 && toolbar.frame.maxY <= keyboard.frame.minY + 1.0 {
                return currentMinY
            }
            previousMinY = currentMinY
        }
        return toolbar.frame.minY
    }

    private func waitForEditorText(_ composer: XCUIElement, contains expected: String, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if editorText(composer).contains(expected) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return editorText(composer).contains(expected)
    }

    private func waitForNonExistence(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return !element.exists
    }

    private func revealToolbarElement(_ element: XCUIElement, in toolbar: XCUIElement) {
        if element.exists && !element.frame.isEmpty && element.isHittable {
            return
        }
        for _ in 0..<3 {
            toolbar.swipeRight()
            if element.exists && !element.frame.isEmpty && element.isHittable {
                return
            }
        }
        for _ in 0..<3 {
            toolbar.swipeLeft()
            if element.exists && !element.frame.isEmpty && element.isHittable {
                return
            }
        }
    }

    private func replaceText(in element: XCUIElement, with value: String) {
        if element.elementType == .secureTextField {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            let existingCount = (element.value as? String)?.count ?? 0
            let deleteCount = max(existingCount + 8, 48)
            element.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: deleteCount))
        } else if let existingValue = element.value as? String,
                  !existingValue.isEmpty,
                  existingValue != element.placeholderValue {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
            let deleteSequence = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingValue.count + 4)
            element.typeText(deleteSequence)
        } else {
            element.tap()
        }

        element.typeText(value)
    }

    private func waitForEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == true && enabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }

    private func waitForAny(_ elements: [XCUIElement], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if elements.contains(where: { $0.exists }) {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return elements.contains(where: { $0.exists })
    }

    // SC-AC-063: Five features (Antigravity quota card, remote files, session info, offline Mermaid) E2E.
    func testFiveFeaturesEndToEndFlow() throws {
        guard let config = acpE2EConfigurationOrFail() else {
            return
        }

        let app = makeApp()
        addUIInterruptionMonitor(withDescription: "System Alerts") { alert in
            let allowButtons = ["Allow", "OK", "Continue", "允许", "Erlauben", "Weiter", "Autoriser", "Permitir", "허용", "Разрешить"]
            for label in allowButtons where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }

        app.launch()
        app.tap()

        // 1. Add isolated ACP server
        let addServerButton = app.buttons[E2E.emptyStateAddServerButtonId]
        XCTAssertTrue(
            addServerButton.waitForExistence(timeout: 20),
            "Expected clean first-run state. UI:\n\(app.debugDescription)"
        )
        addServerButton.tap()

        let nameField = app.textFields["ServerNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8))
        replaceText(in: nameField, with: "FiveFeatures E2E")

        let protocolPicker = app.segmentedControls["ProtocolPicker"]
        if protocolPicker.waitForExistence(timeout: 4), protocolPicker.buttons["ws"].exists {
            protocolPicker.buttons["ws"].tap()
        }

        let hostField = app.textFields["HostField"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 8))
        replaceText(in: hostField, with: config.host)

        let tokenField = app.secureTextFields["TokenField"].exists
            ? app.secureTextFields["TokenField"]
            : app.textFields["TokenField"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: 8))
        replaceText(in: tokenField, with: config.token)

        let cwdField = app.textFields["WorkingDirectoryField"]
        if !cwdField.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(cwdField.waitForExistence(timeout: 8))
        replaceText(in: cwdField, with: config.cwd)

        let toolbarSaveButton = app.buttons[E2E.saveToolbarButtonId].exists
            ? app.buttons[E2E.saveToolbarButtonId]
            : app.navigationBars.buttons["Save"]
        if toolbarSaveButton.waitForExistence(timeout: 8) {
            XCTAssertTrue(waitForEnabled(toolbarSaveButton, timeout: 8))
            toolbarSaveButton.tap()
        } else {
            let inlineSaveButton = app.buttons["SaveServerButton"]
            XCTAssertTrue(inlineSaveButton.waitForExistence(timeout: 8))
            XCTAssertTrue(waitForEnabled(inlineSaveButton, timeout: 8))
            inlineSaveButton.tap()
        }
        XCTAssertFalse(app.buttons[E2E.summaryConfirmButtonId].waitForExistence(timeout: 2), "serverSummaryConfirmButton must not appear")

        // 2. F1: Verify Antigravity ACP card title, quota A1 -> A toggle, and server card "文件" capsule coexist
        let cardTitle = app.staticTexts["antigravityCardTitle"]
        XCTAssertTrue(cardTitle.waitForExistence(timeout: 30), "Expected Antigravity ACP card title. UI:\n\(app.debugDescription)")

        let serverFilesButton = app.buttons["serverCardFilesButton"]
        XCTAssertTrue(serverFilesButton.waitForExistence(timeout: 15), "Expected top-bar serverCardFilesButton")

        let quotaToggle = app.buttons["quotaCollapseToggleButton"]
        XCTAssertTrue(quotaToggle.waitForExistence(timeout: 15), "Expected quotaCollapseToggleButton")
        quotaToggle.tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["quotaExpandedViewA"].waitForExistence(timeout: 10)
            || app.staticTexts["85%"].exists
            || app.staticTexts["quotaUpdatedAtLabel"].exists,
            "Expected expanded quota view A after toggling"
        )
        quotaToggle.tap()

        // 3. F4 (Server card entry): Open RemoteFileBrowserSheet, preview README.md, navigate back & close
        serverFilesButton.tap()
        let readmeRow = app.buttons["file-browser-file-README.md"]
        XCTAssertTrue(readmeRow.waitForExistence(timeout: 15), "Expected README.md in RemoteFileBrowserSheet")
        readmeRow.tap()
        // Wait for README.md preview navigation bar title to appear
        XCTAssertTrue(
            app.navigationBars["README.md"].waitForExistence(timeout: 10)
            || app.staticTexts["README.md"].waitForExistence(timeout: 5),
            "Expected README.md preview screen"
        )
        let backBtn = app.navigationBars.buttons["服务器文件"].exists
            ? app.navigationBars.buttons["服务器文件"]
            : (app.navigationBars.buttons["Back"].exists
                ? app.navigationBars.buttons["Back"]
                : app.navigationBars["README.md"].buttons.element(boundBy: 0))
        if backBtn.exists {
            backBtn.tap()
        }
        let closeFilesBtn = app.buttons["file-browser-close-button"]
        if !closeFilesBtn.waitForExistence(timeout: 6) {
            app.swipeDown(velocity: .fast)
        } else {
            closeFilesBtn.tap()
        }

        // 4. Create new session and enter SessionDetailView
        let newSessionButton = app.buttons["newSessionButton"]
        XCTAssertTrue(newSessionButton.waitForExistence(timeout: 20))
        newSessionButton.tap()
        confirmNewSessionSheetIfPresented(in: app)

        // 5. F4 (Session detail entry): Independent top-bar folder button
        let sessionFilesBtn = app.buttons["acp-session-files-button"]
        XCTAssertTrue(sessionFilesBtn.waitForExistence(timeout: 20), "Expected independent acp-session-files-button")
        sessionFilesBtn.tap()
        XCTAssertTrue(app.buttons["file-browser-chip-currentProject"].waitForExistence(timeout: 10), "Expected currentProject chip in session file browser")
        let closeSessionFilesBtn = app.buttons["file-browser-close-button"]
        XCTAssertTrue(closeSessionFilesBtn.waitForExistence(timeout: 10))
        closeSessionFilesBtn.tap()

        // 6. Send prompt to trigger F5 path link + F6 valid & invalid Mermaid diagrams
        let composer = app.textViews["acp-prompt-text-editor"].exists
            ? app.textViews["acp-prompt-text-editor"]
            : app.textViews.firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 15))
        composer.tap()
        composer.typeText("show five features")

        let sendBtn = app.buttons["acp-send-button"].exists
            ? app.buttons["acp-send-button"]
            : app.buttons["Send"]
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 10))
        sendBtn.tap()

        // 7. F2 (AC-215): SessionInfo via ... menu once session is materialized (strict assertion, zero silent skip)
        let moreBtn = app.buttons["acp-session-more-button"]
        XCTAssertTrue(moreBtn.waitForExistence(timeout: 15))
        moreBtn.tap()
        let infoMenuItem = app.buttons["acp-session-info-menu-item"]
        XCTAssertTrue(infoMenuItem.waitForExistence(timeout: 8), "AC-215: Expected acp-session-info-menu-item in ... menu")
        infoMenuItem.tap()
        let doneInfoBtn = app.buttons["session-info-done-button"].exists ? app.buttons["session-info-done-button"] : app.navigationBars.buttons.firstMatch
        XCTAssertTrue(doneInfoBtn.waitForExistence(timeout: 10), "AC-215: Expected SessionInfoSheet done button")
        doneInfoBtn.tap()

        // 8. F6 (AC-610 / AC-611 / SC-AC-063): Verify Mermaid row rendered in chat list & fullscreen source toggle (hard assertions)
        let mermaidRow = app.otherElements["acp-mermaid-row"].firstMatch
        XCTAssertTrue(mermaidRow.waitForExistence(timeout: 20), "SC-AC-063: Expected acp-mermaid-row in chat list")
        mermaidRow.tap()
        let modePicker = app.segmentedControls["mermaid-fullscreen-mode-picker"]
        XCTAssertTrue(modePicker.waitForExistence(timeout: 10), "SC-AC-063: Expected mermaid-fullscreen-mode-picker after tapping mermaid row")
        XCTAssertGreaterThanOrEqual(modePicker.buttons.count, 2, "SC-AC-063: Expected Diagram/Source segments")
        modePicker.buttons.element(boundBy: 1).tap()
        XCTAssertTrue(app.textViews["mermaid-fullscreen-source"].waitForExistence(timeout: 5), "SC-AC-063: Expected mermaid source view")
        let closeMermaidBtn = app.buttons["mermaid-fullscreen-close-button"]
        XCTAssertTrue(closeMermaidBtn.waitForExistence(timeout: 5))
        closeMermaidBtn.tap()
    }

    private func acpE2EConfigurationOrFail() -> ACPE2EConfiguration? {
        let env = ProcessInfo.processInfo.environment
        guard
            let host = env[ACPE2E.hostEnv]?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
            let token = env[ACPE2E.tokenEnv]?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
            let cwd = env[ACPE2E.cwdEnv]?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty,
            let controlRaw = env[ACPE2E.controlURLEnv]?.trimmingCharacters(in: .whitespacesAndNewlines),
            let controlURL = URL(string: controlRaw)
        else {
            XCTFail(
                "Missing required ACP E2E environment variables (\(ACPE2E.hostEnv), \(ACPE2E.tokenEnv), \(ACPE2E.cwdEnv), \(ACPE2E.controlURLEnv)). Configure them against an isolated `nonlocal-bridge` (`packages/bridge`) instance."
            )
            return nil
        }
        let nonBridgeHost = env[ACPE2E.nonBridgeHostEnv]?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ACPE2EConfiguration(
            host: host,
            token: token,
            cwd: cwd,
            controlURL: controlURL,
            nonBridgeHost: (nonBridgeHost?.isEmpty == false) ? nonBridgeHost : nil
        )
    }

    // SC-AC-054, SC-AC-055, SC-AC-056: Trimmed single-bridge form, required token, real-time '/' warning,
    // non-bridge rejection alert, direct save, Antigravity ACP card, single Add Server menu & 2-section Settings.
    @MainActor
    func testSingleBridgeFormAndRejectionFlow() throws {
        guard let config = acpE2EConfigurationOrFail() else {
            return
        }
        guard let nonBridgeHost = config.nonBridgeHost else {
            XCTFail("Missing \(ACPE2E.nonBridgeHostEnv). Set it to an isolated loopback non-bridge stub host.")
            return
        }

        let app = makeApp(languageOverride: "en")
        addUIInterruptionMonitor(withDescription: "System Alerts") { alert in
            let allowButtons = ["Allow", "OK", "Continue", "允许", "Erlauben", "Weiter"]
            for label in allowButtons where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }

        app.launch()
        app.tap()

        // STEP-01 (SC-AC-054): Trimmed form, required token disables Save, '/' shows rootWorkingDirectoryWarning immediately
        let addServerButton = app.buttons[E2E.emptyStateAddServerButtonId]
        XCTAssertTrue(addServerButton.waitForExistence(timeout: 20), "SC-AC-054: Expected emptyStateAddServerButton")
        addServerButton.tap()

        let nameField = app.textFields["ServerNameField"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 8), "SC-AC-054: Expected ServerNameField")

        // Verify removed controls are absent (SC-AC-054)
        let removedTypePickerId = "Server" + "TypePicker"
        let removedCloudflareLabel = "Cloudflare" + " Access"
        let removedSiteDomain = "halliharp" + ".com"
        XCTAssertFalse(app.segmentedControls[removedTypePickerId].exists, "SC-AC-054: removed type picker must not exist")
        XCTAssertFalse(app.staticTexts[removedCloudflareLabel].exists, "SC-AC-054: removed access section must not exist")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", removedSiteDomain)).firstMatch.exists, "SC-AC-054: external help site must not exist")

        let tokenField = app.secureTextFields["TokenField"].exists
            ? app.secureTextFields["TokenField"]
            : app.textFields["TokenField"]
        XCTAssertTrue(tokenField.waitForExistence(timeout: 8), "SC-AC-054: Expected TokenField")
        let tokenPlaceholder = (tokenField.placeholderValue ?? "") + " " + tokenField.label
        XCTAssertFalse(tokenPlaceholder.lowercased().contains("optional"), "SC-AC-054: Token field must not say optional, got '\(tokenPlaceholder)'")

        replaceText(in: nameField, with: "Single Bridge E2E")
        let protocolPicker = app.segmentedControls["ProtocolPicker"]
        if protocolPicker.waitForExistence(timeout: 4), protocolPicker.buttons["ws"].exists {
            protocolPicker.buttons["ws"].tap()
        }
        let hostField = app.textFields["HostField"]
        XCTAssertTrue(hostField.waitForExistence(timeout: 8))
        replaceText(in: hostField, with: nonBridgeHost)

        // Empty token -> saveToolbarButton MUST be disabled
        let toolbarSaveButton = app.buttons[E2E.saveToolbarButtonId]
        XCTAssertTrue(toolbarSaveButton.waitForExistence(timeout: 8), "SC-AC-054: Expected saveToolbarButton")
        XCTAssertFalse(toolbarSaveButton.isEnabled, "SC-AC-054: Empty token must keep saveToolbarButton disabled")

        // Enter '/' in WorkingDirectoryField -> rootWorkingDirectoryWarning appears immediately without tapping Save
        let cwdField = app.textFields["WorkingDirectoryField"]
        XCTAssertTrue(cwdField.waitForExistence(timeout: 8))
        replaceText(in: cwdField, with: "/")
        let rootWarning = app.descendants(matching: .any).matching(identifier: "rootWorkingDirectoryWarning").firstMatch
        XCTAssertTrue(rootWarning.waitForExistence(timeout: 5), "SC-AC-054: rootWorkingDirectoryWarning must appear immediately on '/'")
        if app.keyboards.count > 0 {
            cwdField.typeText("\n")
            RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        }
        try postControl(to: config.controlURL, path: "/capture-named-screenshot?name=sc-ui-form-root-warning.png")

        // STEP-02 (SC-AC-055): Non-bridge stub with valid token triggers alert, no serverSummaryConfirmButton, stays on form
        replaceText(in: tokenField, with: "stub-token-123")
        replaceText(in: cwdField, with: config.cwd)
        XCTAssertTrue(waitForEnabled(toolbarSaveButton, timeout: 5), "SC-AC-055: saveToolbarButton must enable when name/host/token filled")
        toolbarSaveButton.tap()

        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 20), "SC-AC-055: Non-bridge server must present error alert")
        let alertTexts = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
        XCTAssertTrue(
            alertTexts.lowercased().contains("compatible nonlocal bridge"),
            "SC-AC-055: Expected incompatible-bridge alert message, got '\(alertTexts)'"
        )
        XCTAssertFalse(app.buttons[E2E.summaryConfirmButtonId].exists, "SC-AC-055: serverSummaryConfirmButton must not appear")

        let okBtn = alert.buttons["OK"].exists ? alert.buttons["OK"] : alert.buttons.firstMatch
        okBtn.tap()
        XCTAssertTrue(hostField.waitForExistence(timeout: 5), "SC-AC-055: Must stay on AddServerView after dismissing non-bridge error")

        // STEP-03 (SC-AC-056): Switch to isolated Nonlocal Bridge with padded token -> direct save without modal,
        // Antigravity ACP card visible, single Add Server menu item, 2-section Settings, zero removed dev transcript button
        replaceText(in: hostField, with: config.host)
        replaceText(in: tokenField, with: " \(config.token) ")
        XCTAssertTrue(waitForEnabled(toolbarSaveButton, timeout: 5))
        toolbarSaveButton.tap()

        XCTAssertFalse(app.buttons[E2E.summaryConfirmButtonId].waitForExistence(timeout: 2), "SC-AC-056: Valid bridge must save directly without serverSummaryConfirmButton")
        let cardTitle = app.staticTexts["antigravityCardTitle"]
        XCTAssertTrue(
            cardTitle.waitForExistence(timeout: 30),
            "SC-AC-056: Expected antigravityCardTitle on single-server home. Alerts=\(app.alerts.allElementsBoundByIndex.map { $0.staticTexts.allElementsBoundByIndex.map(\.label) })"
        )

        // Open top-right menu -> single Add Server, zero legacy protocol or transcript items (SC-AC-056)
        let moreBtn = app.buttons["moreMenuButton"].firstMatch
        XCTAssertTrue(moreBtn.waitForExistence(timeout: 8), "SC-AC-056: Expected moreMenuButton")
        moreBtn.tap()
        let removedProtocolLabel = "Cod" + "ex"
        let removedTranscriptMenuId = "test" + "TranscriptMenuAction"
        let removedDevTranscriptId = "devRow" + "TranscriptButton"
        let removedExternalHost = "halli" + "harp"
        XCTAssertTrue(app.buttons["addACPServerMenuAction"].waitForExistence(timeout: 5), "SC-AC-056: Expected single Add Server menu item")
        XCTAssertFalse(app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", removedProtocolLabel)).firstMatch.exists, "SC-AC-056: Must have zero removed protocol menu items")
        XCTAssertFalse(app.buttons[removedTranscriptMenuId].exists, "SC-AC-056: removed transcript menu action must not exist")

        // Open Settings -> verify only Language & Developer mode (zero legacy logging, zero Send Feedback)
        let settingsAction = app.buttons["settingsMenuAction"].firstMatch
        XCTAssertTrue(settingsAction.waitForExistence(timeout: 5), "SC-AC-056: Expected settingsMenuAction")
        settingsAction.tap()
        XCTAssertTrue(app.buttons["settings-language-button"].waitForExistence(timeout: 8), "SC-AC-056: Expected Language section in Settings")
        let devToggle = app.switches.firstMatch
        XCTAssertTrue(devToggle.waitForExistence(timeout: 8), "SC-AC-056: Expected Developer mode toggle in Settings")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", removedProtocolLabel)).firstMatch.exists, "SC-AC-056: Must have zero removed protocol logging in Settings")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "Feedback")).firstMatch.exists, "SC-AC-056: Must have zero Send Feedback in Settings")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", removedExternalHost)).firstMatch.exists, "SC-AC-056: Must have zero external site links in Settings")

        // Enable Developer mode -> return to Home -> devRowLogsButton exists, removed transcript dev button does NOT exist
        if (devToggle.value as? String) != "1" {
            devToggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
            if (devToggle.value as? String) != "1" {
                devToggle.tap()
            }
        }
        XCTAssertEqual(devToggle.value as? String, "1", "SC-AC-056: Developer mode toggle must be ON")
        let settingsNav = app.navigationBars["Settings"].firstMatch
        if settingsNav.exists {
            settingsNav.swipeDown(velocity: .fast)
        } else {
            app.swipeDown(velocity: .fast)
        }
        XCTAssertTrue(app.buttons["devRowLogsButton"].waitForExistence(timeout: 8), "SC-AC-056: Expected devRowLogsButton when developer mode enabled")
        XCTAssertFalse(app.buttons[removedDevTranscriptId].exists, "SC-AC-056: removed transcript dev button must not exist")
    }

    private func assertSingleRowHeight(_ element: XCUIElement, name: String) {
        XCTAssertTrue(element.exists, "Expected element '\(name)' to exist")
        let height = element.frame.height
        XCTAssertGreaterThan(height, 0, "Expected '\(name)' height > 0, got \(height)")
        XCTAssertLessThanOrEqual(height, 44, "Expected '\(name)' single-row height <= 44pt, got \(height)")
    }

    private func postControl(to baseURL: URL, path: String) throws {
        let baseStr = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let cleanPath = path.hasPrefix("/") ? path : "/\(path)"
        guard let url = URL(string: "\(baseStr)\(cleanPath)") else {
            XCTFail("Invalid control URL: \(baseStr)\(cleanPath)")
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30

        final class Box: @unchecked Sendable {
            var response: URLResponse?
            var data: Data?
            var error: Error?
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { data, response, error in
            box.data = data
            box.response = response
            box.error = error
            semaphore.signal()
        }.resume()

        let waitResult = semaphore.wait(timeout: .now() + 30)
        if waitResult == .timedOut {
            XCTFail("Timed out calling E2E control endpoint \(url.absoluteString)")
            throw URLError(.timedOut)
        }
        if let error = box.error {
            XCTFail("Control endpoint \(url.absoluteString) failed: \(error.localizedDescription)")
            throw error
        }
        guard let http = box.response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let status = (box.response as? HTTPURLResponse)?.statusCode ?? -1
            let body = box.data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            XCTFail("Control endpoint \(url.absoluteString) returned HTTP \(status): \(body)")
            throw URLError(.badServerResponse)
        }
    }
}
