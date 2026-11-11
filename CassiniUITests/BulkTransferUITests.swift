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
}
