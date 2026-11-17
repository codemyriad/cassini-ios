import XCTest

/// The model download screen on a device without Apple's speech model or the speaker models: a Transcribe opens the
/// consent, its sources link opens Source code and notices with a plain Back, "Not now" goes back to the note without transcribing,
/// and "Download and transcribe" transcribes the note. Nothing is downloaded: the models are faked. Where the system
/// has no Apple speech (`DeviceUnderTest`), the device is a Parakeet one, whose download the screen then shows.
final class ModelDownloadFlowTests: XCTestCase {
    /// With `parakeet` the fake transcriber stands for Parakeet Ultra, as on a device that can hold it.
    @MainActor private func launchWithoutModels(parakeet: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "library", "--models-missing"]
            + (parakeet ? ["--parakeet"] : [])
        app.launchAndWait()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15))
        return app
    }

    @MainActor private func transcribeTheWalk(_ app: XCUIApplication) {
        // The download banner pushes this row down; scroll it clear of the floating notice and capture bar.
        XCTAssertTrue(app.otherElements["banner.DL_RECORD_NOW"].waitForExistence(within: 5))
        let row = app.scrolledLibraryRow("Thoughts from the morning walk")
        row.tap()
        XCTAssertTrue(app.buttons["Transcribe"].waitForExistence(within: 5))
        app.buttons["Transcribe"].tap()
        XCTAssertTrue(app.staticTexts["modelDownloadTitle"].waitForExistence(within: 5))
    }

    // ports: ModelDownloadFlowTest#notDownloadedRowOpensTheConsentAndNotNowGoesBack
    @MainActor func testTranscribeOpensTheConsentItsSourcesOpenLicensesAndNotNowGoesBack() {
        let app = launchWithoutModels(parakeet: !DeviceUnderTest.appleSpeech)
        transcribeTheWalk(app)
        XCTAssertTrue(app.buttons["Download and transcribe"].exists)
        XCTAssertTrue(part(app, "Telling speakers apart").label.hasSuffix("62 MB"))
        let language = app.staticTexts["speechLanguageLine"]
        if DeviceUnderTest.appleSpeech {
            XCTAssertTrue(app.staticTexts["Speech recognition"].exists, "iOS does not tell the size of Apple's assets")
            XCTAssertFalse(text(app, containing: "one-time download of about").exists, "no total without the speech size")
            // D59 (2): Apple Speech hears only the language set in Settings, so the screen names it and where to change it.
            XCTAssertTrue(language.exists)
            XCTAssertTrue(language.label.hasPrefix("Cassini recognises speech in "), language.label)
            XCTAssertTrue(language.label.hasSuffix(". To transcribe another language, change it in Settings › Speech language."),
                          language.label)
            let name = language.label.dropFirst("Cassini recognises speech in ".count).prefix { $0 != "." }
            XCTAssertTrue(!name.isEmpty && !name.contains("-") && !name.contains("_"),
                          "the language's name, as Settings shows it, not its code: \(name)")
        } else {
            XCTAssertEqual(part(app, "Speech recognition").label, "Speech recognition, 444 MB")
            XCTAssertTrue(text(app, containing: "one-time download of 532\u{00A0}MB.").exists)
            XCTAssertFalse(language.exists, "Parakeet hears the language")
        }

        app.buttons["modelDownloadSources"].tap()
        XCTAssertTrue(app.navigationBars["Where the models come from"].waitForExistence(within: 5))
        app.navigationBars["Where the models come from"].buttons.element(boundBy: 0).tap()

        let notNow = app.buttons["modelDownloadNotNow"]
        XCTAssertTrue(notNow.waitForExistence(within: 5))
        notNow.tap()
        XCTAssertTrue(app.buttons["Transcribe"].waitForExistence(within: 5), "back on the note, still audio only")
        XCTAssertTrue(app.staticTexts["modelDownloadTitle"].waitForNonExistence(within: 5))
    }

    // ports: ModelDownloadViewModelTest#showsTheMissingPartsWithTheirSizesAndTheSpaceTheInstallNeeds (on the screen)
    /// On a Parakeet device each part shows its download by the shared size rule, and the body their total: Ultra and
    /// its speech detector, the two speaker models, and the room the whole install needs.
    @MainActor func testAParakeetDeviceShowsEachPartsDownloadAndTheTotal() {
        let app = launchWithoutModels(parakeet: true)
        transcribeTheWalk(app)
        XCTAssertEqual(part(app, "Speech recognition").label, "Speech recognition, 444 MB")
        XCTAssertEqual(part(app, "Telling speakers apart").label, "Telling speakers apart, 62 MB")
        XCTAssertEqual(part(app, "Recognising saved voices").label, "Recognising saved voices, 26 MB")
        // The figure keeps its unit on its line: a no-break space.
        XCTAssertTrue(text(app, containing: "Cassini needs a one-time download of 532\u{00A0}MB.").exists)
        XCTAssertTrue(text(app, containing: "Needs about 1.2 GB free while it installs.").exists)
        XCTAssertFalse(app.staticTexts["speechLanguageLine"].exists, "Parakeet hears the language")
        XCTAssertTrue(app.buttons["Download and transcribe"].exists)
    }

    @MainActor private func part(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    @MainActor private func text(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor func testCloseKeepsTheRecordingAndCanReopenTheOffer() {
        let app = launchWithoutModels(parakeet: true)
        transcribeTheWalk(app)
        app.buttons["closeModelDownload"].tap()
        XCTAssertTrue(app.buttons["Transcribe"].waitForExistence(within: 15))
        XCTAssertFalse(app.staticTexts["modelDownloadTitle"].exists)
        app.buttons["Transcribe"].tap()
        XCTAssertTrue(app.staticTexts["modelDownloadTitle"].waitForExistence(within: 15))
    }

    @MainActor func testDownloadAndTranscribeTranscribesTheNote() {
        let app = launchWithoutModels(parakeet: !DeviceUnderTest.appleSpeech)
        transcribeTheWalk(app)
        app.buttons["Download and transcribe"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "What if being productive")).firstMatch
            .waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts["modelDownloadTitle"].waitForNonExistence(within: 5))
    }
}
