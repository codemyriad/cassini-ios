import XCTest

final class BulkTransferUITests: XCTestCase {
    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "library", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchAndWait(fresh: true)
        XCTAssertTrue(app.buttons["libraryArchiveMenu"].waitForExistence(within: 15))
        return app
    }

    @MainActor func testExportAllMakesACompletedArchiveAndOffersItForSaving() {
        let app = launch()
        app.buttons["libraryArchiveMenu"].tap()
        app.collectionViews.buttons["Export All as ZIP…"].tapWhenSettled()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(within: 15))
        closeShareSheet(app)
        XCTAssertTrue(app.staticTexts["zipExportCompleted"].waitForExistence(within: 15))
        XCTAssertEqual(app.staticTexts["zipExportCompleted"].label, "Exported 2 to a ZIP archive")
    }

    @MainActor func testSelectedExportIsShownOnlyAfterSelectingANote() {
        let app = launch()
        app.buttons["libraryArchiveMenu"].tap()
        XCTAssertTrue(app.collectionViews.buttons["Export All as ZIP…"].waitForExistence(within: 15))
        XCTAssertFalse(app.collectionViews.buttons["Export Selected as ZIP…"].exists)
        app.navigationBars.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        app.buttons["selectNotesForExport"].tap()
        let selection = app.buttons["selectArchiveNote-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"]
        XCTAssertTrue(selection.waitForExistence(within: 15))
        selection.tap()
        app.buttons["libraryArchiveMenu"].tap()
        app.collectionViews.buttons["Export Selected as ZIP…"].tapWhenSettled()
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
        app.buttons["libraryArchiveMenu"].tap()
        let export = app.collectionViews.buttons["Export All as ZIP…"]
        XCTAssertTrue(export.waitForExistence(within: 15))
        let card = app.buttons["activeRecordingCard"]
        let previous = card.label
        XCTAssertTrue(card.wait(until: NSPredicate(format: "label != %@", previous), within: 15),
                      "The open menu survives an actual capture-clock update")
        XCTAssertTrue(export.exists)
        export.tapWhenSettled()
        XCTAssertTrue(app.otherElements["ActivityListView"].waitForExistence(within: 15))
        closeShareSheet(app)
        XCTAssertTrue(app.staticTexts["zipExportCompleted"].waitForExistence(within: 15))
        XCTAssertEqual(app.staticTexts["zipExportCompleted"].label, "Exported 2 to a ZIP archive")
    }

    @MainActor func testTrashingTheSelectionRemovesTheSelectedExportAction() {
        let app = launch()
        app.buttons["selectNotesForExport"].tap()
        app.buttons["selectArchiveNote-AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@", "A quieter kind of productivity")).firstMatch
        row.press(forDuration: 1)
        app.buttons["Move to Recently Deleted"].tapWhenSettled()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(within: 15))
        app.buttons["libraryArchiveMenu"].tap()
        XCTAssertTrue(app.collectionViews.buttons["Export All as ZIP…"].waitForExistence(within: 15))
        XCTAssertFalse(app.collectionViews.buttons["Export Selected as ZIP…"].exists)
    }

    @MainActor func testOnlyALiveRecordingOffersNoEditOrZIPAction() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "recording", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchAndWait(fresh: true)
        for title in ["A quieter kind of productivity", "Thoughts from the morning walk"] {
            let row = app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(row.waitForExistence(within: 15))
            row.press(forDuration: 1)
            app.buttons["Move to Recently Deleted"].tapWhenSettled()
        }
        XCTAssertTrue(app.staticTexts["No notes yet"].waitForExistence(within: 15))
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["Pause recording"].waitForEnabled(within: 15))
        app.buttons["recordingAllMeetings"].tap()
        XCTAssertTrue(app.buttons["activeRecordingCard"].waitForExistence(within: 15))
        XCTAssertFalse(app.buttons["libraryArchiveMenu"].exists)
        XCTAssertFalse(app.buttons["selectNotesForExport"].exists)
    }

}
