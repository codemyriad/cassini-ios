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

    /// Scrolls the screen up until the whole of `element` is on it. Hittable is not enough: an element cut by the bottom
    /// edge is hittable, and its tap point can fall in the home indicator's strip, where the tap does nothing. On an
    /// iPhone 16 (iOS 18.2) "Source code and notices" stopped at y 827.7–865.7 of 852 and the tap at y 846.7 did not
    /// open the notices.
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        app.scroll { element.exists && element.isHittable && app.frame.contains(element.frame) }
        XCTAssertTrue(element.waitForExistence(within: 2), "\(element) is not on the screen")
    }

    @MainActor private func row(_ app: XCUIApplication, startingWith title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// Any element whose label starts with `title`: a row that is not a button reads as one element.
    @MainActor private func element(_ app: XCUIApplication, startingWith title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    @MainActor private func downloadAndAssertRequests(_ app: XCUIApplication, group: String) {
        app.buttons["Download"].tap()
        let requested = app.staticTexts["uiTestState-modelInstallRequested"]
        XCTAssertTrue(requested.waitForExistence(within: 15), "No installer received a request")
        let completed = app.staticTexts["uiTestState-modelInstallCompleted"]
        XCTAssertTrue(completed.waitForExistence(within: 15), "The install queue never completed")
        // The completion marker is emitted only once the entire queue has drained and refreshed.
        // Exact journals after that event also exclude unrelated and duplicate requests.
        XCTAssertEqual(requested.value as? String, group)
        XCTAssertEqual(completed.value as? String,
                       "requested=\(group);completed=\(group);consented=\(group)")
    }

    // ports: SettingsViewModelTest#showsTheModelRowsTheCountsTheVersionAndTheNotificationsBanner (on the screen)
    /// Where the system has no Apple speech (iOS 18) the default device has no recognizer: no picker, and the speech
    /// row says it is not available. That repeats, on purpose, the row of
    /// `testWithoutAppleSpeechOrAnotherRecognizerTheSpeechRowIsNotAvailable`; the rest of the screen is this test's own. The Whistle and Parakeet rows of iOS 18 are checked by ParakeetSuggestionTests and
    /// `testOnAParakeetDeviceTheSpeechRowShowsItsDownload`.
    @MainActor func testSettingsShowsTheModelRowsTheBannerTheCountsAndTheBundleVersion() {
        let app = openSettings()
        XCTAssertTrue(app.staticTexts["uiTestState-settingsLoaded"].waitForExistence(within: 15))
        XCTAssertTrue(app.buttons["transcriptionRow"].exists)
        XCTAssertTrue(app.buttons["speakersRow"].label.contains("On"))
        XCTAssertTrue(app.buttons["savedVoicesRow"].label.contains("0 people"))
        XCTAssertTrue(app.buttons["recentlyDeletedRow"].label.contains("0 meetings"))
        XCTAssertFalse(app.switches.firstMatch.exists, "Choices live one level below the map")
        XCTAssertFalse(app.staticTexts["On-device models"].exists)
        let version = element(app, startingWith: "Cassini talk 0.1.0")
        reveal(version, in: app)
        let language = app.buttons["appLanguageRow"]
        reveal(language, in: app)
        XCTAssertTrue(language.label.contains("English"))
        app.scroll(up: false) { app.buttons["transcriptionRow"].isHittable }
        openPage(app, "transcriptionRow", title: "Transcription")
        XCTAssertEqual(app.descendants(matching: .any)["speechLanguagePicker"].exists, DeviceUnderTest.appleSpeech)
        let speech = element(app, startingWith: "Speech recognition")
        XCTAssertTrue(speech.waitForExistence(within: 15))
        if DeviceUnderTest.appleSpeech {
            XCTAssertTrue(speech.label.contains("Ready"))
            XCTAssertTrue(speech.label.contains("Managed by iOS"))
        } else { XCTAssertEqual(speech.label, "Speech recognition, Not available") }
    }

    @MainActor private func openPage(_ app: XCUIApplication, _ id: String, title: String) {
        let button = app.buttons[id]
        reveal(button, in: app)
        button.tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts["uiTestState-settingsLoaded"].waitForExistence(within: 15))
    }

    /// On a Parakeet device the speech row shows the model's precision and its download by the shared size rule, and
    /// Transcription has no Speech language picker: Parakeet hears the language.
    @MainActor func testOnAParakeetDeviceTheSpeechRowShowsItsDownload() {
        let app = openSettings(["--parakeet"])
        openPage(app, "transcriptionRow", title: "Transcription")
        // The picker would sit above this toggle, in the same section: once the toggle is there, so would it be.
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Transcribe right away"))
            .firstMatch.waitForExistence(within: 5))
        XCTAssertFalse(app.descendants(matching: .any)["speechLanguagePicker"].exists)
        XCTAssertFalse(element(app, startingWith: "Speech language").exists)
        let speech = element(app, startingWith: "Speech recognition")
        reveal(speech, in: app)
        XCTAssertEqual(speech.label, "Speech recognition, INT8 · 444 MB, Ready")
    }

    /// The iOS 18 facts on a device with no recognizer that can run: no Speech language picker and no "Managed by iOS";
    /// the speech row only says it is not available.
    @MainActor func testWithoutAppleSpeechOrAnotherRecognizerTheSpeechRowIsNotAvailable() {
        let app = openSettings(["--ios18-platform"])
        openPage(app, "transcriptionRow", title: "Transcription")
        XCTAssertTrue(app.switches.matching(NSPredicate(format: "label BEGINSWITH %@", "Transcribe right away"))
            .firstMatch.waitForExistence(within: 5))
        XCTAssertFalse(app.descendants(matching: .any)["speechLanguagePicker"].exists)
        XCTAssertFalse(element(app, startingWith: "Speech language").exists)
        XCTAssertFalse(element(app, startingWith: "The language of speech is chosen separately").exists)
        let speech = element(app, startingWith: "Speech recognition")
        reveal(speech, in: app)
        XCTAssertEqual(speech.label, "Speech recognition, Not available")
        XCTAssertFalse(row(app, startingWith: "Speech recognition").exists, "a Not available row is not a button")
        app.navigationBars.buttons.firstMatch.tap()
        openPage(app, "speakersRow", title: "Speakers")
        let speakers = row(app, startingWith: "Telling speakers apart")
        XCTAssertTrue(speakers.label.contains("88 MB"))
        // D59: the download screen does not point at the Speech language picker Settings hides.
        speakers.tap()
        XCTAssertTrue(app.staticTexts["Transcribe on this device"].waitForExistence(within: 5))
        XCTAssertTrue(app.buttons["Download"].exists)
        // The line would come with the plan, which lists the speaker models.
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Telling speakers apart"))
            .firstMatch.waitForExistence(within: 5))
        XCTAssertFalse(app.staticTexts["speechLanguageLine"].exists)
    }

    /// A Parakeet device without Ultra: its row is a button that opens the download screen with the sizes.
    @MainActor func testOnAParakeetDeviceAMissingSpeechModelOpensTheDownloadWithItsSize() {
        let app = openSettings(["--parakeet", "--models-missing"])
        openPage(app, "transcriptionRow", title: "Transcription")
        let speech = row(app, startingWith: "Speech recognition")
        reveal(speech, in: app)
        XCTAssertEqual(speech.label, "Speech recognition, INT8 · 444 MB, Not downloaded")
        speech.tap()
        XCTAssertTrue(app.staticTexts["Transcribe on this device"].waitForExistence(within: 5))
        XCTAssertTrue(app.buttons["Download"].exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label == %@", "Speech recognition, 444 MB")).firstMatch
            .exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Telling speakers apart"))
            .firstMatch.exists, "The speech row downloads only speech")
        downloadAndAssertRequests(app, group: "speech")
    }

    @MainActor func testEachSpeakerRowDownloadsOnlyTheSpeakerBundleWhileSpeechIsMissing() {
        for label in ["Telling speakers apart", "Recognising saved voices"] {
            let app = openSettings(["--parakeet", "--models-missing"])
            openPage(app, "speakersRow", title: "Speakers")
            let selected = row(app, startingWith: label)
            reveal(selected, in: app)
            selected.tap()
            XCTAssertTrue(app.buttons["Download"].waitForExistence(within: 5))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Telling speakers apart"))
                .firstMatch.exists)
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Speech recognition"))
                .firstMatch.exists, "A speaker row must not add the missing speech model")
            XCTAssertFalse(app.staticTexts["speechLanguageLine"].exists)
            downloadAndAssertRequests(app, group: "speakers")
            XCTAssertTrue(app.navigationBars["Speakers"].waitForExistence(within: 5))
            let pending = element(app, startingWith: "Telling speakers apart")
            reveal(pending, in: app)
            XCTAssertTrue(pending.label.contains("Downloads with next transcription"), pending.label)
            app.navigationBars.buttons.firstMatch.tap()
            openPage(app, "transcriptionRow", title: "Transcription")
            XCTAssertTrue(row(app, startingWith: "Speech recognition").label.contains("Not downloaded"))
            app.terminate()
        }
    }

    // ports: SettingsViewModelTest#onlyANotDownloadedOrAFailedRowOpensModelDownload (on the screen)
    @MainActor func testANotDownloadedRowOpensTheStandaloneDownload() {
        let app = openSettings()
        openPage(app, "speakersRow", title: "Speakers")
        let speakers = row(app, startingWith: "Telling speakers apart")
        reveal(speakers, in: app)
        speakers.tap()
        XCTAssertTrue(app.staticTexts["Transcribe on this device"].waitForExistence(within: 5))
        XCTAssertTrue(app.buttons["Download"].exists, "with no note the screen offers a standalone Download")
        app.buttons["Download"].tap()
        XCTAssertTrue(app.navigationBars["Speakers"].waitForExistence(within: 5))
        // The fake models install nothing: agreed to and still missing, the row waits for the next transcription.
        let pending = element(app, startingWith: "Telling speakers apart")
        reveal(pending, in: app)
        XCTAssertTrue(pending.label.contains("Downloads with next transcription"), pending.label)
    }

    @MainActor func testSpeakerChoicesPersistAndAboutOpensPrivacyDirectly() {
        let app = openSettings()
        openPage(app, "speakersRow", title: "Speakers")
        let recognition = app.switches["recogniseSavedVoicesToggle"]
        XCTAssertTrue(recognition.waitForValue("1"))
        recognition.switches.firstMatch.tap()
        XCTAssertTrue(recognition.waitForValue("0"))
        XCTAssertEqual(app.switches["autoNameVoicesToggle"].value as? String, "0")
        app.launchArguments = ["--ui-testing", "--seed", "library"]
        app.launchAndWait(fresh: true)
        app.buttons["settingsButton"].tap()
        openPage(app, "speakersRow", title: "Speakers")
        XCTAssertTrue(app.switches["recogniseSavedVoicesToggle"].waitForValue("0"))
        app.navigationBars.buttons.firstMatch.tap()
        openPage(app, "aboutRow", title: "About")
        XCTAssertTrue(app.descendants(matching: .any)["aboutHelp"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["aboutSourceCode"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "{year}")).firstMatch.exists)
        app.buttons["aboutPrivacy"].tap()
        XCTAssertTrue(app.navigationBars["Privacy"].waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Cassini for iOS keeps"))
            .firstMatch.waitForExistence(within: 15))
    }

    // ports: SettingsBehaviourTest#licenceRowsOpenAndBackClosesTheText
    @MainActor func testLicenceRowsOpenTheirTextAndBackClosesIt() {
        let app = openSettings()
        openPage(app, "aboutRow", title: "About")
        let notices = app.buttons["aboutLicences"]
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
        XCTAssertTrue(app.navigationBars["About"].waitForExistence(within: 5))
    }
}
