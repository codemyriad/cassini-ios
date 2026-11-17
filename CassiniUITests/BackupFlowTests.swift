import XCTest

final class BackupFlowTests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    @MainActor private func launch(_ arguments: [String] = ["--seed", "library"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"] + arguments
        app.launchAndWait()
        XCTAssertTrue(app.staticTexts["uiTestState-backupState"].waitForExistence(within: 15))
        return app
    }

    @MainActor private func openBackup(_ app: XCUIApplication) {
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.waitForSettingsPage("map"))
        app.buttons["backupRow"].tap()
        XCTAssertTrue(app.waitForSettingsPage("backup"))
        XCTAssertTrue(app.switches["cloudBackupToggle"].waitForEnabled(within: 15))
    }

    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(app.scroll(attempts: 12) { element.exists && element.isHittable && app.frame.contains(element.frame) })
    }

    @MainActor func testNoticeFloatsAboveCaptureAndLeavesMeetingRowsReachable() {
        let app = launch()
        let notice = app.descendants(matching: .any).matching(identifier: "backupNotice").firstMatch
        XCTAssertTrue(notice.waitForExistence(within: 15))
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@", "A quieter kind of productivity")).firstMatch
        XCTAssertTrue(poll(within: uiWaitFloor) {
            notice.frame.height < app.frame.height * 0.6 && row.isHittable
        }, "The card sizes to its content and leaves the saved meeting reachable")
        XCTAssertLessThanOrEqual(notice.frame.maxY, app.buttons["recordButton"].frame.minY)
        XCTAssertTrue(app.buttons["backupNoticeDismiss"].isHittable)
    }

    @MainActor func testUndoTemporarilyTakesPriorityWithoutDismissingBackupNotice() {
        let app = launch()
        XCTAssertTrue(app.buttons["backupNoticeDismiss"].waitForExistence(within: 15))
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@", "Thoughts from the morning walk")).firstMatch
        row.press(forDuration: 1)
        app.buttons["Move to Recently Deleted"].tapWhenSettled()
        let undo = app.buttons["Undo"]
        XCTAssertTrue(undo.waitForExistence(within: 15))
        XCTAssertFalse(app.buttons["backupNoticeDismiss"].exists)
        XCTAssertTrue(undo.isHittable)
        undo.tap()
        XCTAssertTrue(row.waitForExistence(within: 15))
        XCTAssertTrue(app.buttons["backupNoticeDismiss"].waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts["uiTestState-backupState"].waitForValue("cloud=true;voices=true;dismissed=false"))
    }

    @MainActor func testLastMeetingCanScrollAboveTheFloatingNotice() {
        let app = launch(["--seed", "statuses"])
        XCTAssertTrue(app.buttons["backupNoticeDismiss"].waitForExistence(within: 15))
        let row = app.scrolledLibraryRow("Thoughts from the morning walk")
        let notice = app.descendants(matching: .any).matching(identifier: "backupNotice").firstMatch
        XCTAssertLessThanOrEqual(row.frame.maxY, notice.frame.minY)
        row.tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 15))
        XCTAssertEqual(app.staticTexts["noteTitle"].label, "Thoughts from the morning walk")
    }

    @MainActor func testOwnCopyIsDisabledWithoutSavedMeetings() {
        let app = launch([])
        openBackup(app)
        let export = app.buttons["backupExportZIP"]
        reveal(export, in: app)
        XCTAssertFalse(export.isEnabled)
    }

    @MainActor func testEmptyLibraryDoesNotShowTheBackupNotice() {
        let app = launch([])
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(within: 15))
        XCTAssertFalse(app.buttons["backupNoticeDismiss"].exists)
    }

    @MainActor func testFirstLiveCaptureDoesNotShowNoticeUntilSaved() {
        let app = launch(["--seed", "recording"] + DeviceUnderTest.workingSpeech)
        for title in ["A quieter kind of productivity", "Thoughts from the morning walk"] {
            let row = app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(row.waitForExistence(within: 15))
            row.press(forDuration: 1)
            app.buttons["Move to Recently Deleted"].tapWhenSettled()
        }
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(within: 15))
        XCTAssertFalse(app.buttons["backupNoticeDismiss"].exists)
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["pauseResumeRecording"].waitForEnabled(within: 15))
        app.buttons["recordingAllMeetings"].tap()
        XCTAssertTrue(app.buttons["activeRecordingCard"].waitForExistence(within: 15))
        XCTAssertFalse(app.buttons["backupNoticeDismiss"].exists)
        app.buttons["activeRecordingCard"].tap()
        XCTAssertTrue(app.buttons["stopRecording"].waitForEnabled(within: 15))
        app.buttons["stopRecording"].tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 15))
        if UIDevice.current.userInterfaceIdiom != .pad { app.navigationBars.buttons["Back to all meetings"].tap() }
        XCTAssertTrue(app.buttons["backupNoticeDismiss"].waitForExistence(within: 15))
    }

    @MainActor func testBothChoicesDefaultOnAndDetailRowsDescribeInclusion() {
        let app = launch()
        openBackup(app)
        XCTAssertEqual(app.switches["cloudBackupToggle"].value as? String, "1")
        XCTAssertEqual(app.switches["includeSavedVoicesToggle"].value as? String, "1")
        let info = app.buttons["backupInfoRow"]
        reveal(info, in: app); info.tap()
        XCTAssertTrue(app.navigationBars["In more detail"].waitForExistence(within: 15))
        for id in ["backupStatusMeetings", "backupStatusSettings", "backupStatusVoices", "backupStatusModels"] {
            let row = app.descendants(matching: .any).matching(identifier: id).firstMatch
            reveal(row, in: app)
            XCTAssertTrue(row.label.contains(id == "backupStatusModels" ? "Marked to be left out" : "Included when iCloud Backup is on"), row.label)
        }
    }

    @MainActor func testReadersLinkOpensTheReadershipSection() {
        let app = launch()
        openBackup(app)
        let readers = app.buttons["backupReadersRow"]
        reveal(readers, in: app); readers.tap()
        let heading = app.staticTexts["iCloud Backup"]
        XCTAssertTrue(heading.waitForExistence(within: 15))
        XCTAssertTrue(heading.isHittable, "The topic link opens its section without another scroll")
    }

    @MainActor func testVoiceChoiceDoesNotExcludeMeetings() {
        let app = launch()
        openBackup(app)
        let control = app.switches["includeSavedVoicesToggle"]
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertTrue(control.waitForValue("0"))
        XCTAssertEqual(app.switches["cloudBackupToggle"].value as? String, "1")
        let info = app.buttons["backupInfoRow"]
        reveal(info, in: app); info.tap()
        XCTAssertTrue(app.navigationBars["In more detail"].waitForExistence(within: 15))
        for id in ["backupStatusMeetings", "backupStatusVoices"] {
            let row = app.descendants(matching: .any).matching(identifier: id).firstMatch
            reveal(row, in: app)
            XCTAssertTrue(row.label.contains(id == "backupStatusMeetings" ? "Included when iCloud Backup is on" : "Marked to be left out"), row.label)
        }
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-test-data" }
        app.launchAndWait(fresh: true)
        XCTAssertTrue(app.staticTexts["uiTestState-backupState"].waitForValue("cloud=true;voices=false;dismissed=false"))
    }

    @MainActor func testExcludingMeetingsPreservesVoiceChoiceAndExcludesBothStoredKinds() {
        let app = launch()
        openBackup(app)
        let control = app.switches["cloudBackupToggle"]
        // A composite Toggle's AX frame includes its multiline label. Tap the native switch at its trailing edge.
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.94, dy: 0.5)).tap()
        XCTAssertTrue(app.switches["cloudBackupToggle"].waitForValue("0"))
        XCTAssertEqual(app.switches["includeSavedVoicesToggle"].value as? String, "1")
        XCTAssertEqual(app.staticTexts["backupAnswer"].label, "Marked to be left out")
        let info = app.buttons["backupInfoRow"]
        reveal(info, in: app); info.tap()
        XCTAssertTrue(app.navigationBars["In more detail"].waitForExistence(within: 15))
        for id in ["backupStatusMeetings", "backupStatusVoices"] {
            let row = app.descendants(matching: .any).matching(identifier: id).firstMatch
            reveal(row, in: app)
            XCTAssertTrue(row.label.contains("Marked to be left out"), row.label)
        }
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-test-data" }
        app.launchAndWait(fresh: true)
        XCTAssertTrue(app.staticTexts["uiTestState-backupState"].waitForValue("cloud=false;voices=true;dismissed=false"))
        XCTAssertFalse(app.buttons["backupNoticeDismiss"].exists)
    }

    @MainActor func testNoticeCloseAndPrimaryKeepBothChoicesAndPersistDismissal() {
        for action in ["backupNoticeDismiss", "backupNoticeKeep"] {
            let app = launch()
            let button = app.buttons[action]
            XCTAssertTrue(button.waitForExistence(within: 15)); button.tap()
            XCTAssertTrue(app.staticTexts["uiTestState-backupState"].waitForValue("cloud=true;voices=true;dismissed=true"))
            XCTAssertFalse(app.buttons["backupNoticeDismiss"].exists)
            app.terminate()
            app.launchArguments.removeAll { $0 == "--reset-test-data" }
            app.launchAndWait(fresh: true)
            XCTAssertTrue(app.staticTexts["uiTestState-backupState"].waitForValue("cloud=true;voices=true;dismissed=true"))
            XCTAssertFalse(app.buttons["backupNoticeDismiss"].exists)
        }
    }

    @MainActor func testNoticeExclusionCommitsBeforeDismissing() {
        let app = launch()
        XCTAssertTrue(app.buttons["backupNoticeExclude"].waitForExistence(within: 15))
        app.buttons["backupNoticeExclude"].tap()
        XCTAssertTrue(app.staticTexts["uiTestState-backupState"].waitForValue("cloud=false;voices=true;dismissed=true"))
        XCTAssertFalse(app.buttons["backupNoticeDismiss"].exists)
        openBackup(app)
        XCTAssertEqual(app.switches["cloudBackupToggle"].value as? String, "0")
        XCTAssertEqual(app.switches["includeSavedVoicesToggle"].value as? String, "1")
    }

    @MainActor func testOwnCopyExportsEverySavedMeeting() {
        let app = launch()
        openBackup(app)
        let export = app.buttons["backupExportZIP"]
        reveal(export, in: app); export.tapWhenSettled()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(within: 15))
        closeShareSheet(app)
        let complete = app.staticTexts["zipExportCompleted"]
        reveal(complete, in: app)
        XCTAssertEqual(complete.label, "Exported 2 to a ZIP archive")
    }
}
