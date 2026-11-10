import XCTest

/// Settings and "Source code and notices" over the UI-test models: Apple's speech model installed where the system has
/// Apple speech (`DeviceUnderTest`), the speaker models not downloaded, notifications denied.
final class SettingsFlowTests: XCTestCase {
    @MainActor private func openSettings(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "library", "--notifications-denied"] + arguments
        app.launchAndWait()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 5))
        return app
    }

    /// Scrolls the screen up until `element` is on it.
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        app.scroll { element.exists && element.isHittable }
        XCTAssertTrue(element.waitForExistence(within: 2), "\(element) is not on the screen")
    }

    @MainActor private func row(_ app: XCUIApplication, startingWith title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// Any element whose label starts with `title`: a row that is not a button reads as one element.
    @MainActor private func element(_ app: XCUIApplication, startingWith title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    // ports: SettingsViewModelTest#showsTheModelRowsTheCountsTheVersionAndTheNotificationsBanner (on the screen)
    /// Where the system has no Apple speech (iOS 18) the default device has no recognizer: no picker, and the speech
    /// row says it is not available. That repeats, on purpose, the row of
    /// `testWithoutAppleSpeechOrAnotherRecognizerTheSpeechRowIsNotAvailable`; the rest of the screen is this test's own. The Whistle and Parakeet rows of iOS 18 are checked by ParakeetSuggestionTests and
    /// `testOnAParakeetDeviceTheSpeechRowShowsItsDownload`.
    @MainActor func testSettingsShowsTheModelRowsTheBannerTheCountsAndTheBundleVersion() {
        let app = openSettings()
        // In the iPad split view the list fills in after the navigation bar.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "App language")).firstMatch
            .waitForExistence(within: 5))
        XCTAssertTrue(app.staticTexts["Notifications are off"].waitForExistence(within: 5))
        XCTAssertTrue(app.buttons["Turn on"].exists)
        XCTAssertEqual(app.descendants(matching: .any)["speechLanguagePicker"].exists, DeviceUnderTest.appleSpeech,
                       "Apple Speech takes a language: Transcription offers the picker, and only then")
        let speech = element(app, startingWith: "Speech recognition")
        reveal(speech, in: app)
        if DeviceUnderTest.appleSpeech {
            XCTAssertTrue(speech.label.contains("Ready"), speech.label)
            XCTAssertTrue(speech.label.contains("Managed by iOS"), speech.label)
        } else {
            XCTAssertEqual(speech.label, "Speech recognition, Not available")
        }
        XCTAssertFalse(row(app, startingWith: "Speech recognition").exists, "a Ready or Not available row is not a button")
        XCTAssertTrue(row(app, startingWith: "Telling speakers apart").label.contains("Not downloaded"))
        XCTAssertTrue(row(app, startingWith: "Telling speakers apart").label.contains("88 MB"))
        let voices = row(app, startingWith: "Saved voices")
        reveal(voices, in: app)
        XCTAssertTrue(voices.label.contains("None yet"), voices.label)
        // With its value: on iPad the library's toolbar beside Settings has a Recently Deleted button too.
        XCTAssertTrue(row(app, startingWith: "Recently Deleted,").label.contains("Empty"))
        let version = element(app, startingWith: "Cassini talk 0.1.0")
        reveal(version, in: app)
    }

    /// On a Parakeet device the speech row shows the model's precision and its download by the shared size rule, and
    /// Transcription has no Speech language picker: Parakeet hears the language.
    @MainActor func testOnAParakeetDeviceTheSpeechRowShowsItsDownload() {
        let app = openSettings(["--parakeet"])
        // The picker would sit above this toggle, in the same section: once the toggle is there, so would it be.
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Transcribe after recording"))
            .firstMatch.waitForExistence(within: 5))
        XCTAssertFalse(app.descendants(matching: .any)["speechLanguagePicker"].exists)
        XCTAssertFalse(element(app, startingWith: "Speech language").exists)
        let speech = element(app, startingWith: "Speech recognition")
        reveal(speech, in: app)
        XCTAssertEqual(speech.label, "Speech recognition, INT8 · 444 MB, Ready")
        XCTAssertTrue(row(app, startingWith: "Telling speakers apart").label.contains("88 MB"))
    }

    /// The iOS 18 facts on a device with no recognizer that can run: no Speech language picker and no "Managed by iOS";
    /// the speech row only says it is not available.
    @MainActor func testWithoutAppleSpeechOrAnotherRecognizerTheSpeechRowIsNotAvailable() {
        let app = openSettings(["--ios18-platform"])
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Transcribe after recording"))
            .firstMatch.waitForExistence(within: 5))
        XCTAssertFalse(app.descendants(matching: .any)["speechLanguagePicker"].exists)
        XCTAssertFalse(element(app, startingWith: "Speech language").exists)
        XCTAssertFalse(element(app, startingWith: "The language of speech is chosen separately").exists)
        let speech = element(app, startingWith: "Speech recognition")
        reveal(speech, in: app)
        XCTAssertEqual(speech.label, "Speech recognition, Not available")
        XCTAssertFalse(row(app, startingWith: "Speech recognition").exists, "a Not available row is not a button")
        let speakers = row(app, startingWith: "Telling speakers apart")
        XCTAssertTrue(speakers.label.contains("88 MB"))
        // D59: the download screen does not point at the Speech language picker Settings hides.
        speakers.tap()
        XCTAssertTrue(app.staticTexts["Transcribe on this device"].waitForExistence(within: 5))
        XCTAssertTrue(app.buttons["Download"].exists)
        // The line would come with the plan, which lists the speaker models.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Telling speakers apart"))
            .firstMatch.waitForExistence(within: 5))
        XCTAssertTrue(app.staticTexts["speechLanguageLine"].staysAbsent(for: 2))
    }

    /// A Parakeet device without Ultra: its row is a button that opens the download screen with the sizes.
    @MainActor func testOnAParakeetDeviceAMissingSpeechModelOpensTheDownloadWithItsSize() {
        let app = openSettings(["--parakeet", "--models-missing"])
        let speech = row(app, startingWith: "Speech recognition")
        reveal(speech, in: app)
        XCTAssertEqual(speech.label, "Speech recognition, INT8 · 444 MB, Not downloaded")
        speech.tap()
        XCTAssertTrue(app.staticTexts["Transcribe on this device"].waitForExistence(within: 5))
        XCTAssertTrue(app.buttons["Download"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Speech recognition, 444 MB")).firstMatch
            .exists)
    }

    // ports: SettingsViewModelTest#onlyANotDownloadedOrAFailedRowOpensModelDownload (on the screen)
    @MainActor func testANotDownloadedRowOpensTheStandaloneDownload() {
        let app = openSettings()
        let speakers = row(app, startingWith: "Telling speakers apart")
        reveal(speakers, in: app)
        speakers.tap()
        XCTAssertTrue(app.staticTexts["Transcribe on this device"].waitForExistence(within: 5))
        XCTAssertTrue(app.buttons["Download"].exists, "with no note the screen offers a standalone Download")
        app.buttons["Download"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 5))
        // The fake models install nothing: agreed to and still missing, the row waits for the next transcription.
        let pending = element(app, startingWith: "Telling speakers apart")
        reveal(pending, in: app)
        XCTAssertTrue(pending.label.contains("Downloads with next transcription"), pending.label)
    }

    // ports: SettingsBehaviourTest#licenceRowsOpenAndBackClosesTheText
    @MainActor func testLicenceRowsOpenTheirTextAndBackClosesIt() {
        let app = openSettings()
        let notices = app.buttons["Source code and notices"]
        reveal(notices, in: app)
        notices.tap()
        XCTAssertTrue(app.navigationBars["Source code and notices"].waitForExistence(within: 5))
        for title in ["Cassini talk", "Third-party notices", "Model notices", "Where the models come from", "Privacy",
                      "Source code on GitHub"] {
            XCTAssertTrue(row(app, startingWith: title).exists, "\(title) row")
        }
        row(app, startingWith: "Privacy").tap()
        XCTAssertTrue(app.navigationBars["Privacy"].waitForExistence(within: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Cassini for iOS keeps")).firstMatch.exists)
        app.navigationBars["Privacy"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Source code and notices"].waitForExistence(within: 5))

        row(app, startingWith: "Cassini talk").tap()
        XCTAssertTrue(app.navigationBars["Cassini talk"].waitForExistence(within: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "GNU GENERAL PUBLIC LICENSE")).firstMatch
            .waitForExistence(within: 5))
        app.navigationBars["Cassini talk"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Source code and notices"].waitForExistence(within: 5))
        app.navigationBars["Source code and notices"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 5))
    }
}
