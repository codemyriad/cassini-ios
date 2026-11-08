import XCTest

final class RecordingSelectionTests: XCTestCase {
    @MainActor func testIPadSelectingAnotherRecordingReplacesTheDetailEachTime() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "split-view selection")
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed-test-data"]
        app.launchAndWait(fresh: true)
        let titles = ["A quieter kind of productivity", "Thoughts from the morning walk"]
        let list = app.scrollViews.containing(.button, identifier: "noteRow").firstMatch
        for title in titles + titles + titles {
            let row = app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(list.scroll(up: title == titles[1]) { row.exists && row.isHittable })
            row.tap()
            XCTAssertTrue(row.wait(until: NSPredicate(format: "selected == true"), within: 15))
            XCTAssertTrue(app.staticTexts["noteTitle"].wait(until: NSPredicate(format: "label == %@", title), within: 15),
                          "The detail must follow the selected row, including replacement at the same stack depth")
        }
    }

    @MainActor func testBackToLibraryThenAnotherRecordingOpensTheRequestedNote() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the compact back stack")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed-test-data"]
        app.launchAndWait(fresh: true)
        let titles = ["A quieter kind of productivity", "Thoughts from the morning walk"]
        let list = app.scrollViews.containing(.button, identifier: "noteRow").firstMatch
        for title in titles + titles {
            let row = app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(list.scroll(up: title == titles[1]) { row.exists && row.isHittable })
            row.tap()
            XCTAssertTrue(app.staticTexts["noteTitle"].wait(until: NSPredicate(format: "label == %@", title), within: 15))
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15))
        }
    }

}
