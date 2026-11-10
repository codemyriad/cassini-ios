import XCTest

/// The model download screen on a device without Apple's speech model or the speaker models: a Transcribe opens the
/// consent, its sources link opens Source code and notices with a plain Back, "Not now" goes back to the note without transcribing,
/// and "Download and transcribe" transcribes the note. Nothing is downloaded: the models are faked.
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
        // Without the speech model the Library starts with "Record now, transcribe later", which pushes the row down
        // under the capture bar.
        XCTAssertTrue(app.otherElements["banner.DL_RECORD_NOW"].waitForExistence(within: 5))
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Thoughts from the morning walk")).firstMatch
        let list = app.scrollViews.firstMatch
        let capture = app.buttons["recordButton"]
        guard list.scroll(until: {
            guard row.exists && row.isHittable else { return false }
            let frame = row.frame
            return list.frame.contains(frame) && frame.maxY <= capture.frame.minY
        }) else { XCTFail("The note did not scroll clear of the capture controls"); return }
        row.tap()
        XCTAssertTrue(app.buttons["Transcribe"].waitForExistence(within: 5))
        app.buttons["Transcribe"].tap()
        XCTAssertTrue(app.staticTexts["Transcribe on this device"].waitForExistence(within: 5))
    }

    // ports: ModelDownloadFlowTest#notDownloadedRowOpensTheConsentAndNotNowGoesBack
    @MainActor func testTranscribeOpensTheConsentItsSourcesOpenLicensesAndNotNowGoesBack() {
        let app = launchWithoutModels()
        transcribeTheWalk(app)
        XCTAssertTrue(app.buttons["Download and transcribe"].exists)
        XCTAssertTrue(app.staticTexts["Speech recognition"].exists, "iOS does not tell the size of Apple's assets")
        XCTAssertTrue(part(app, "Telling speakers apart").label.hasSuffix("88 MB"))
        XCTAssertFalse(text(app, containing: "one-time download of about").exists, "no total without the speech size")
        // D59 (2): Apple Speech hears only the language set in Settings, so the screen names it and where to change it.
        let language = app.staticTexts["speechLanguageLine"]
        XCTAssertTrue(language.exists)
        XCTAssertTrue(language.label.hasPrefix("Cassini recognises speech in "), language.label)
        XCTAssertTrue(language.label.hasSuffix(". To transcribe another language, change it in Settings › Speech language."),
                      language.label)
        let name = language.label.dropFirst("Cassini recognises speech in ".count).prefix { $0 != "." }
        XCTAssertTrue(!name.isEmpty && !name.contains("-") && !name.contains("_"),
                      "the language's name, as Settings shows it, not its code: \(name)")

        app.buttons["Where the models come from · Privacy"].tap()
        XCTAssertTrue(app.navigationBars["Source code and notices"].waitForExistence(within: 5))
        app.navigationBars["Source code and notices"].buttons.element(boundBy: 0).tap()

        let notNow = app.buttons["Not now — keep the audio"]
        XCTAssertTrue(notNow.waitForExistence(within: 5))
        notNow.tap()
        XCTAssertTrue(app.buttons["Transcribe"].waitForExistence(within: 5), "back on the note, still audio only")
        XCTAssertTrue(app.staticTexts["Transcribe on this device"].waitForNonExistence(within: 5))
    }

    // ports: ModelDownloadViewModelTest#showsTheMissingPartsWithTheirSizesAndTheSpaceTheInstallNeeds (on the screen)
    /// On a Parakeet device each part shows its download by the shared size rule, and the body their total: Ultra and
    /// its speech detector, the two speaker models, and the room the whole install needs.
    @MainActor func testAParakeetDeviceShowsEachPartsDownloadAndTheTotal() {
        let app = launchWithoutModels(parakeet: true)
        transcribeTheWalk(app)
        XCTAssertEqual(part(app, "Speech recognition").label, "Speech recognition, 444 MB")
        XCTAssertEqual(part(app, "Telling speakers apart").label, "Telling speakers apart, 88 MB")
        // The figure keeps its unit on its line: a no-break space.
        XCTAssertTrue(text(app, containing: "Cassini needs a one-time download of about 532\u{00A0}MB.").exists)
        XCTAssertTrue(text(app, containing: "Needs about 1.2 GB free while installing.").exists)
        XCTAssertFalse(app.staticTexts["speechLanguageLine"].exists, "Parakeet hears the language")
        XCTAssertTrue(app.buttons["Download and transcribe"].exists)
    }

    @MainActor private func part(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
    }

    @MainActor private func text(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor func testDownloadAndTranscribeTranscribesTheNote() {
        let app = launchWithoutModels()
        transcribeTheWalk(app)
        app.buttons["Download and transcribe"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "What if being productive")).firstMatch
            .waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts["Transcribe on this device"].waitForNonExistence(within: 5))
    }
}
