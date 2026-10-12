import XCTest

/// The model download screen on a device without Apple's speech model or the speaker models: a Transcribe opens the
/// consent, its sources link opens Licenses with a plain Back, "Not now" goes back to the note without transcribing,
/// and "Download and transcribe" transcribes the note. Nothing is downloaded: the models are faked.
final class ModelDownloadFlowTests: XCTestCase {
    @MainActor private func launchWithoutModels() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "library", "--models-missing"]
        app.launch()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func transcribeTheWalk(_ app: XCUIApplication) {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Thoughts from the morning walk")).firstMatch.tap()
        XCTAssertTrue(app.buttons["Transcribe"].waitForExistence(timeout: 5))
        app.buttons["Transcribe"].tap()
        XCTAssertTrue(app.staticTexts["Transcribe on this device"].waitForExistence(timeout: 5))
    }

    // ports: ModelDownloadFlowTest#notDownloadedRowOpensTheConsentAndNotNowGoesBack
    @MainActor func testTranscribeOpensTheConsentItsSourcesOpenLicensesAndNotNowGoesBack() {
        let app = launchWithoutModels()
        transcribeTheWalk(app)
        XCTAssertTrue(app.buttons["Download and transcribe"].exists)
        XCTAssertTrue(app.staticTexts["Speech recognition"].exists)
        XCTAssertTrue(app.staticTexts["Telling speakers apart"].exists)

        app.buttons["Where the models come from · Privacy"].tap()
        XCTAssertTrue(app.navigationBars["Licenses"].waitForExistence(timeout: 5))
        app.navigationBars["Licenses"].buttons.element(boundBy: 0).tap()

        let notNow = app.buttons["Not now — keep the audio"]
        XCTAssertTrue(notNow.waitForExistence(timeout: 5))
        notNow.tap()
        XCTAssertTrue(app.buttons["Transcribe"].waitForExistence(timeout: 5), "back on the note, still audio only")
        XCTAssertFalse(app.staticTexts["Transcribe on this device"].exists)
    }

    @MainActor func testDownloadAndTranscribeTranscribesTheNote() {
        let app = launchWithoutModels()
        transcribeTheWalk(app)
        app.buttons["Download and transcribe"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "What if being productive")).firstMatch
            .waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["Transcribe on this device"].exists)
    }
}
