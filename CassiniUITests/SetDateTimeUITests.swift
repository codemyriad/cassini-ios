import XCTest

/// End-to-end UI tests for Set date and time (D-1163 / L-87):
/// - Library long-press menu item under Rename opens the half-height sheet.
/// - Meeting screen "…" menu item under Rename opens the same sheet.
final class SetDateTimeUITests: XCTestCase {
    @MainActor func testSetDateTimeFromLibraryAndNoteMenus() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "library"]
        app.launchAndWait()

        let row = app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label CONTAINS %@", "A quieter kind of productivity")).firstMatch
        XCTAssertTrue(row.waitForExistence(within: uiWaitFloor))

        // Long-press menu: Set date and time opens "When was this recorded?"
        row.press(forDuration: 1)
        let menuItem = app.buttons["Set date and time"]
        XCTAssertTrue(menuItem.waitForExistence(within: uiWaitFloor))
        menuItem.tapWhenSettled()

        XCTAssertTrue(app.navigationBars["When was this recorded?"].waitForExistence(within: uiWaitFloor))
        XCTAssertTrue(app.buttons["setDateTimeSave"].waitForExistence(within: uiWaitFloor))
        XCTAssertTrue(app.buttons["setDateTimeCancel"].exists)
        app.buttons["setDateTimeSave"].tap()
        XCTAssertTrue(poll(within: uiWaitFloor) { !app.navigationBars["When was this recorded?"].exists })

        // Open the meeting and verify the "…" menu also offers Set date and time.
        row.tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: uiWaitFloor))
        let more = app.buttons["noteActions"]
        XCTAssertTrue(more.waitForExistence(within: uiWaitFloor))
        more.tap()

        let noteMenuItem = app.buttons["Set date and time"]
        XCTAssertTrue(noteMenuItem.waitForExistence(within: uiWaitFloor))
        noteMenuItem.tapWhenSettled()

        XCTAssertTrue(app.navigationBars["When was this recorded?"].waitForExistence(within: uiWaitFloor))
        app.buttons["setDateTimeCancel"].tap()
        XCTAssertTrue(poll(within: uiWaitFloor) { !app.navigationBars["When was this recorded?"].exists })
    }

    @MainActor func testIPadSetDateTimeFromLibraryAndNoteMenus() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        testSetDateTimeFromLibraryAndNoteMenus()
    }
}
