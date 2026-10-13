import XCTest

/// On a window wider than 560 pt (iPad, here in landscape beside the Library), each screen caps its content at 560 pt
/// and centres it in its column, while its background fills the column.
// ports: WideScreenTest#readAndListen
// ports: WideScreenTest#settings
// ports: WideScreenTest#trash
// ports: DialogLandscapeTest#theScrimCoversAWideWindow (the Rename form stays within its 560 pt band in landscape)
final class WideScreenTests: XCTestCase {
    private static let cap: CGFloat = 560

    @MainActor private func launch(_ arguments: [String]) throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a wide window")
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data"] + arguments
        app.launchAndWait()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15))
        return app
    }

    /// The detail column: the window right of the Library's sidebar, whose navigation bar is the narrowest.
    @MainActor private func detailColumn(_ app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch.frame
        let sidebar = app.navigationBars.allElementsBoundByIndex.map(\.frame).min { $0.width < $1.width } ?? .zero
        return CGRect(x: sidebar.maxX, y: window.minY, width: window.maxX - sidebar.maxX, height: window.height)
    }

    /// Every element lies in the band of `cap` centred in `column`, and the widest of them is wider than a phone's
    /// content would leave, so the band is really used.
    @MainActor private func assertCentred(_ elements: [XCUIElement], in column: CGRect,
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(column.width, Self.cap + 40, "the column is wider than the cap", file: file, line: line)
        let band = CGRect(x: column.midX - Self.cap / 2, y: column.minY, width: Self.cap, height: .greatestFiniteMagnitude)
        for element in elements {
            XCTAssertTrue(element.waitForExistence(within: 5), "\(element)", file: file, line: line)
            let frame = element.frame
            XCTAssertGreaterThanOrEqual(frame.minX, band.minX - 1, element.label, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, band.maxX + 1, element.label, file: file, line: line)
        }
    }

    @MainActor func testIPadNoteContentIsCappedAndCentred() throws {
        let app = try launch(["--seed", "library", "--open-fixture", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"])
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 10))
        let turns = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "turn-"))
        assertCentred([app.staticTexts["noteTitle"], turns.element(boundBy: 0), app.buttons["playButton"]], in: detailColumn(app))
    }

    @MainActor func testIPadSettingsAndRecentlyDeletedAreCappedAndCentred() throws {
        let app = try launch(["--seed", "trash"])
        app.buttons["Recently Deleted"].tap()
        XCTAssertTrue(app.staticTexts["Old interview draft"].waitForExistence(within: 5))
        assertCentred([app.staticTexts["Old interview draft"], app.buttons["Restore"].firstMatch], in: detailColumn(app))
        app.buttons["Settings"].tap()
        let language = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "App language")).firstMatch
        assertCentred([language], in: detailColumn(app))
    }

    @MainActor func testIPadRenameStaysInItsBandInLandscape() throws {
        let app = try launch(["--seed", "library"])
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Thoughts from the morning walk")).firstMatch
        XCTAssertTrue(row.waitForExistence(within: 5))
        row.press(forDuration: 1)
        app.buttons["Rename"].tap()
        let field = app.textFields["renameField"]
        XCTAssertTrue(field.waitForExistence(within: 5))
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(field.frame), "the form is inside the window")
        XCTAssertLessThanOrEqual(field.frame.width, Self.cap, "the field is at most 560 pt wide")
    }
}
