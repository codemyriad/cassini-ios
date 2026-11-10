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

    /// Fills `field` past `limit` in one edit, then types one more character; it shows `limit` characters each time.
    @MainActor private func fillPastTheLimit(_ field: XCUIElement, _ limit: Int, file: StaticString = #filePath, line: UInt = #line) {
        // The cursor goes to the end, so the deletes clear the whole field.
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.5)).tap()
        let full = String(repeating: "a", count: limit)
        field.replaceText(with: full + "a", expecting: full)
        // The field cuts what goes past the limit as it changes, a moment after the typing on a busy machine.
        _ = field.wait(until: NSPredicate(format: "value == %@", full), within: 3)
        XCTAssertEqual(field.value as? String, full, file: file, line: line)
        field.typeText("x")
        _ = field.wait(until: NSPredicate(format: "value == %@", full), within: 3)
        XCTAssertEqual(field.value as? String, full, file: file, line: line)
    }

    // ports: TextLimitBehaviourTest#theVoiceRenameStopsAtTheNameLimit
    @MainActor func testTheVoiceRenameStopsAtTheNameLimit() {
        let app = launch(["--seed", "voices"])
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(within: 15))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 5))
        let savedVoices = app.buttons["savedVoicesRow"]
        app.scroll(attempts: 6) { savedVoices.exists && savedVoices.isHittable }
        savedVoices.tap()
        let options = app.buttons["Options for Alex Moreau"]
        XCTAssertTrue(options.waitForExistence(within: 5))
        options.tap()
        app.buttons["Rename…"].tap()
        let field = app.textFields["renameVoiceField"]
        XCTAssertTrue(field.waitForExistence(within: 5))
        let save = app.navigationBars.buttons["Save"]
        XCTAssertFalse(save.isEnabled, "Save waits for a changed name")
        fillPastTheLimit(field, Self.nameLimit)
        XCTAssertTrue(save.isEnabled)

        // A blank name says "Enter a name." under the field, as Android's dialog does.
        field.replaceText(with: " ")
        XCTAssertTrue(app.staticTexts["Enter a name."].waitForExistence(within: 3), "a blank name says so under the field")
        XCTAssertFalse(save.isEnabled)
        field.replaceText(with: "Alexandra")
        save.tap()
        XCTAssertTrue(app.staticTexts["Alexandra"].waitForExistence(within: 5), "the saved voice has its new name")
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
