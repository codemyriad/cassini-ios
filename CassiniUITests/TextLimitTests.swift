import XCTest

/// Android `TextLimitBehaviourTest`: each text field fills to its limit, then one more character goes in and the field
/// still shows the limit. Titles stop at 200 characters, names at 80. The note rename is in `LibraryUITests`.
final class TextLimitTests: XCTestCase {
    private static let titleLimit = 200
    private static let nameLimit = 80

    @MainActor private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data"] + arguments
        app.launchAndWait()
        return app
    }

    /// Types past `limit` into `field`, then one more character; it shows `limit` characters each time.
    @MainActor private func fillPastTheLimit(_ field: XCUIElement, _ limit: Int, file: StaticString = #filePath, line: UInt = #line) {
        // The cursor goes to the end, so the deletes clear the whole field.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let count = (field.value as? String)?.count ?? 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count + 2))
        field.typeText(String(repeating: "a", count: limit + 1))
        XCTAssertEqual(field.value as? String, String(repeating: "a", count: limit), file: file, line: line)
        field.typeText("x")
        XCTAssertEqual(field.value as? String, String(repeating: "a", count: limit), file: file, line: line)
    }

    // ports: TextLimitBehaviourTest#theVoiceRenameStopsAtTheNameLimit
    @MainActor func testTheVoiceRenameStopsAtTheNameLimit() {
        let app = launch(["--seed", "voices"])
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(within: 15))
        app.buttons["Settings"].tap()
        let savedVoices = app.buttons["savedVoicesRow"]
        for _ in 0..<6 where !savedVoices.isHittable { app.swipeUp() }
        savedVoices.tap()
        let options = app.buttons["Options for Alex Moreau"]
        XCTAssertTrue(options.waitForExistence(within: 5))
        options.tap()
        app.buttons["Rename…"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(within: 5))
        fillPastTheLimit(field, Self.nameLimit)
    }

    // ports: TextLimitBehaviourTest#theNameFieldStopsAtTheNameLimit
    @MainActor func testTheNameFieldStopsAtTheNameLimit() {
        let app = launch(["--seed", "speakers", "--open-fixture", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"])
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 15))
        app.buttons["speakersButton"].tap()
        let alex = app.buttons["speaker-alex"]
        XCTAssertTrue(alex.waitForExistence(within: 5))
        alex.tap()
        let field = app.textFields["speakerNameField"]
        XCTAssertTrue(field.waitForExistence(within: 5))
        field.tap()
        fillPastTheLimit(field, Self.nameLimit)
    }

    // ports: TextLimitBehaviourTest#theRecordingTitleStopsAtTheTitleLimit
    @MainActor func testTheRecordingTitleStopsAtTheTitleLimit() {
        let app = launch(["--seed", "recording"])
        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(within: 15))
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["Pause recording"].waitForEnabled(within: 8))
        let field = app.textFields["recordingTitle"]
        field.tap()
        fillPastTheLimit(field, Self.titleLimit)
    }
}
