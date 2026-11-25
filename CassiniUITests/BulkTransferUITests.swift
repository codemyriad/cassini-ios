import XCTest

final class BulkTransferUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "library", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchAndWait(fresh: true)
        XCTAssertTrue(app.buttons["selectNotesForExport"].waitForExistence(within: 15))
        return app
    }

    @MainActor func testExportAllMakesACompletedArchiveAndOffersItForSaving() {
        let app = launch()
        app.buttons["selectNotesForExport"].tap()
        XCTAssertTrue(app.buttons["selectAllNotes"].waitForExistence(within: 15))
        app.buttons["selectAllNotes"].tap()
        app.buttons["exportSelectedNotes"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(within: 15))
        closeShareSheet(app)
        XCTAssertTrue(app.staticTexts["zipExportCompleted"].waitForExistence(within: 15))
        XCTAssertEqual(app.staticTexts["zipExportCompleted"].label, "Exported 2 to a ZIP archive")
    }

    @MainActor func testSelectedExportIsEnabledOnlyAfterSelectingANote() {
        let app = launch()
        let selection = app.buttons["selectArchiveNote-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"]
        XCTAssertTrue(app.buttons["selectNotesForExport"].tapWhenInteractive(in: app, until: { selection.exists }),
                      "Select enters selection mode")
        let exportButton = app.buttons["exportSelectedNotes"]
        XCTAssertTrue(exportButton.waitForExistence(within: 15))
        XCTAssertFalse(exportButton.isEnabled)
        selection.tap()
        XCTAssertTrue(exportButton.waitForEnabled(within: 15))
        exportButton.tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(within: 15))
        closeShareSheet(app)
        XCTAssertTrue(app.staticTexts["zipExportCompleted"].waitForExistence(within: 15))
        XCTAssertEqual(app.staticTexts["zipExportCompleted"].label, "Exported 1 to a ZIP archive")
    }

    @MainActor func testExportAllSkipsALiveRecording() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "recording", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchAndWait(fresh: true)
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["Pause recording"].waitForEnabled(within: 15))
        app.buttons["recordingAllMeetings"].tap()
        XCTAssertTrue(app.buttons["activeRecordingCard"].waitForExistence(within: 15))
        app.buttons["selectNotesForExport"].tap()
        XCTAssertTrue(app.buttons["selectAllNotes"].waitForExistence(within: 15))
        app.buttons["selectAllNotes"].tap()
        app.buttons["exportSelectedNotes"].tap()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(within: 15))
        closeShareSheet(app)
        XCTAssertTrue(app.staticTexts["zipExportCompleted"].waitForExistence(within: 15))
        XCTAssertEqual(app.staticTexts["zipExportCompleted"].label, "Exported 2 to a ZIP archive")
    }

    @MainActor func testTrashingTheSelectionDisablesExport() {
        let app = launch()
        app.buttons["selectNotesForExport"].tap()
        let selection = app.buttons["selectArchiveNote-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"]
        XCTAssertTrue(selection.waitForExistence(within: 15))
        selection.tap()
        XCTAssertTrue(app.buttons["exportSelectedNotes"].waitForEnabled(within: 15))
        app.buttons["deleteSelectedNotes"].tap()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(within: 15))
    }

    @MainActor func testOnlyALiveRecordingOffersNoSelectAction() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "recording", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchAndWait(fresh: true)
        for title in ["A quieter kind of productivity", "Thoughts from the morning walk"] {
            let row = app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(row.waitForExistence(within: 15))
            row.press(forDuration: 1)
            app.buttons["Delete"].tapWhenSettled()
        }
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(within: 15))
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["Pause recording"].waitForEnabled(within: 15))
        app.buttons["recordingAllMeetings"].tap()
        XCTAssertTrue(app.buttons["activeRecordingCard"].waitForExistence(within: 15))
        XCTAssertFalse(app.buttons["selectNotesForExport"].exists)
    }
}
