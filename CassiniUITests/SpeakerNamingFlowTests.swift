import XCTest

/// Naming speakers through saved voices, end to end on the `speakers` seed: the note's second speaker is still
/// "Speaker 2" and the saved voice "Sam Rivera" may be them.
final class SpeakerNamingFlowTests: XCTestCase {
    @MainActor private func launchSpeakersSeed() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "speakers",
                               "--open-fixture", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"]
        app.launch()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    // ports: SpeakerNamingFlowTest#aSavedVoiceIsSuggestedInTheDraftAndYesNamesTheSpeaker
    /// iOS suggests after the analysis rather than in a draft; Yes names the speaker and Saved voices counts the note.
    @MainActor func testASavedVoiceIsSuggestedAndYesNamesTheSpeaker() {
        let app = launchSpeakersSeed()
        let yes = app.buttons["suggestionYes"]
        XCTAssertTrue(yes.waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, containing: "Is this Sam Rivera?").exists)
        yes.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sam Rivera, at")).firstMatch
            .waitForExistence(timeout: 5), "the passage carries the name")
        XCTAssertFalse(app.buttons["suggestionYes"].exists)

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let savedVoices = app.buttons["savedVoicesRow"]
        for _ in 0..<6 where !savedVoices.isHittable { app.swipeUp() }
        savedVoices.tap()
        XCTAssertTrue(element(app, containing: "Sam Rivera").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, containing: "1 note").waitForExistence(timeout: 5))
    }

    /// Typing a saved voice's first name asks whether it is the same person; Save waits for the answer.
    @MainActor func testAFirstNameOfASavedVoiceAsksTheSamePersonQuestion() {
        let app = launchSpeakersSeed()
        app.buttons["speakersButton"].tap()
        let alex = app.buttons["speaker-alex"]
        XCTAssertTrue(alex.waitForExistence(timeout: 5))
        alex.tap()
        let field = app.textFields["speakerNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10) + "Sam")
        XCTAssertTrue(element(app, containing: "is already a saved voice").waitForExistence(timeout: 5))

        app.buttons["saveSpeakerName"].tap()
        XCTAssertTrue(field.exists, "Save waits until the question is answered")
        app.buttons["questionYes"].tap()
        XCTAssertEqual(field.value as? String, "Sam Rivera")
        app.buttons["saveSpeakerName"].tap()

        XCTAssertTrue(element(app, containing: "Sam Rivera").waitForExistence(timeout: 5))
        XCTAssertFalse(app.textFields["speakerNameField"].exists)
    }
}
