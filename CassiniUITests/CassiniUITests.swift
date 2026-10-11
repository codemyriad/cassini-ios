import XCTest

final class CassiniUITests: XCTestCase {
    @MainActor private func launch(seed: Bool = true, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (reset ? ["--reset-test-data"] : []) + (seed ? ["--seed-test-data"] : [])
        app.launch()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(timeout: 15))
        return app
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
        app.buttons["Done"].tap()
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
        app.buttons["Done"].tap()
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
}
