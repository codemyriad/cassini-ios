import XCTest

final class CassiniUITests: XCTestCase {
    @MainActor private func launch(seed: Bool = true, reset: Bool = true, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (reset ? ["--reset-test-data"] : []) + (seed ? ["--seed-test-data"] : []) + arguments
        app.launch()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(timeout: 15))
        return app
    }
    @MainActor private func goBack(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }
    @MainActor private func openFixture(_ app: XCUIApplication) {
        let note = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A quieter kind of productivity")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 5)); note.tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(timeout: 5))
    }
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor func testEmptyLibraryAndSettings() {
        let app = launch(seed: false)
        XCTAssertTrue(app.buttons["recordButton"].exists)
        capture("Empty library")
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Allow speech model downloads"].exists)
        capture("Settings")
        goBack(app)
        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(timeout: 5))
    }
    @MainActor func testSearchPlaybackRenameAndPersistence() {
        let app = launch()
        capture("Library")
        let search = app.textFields["librarySearch"]
        search.tap(); search.typeText("Thursday")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A quieter kind of productivity")).firstMatch.exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Thoughts from the morning walk")).firstMatch.exists)
        app.buttons["Clear search"].tap()
        openFixture(app)
        capture("Transcript")
        app.buttons["playButton"].tap()
        XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 3))
        app.buttons["Pause playback"].tap()
        app.buttons["Recording actions"].tap()
        app.buttons["Rename"].tap()
        let title = app.textFields["recordingTitleField"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 100))
        title.typeText("A saved conversation")
        app.buttons["Save"].tap()
        XCTAssertEqual(app.staticTexts["noteTitle"].label, "A saved conversation")
        app.terminate()
        let reopened = launch(seed: false, reset: false)
        XCTAssertTrue(reopened.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A saved conversation")).firstMatch.exists)
    }
    @MainActor func testTrashAndRestore() {
        let app = launch()
        openFixture(app)
        app.buttons["Recording actions"].tap()
        app.buttons["Move to Recently Deleted"].tap()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A quieter kind of productivity")).firstMatch.exists)
        app.buttons["Recently Deleted"].tap()
        XCTAssertTrue(app.buttons["Restore"].waitForExistence(timeout: 5))
        app.buttons["Restore"].tap()
        goBack(app)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A quieter kind of productivity")).firstMatch.waitForExistence(timeout: 5))
    }
    @MainActor func testTranscriptionConsentDoesNotStartWhenCancelled() {
        let app = launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Thoughts from the morning walk")).firstMatch.tap()
        app.buttons["Transcribe"].tap()
        XCTAssertTrue(app.alerts["Transcribe on this device"].waitForExistence(timeout: 5))
        app.alerts.buttons["Not now"].tap()
        XCTAssertTrue(app.buttons["Transcribe"].exists)
    }
    @MainActor func testRecordingOrUnavailableInputRecovery() {
        let app = launch(seed: false)
        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            return false
        }
        app.buttons["recordButton"].tap()
        if !app.buttons["Pause"].waitForExistence(timeout: 8) {
            let alert = app.alerts["Something needs attention"]
            XCTAssertTrue(alert.exists)
            XCTAssertTrue(alert.staticTexts["No microphone is available. Connect an audio input and try again."].exists || alert.staticTexts["The microphone could not start. Check your audio connection and try again."].exists)
            capture("Microphone unavailable")
            alert.buttons["OK"].tap()
            XCTAssertTrue(app.buttons["recordButton"].isEnabled)
            XCTAssertTrue(app.buttons["Import"].isEnabled)
            return
        }
        capture("Recording")
        app.buttons["Pause"].tap()
        XCTAssertTrue(app.buttons["Resume"].exists)
        app.buttons["Resume"].tap()
        XCTAssertTrue(app.buttons["Pause"].exists)
        app.buttons["finishRecording"].tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["playButton"].isEnabled)
        app.buttons["playButton"].tap()
        XCTAssertTrue(app.buttons["Pause playback"].waitForExistence(timeout: 3))
    }
    @MainActor func testSpeakerRenameAppliesToAllPassagesAndPersists() {
        let app = launch(); openFixture(app)
        app.buttons["speakersButton"].tap()
        XCTAssertTrue(app.navigationBars["Speakers"].waitForExistence(timeout: 5))
        let alex = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alex")).firstMatch
        XCTAssertTrue(alex.waitForExistence(timeout: 5)); alex.tap()
        let field = app.textFields["speakerNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30)); field.typeText("Alice")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alice")).firstMatch.waitForExistence(timeout: 5))
        capture("Speakers")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts.matching(identifier: "Alice").firstMatch.exists)
        app.terminate()
        let reopened = launch(seed: false, reset: false); openFixture(reopened)
        XCTAssertTrue(reopened.staticTexts.matching(identifier: "Alice").firstMatch.exists)
    }
    @MainActor func testEmptyTrashRequiresConfirmationAndRemovesRecording() {
        let app = launch(); openFixture(app)
        app.buttons["Recording actions"].tap(); app.buttons["Move to Recently Deleted"].tap()
        XCTAssertTrue(app.buttons["Recently Deleted"].waitForExistence(timeout: 5)); app.buttons["Recently Deleted"].tap()
        XCTAssertTrue(app.buttons["Empty"].waitForExistence(timeout: 5)); app.buttons["Empty"].tap()
        XCTAssertTrue(app.alerts["Empty Recently Deleted?"].waitForExistence(timeout: 5))
        app.alerts.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Restore"].exists)
        app.buttons["Empty"].tap(); app.alerts.buttons["Delete all forever"].tap()
        XCTAssertTrue(app.staticTexts["Nothing here"].waitForExistence(timeout: 5))
    }

    @MainActor func testSeededTrashShowsDaysLeftFromTheFixedClock() {
        let app = launch(seed: false, arguments: ["--seed", "trash"])
        app.buttons["Recently Deleted"].tap()
        XCTAssertTrue(app.staticTexts["Old interview draft"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "23 days left")).firstMatch.exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "29 days left")).firstMatch.exists)
        capture("Trash")
    }
    @MainActor func testOpenFixtureOpensTheNamedNote() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed-test-data", "--open-fixture", "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"]
        app.launch()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["noteTitle"].label, "Thoughts from the morning walk")
    }
    @MainActor func testTheRecordingSeedRecordsWithoutAMicrophone() {
        let app = launch(seed: false, arguments: ["--seed", "recording"])
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 8))
        capture("Recording")
        app.buttons["finishRecording"].tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["playButton"].isEnabled)
    }
    @MainActor func testTheProcessingSeedShowsAJobInProgress() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "processing", "--open-fixture", "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Transcribing on this device…"].waitForExistence(timeout: 15))
        capture("Processing")
    }
    @MainActor func testIPadShowsTheLibraryBesideTheNote() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "split view is for regular width")
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch()
        openFixture(app)
        let search = app.textFields["librarySearch"], title = app.staticTexts["noteTitle"]
        XCTAssertTrue(search.isHittable, "the library stays beside the note")
        XCTAssertTrue(title.isHittable, "the note shows in the detail column")
        XCTAssertLessThanOrEqual(search.frame.maxX, title.frame.minX, "the library sits to the left of the note")
        capture("iPad split")
    }
}
