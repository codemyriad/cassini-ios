import XCTest

/// Naming speakers through saved voices, end to end on the `speakers` seed: the note's second speaker is still
/// "Speaker 2" and the saved voice "Sam Rivera" may be them.
final class SpeakerNamingFlowTests: XCTestCase {
    @MainActor private func launchSpeakersSeed() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "speakers",
                               "--open-fixture", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"]
        app.launchAndWait()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 15))
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
        XCTAssertTrue(yes.waitForExistence(within: 10))
        XCTAssertTrue(element(app, containing: "Is this Sam Rivera?").exists)
        yes.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sam Rivera, at")).firstMatch
            .waitForExistence(within: 5), "the passage carries the name")
        XCTAssertTrue(app.buttons["suggestionYes"].waitForNonExistence(within: 5))

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(within: 5))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 5))
        let savedVoices = app.buttons["savedVoicesRow"]
        app.scroll(attempts: 6) { savedVoices.exists && savedVoices.isHittable }
        savedVoices.tap()
        XCTAssertTrue(element(app, containing: "Sam Rivera").waitForExistence(within: 5))
        XCTAssertTrue(element(app, containing: "1 note").waitForExistence(within: 5))
    }

    /// Typing a saved voice's first name asks whether it is the same person; Save waits for the answer.
    @MainActor func testAFirstNameOfASavedVoiceAsksTheSamePersonQuestion() {
        let app = launchSpeakersSeed()
        app.buttons["speakersButton"].tap()
        let alex = app.buttons["speaker-alex"]
        XCTAssertTrue(alex.waitForExistence(within: 5))
        alex.tap()
        let field = app.textFields["speakerNameField"]
        XCTAssertTrue(field.waitForExistence(within: 5))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10) + "Sam")
        XCTAssertTrue(element(app, containing: "is already a saved voice").waitForExistence(within: 5))

        app.buttons["saveSpeakerName"].tap()
        XCTAssertTrue(field.exists, "Save waits until the question is answered")
        app.buttons["questionYes"].tap()
        XCTAssertEqual(field.value as? String, "Sam Rivera")
        app.buttons["saveSpeakerName"].tap()

        XCTAssertTrue(app.textFields["speakerNameField"].waitForNonExistence(within: 5), "Save closes the sheet")
        XCTAssertTrue(element(app, containing: "Sam Rivera").waitForExistence(within: 5))
    }

    /// Without consent for the speaker models, Identify speakers opens the model download screen, which asks for those
    /// models alone; the Speakers sheet records no consent of its own.
    @MainActor func testIdentifySpeakersWithoutConsentOpensTheModelDownload() {
        let app = launchSpeakersSeed()
        app.buttons["speakersButton"].tap()
        let identify = app.buttons["Identify speakers"]
        XCTAssertTrue(identify.waitForExistence(within: 5))
        identify.tap()
        let again = app.buttons["Analyze again"]
        XCTAssertTrue(again.waitForExistence(within: 5))
        again.tap()
        XCTAssertTrue(app.staticTexts["Transcribe on this device"].waitForExistence(within: 10))
        XCTAssertTrue(app.staticTexts["Telling speakers apart"].exists)
        XCTAssertFalse(app.staticTexts["Speech recognition"].exists, "Identify speakers needs no speech model")
        XCTAssertTrue(app.buttons["Download and identify speakers"].exists)
        app.buttons["Not now — keep the audio"].tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 5))
    }
}
