import XCTest

final class CassiniUITests: XCTestCase {
    @MainActor private func launch(seed: Bool = true, reset: Bool = true, arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (reset ? ["--reset-test-data"] : []) + (seed ? ["--seed-test-data"] : []) + arguments
        app.launchAndWait()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15))
        return app
    }
    @MainActor private func goBack(_ app: XCUIApplication) {
        app.navigationBars.buttons.element(boundBy: 0).tap()
    }
    @MainActor private func openFixture(_ app: XCUIApplication) {
        let note = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A quieter kind of productivity")).firstMatch
        XCTAssertTrue(note.waitForExistence(within: 5)); note.tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 5))
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
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 5))
        XCTAssertTrue(app.switches["Transcribe after recording or import"].exists)
        capture("Settings")
        goBack(app)
        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(within: 5))
    }
    @MainActor func testSearchPlaybackRenameAndPersistence() {
        let app = launch()
        capture("Library")
        let search = app.textFields["librarySearch"]
        search.tap(); search.typeText("Thursday")
        // The search answers 150 ms after the last keystroke.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A quieter kind of productivity")).firstMatch
            .waitForExistence(within: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Thoughts from the morning walk")).firstMatch
            .waitForNonExistence(within: 5))
        app.buttons["Clear search"].tap()
        openFixture(app)
        capture("Transcript")
        app.buttons["playButton"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(within: 3))
        app.buttons["Pause"].tap()
        app.buttons["More actions"].tap()
        app.buttons["Rename"].tap()
        let title = app.textFields["recordingTitleField"]
        XCTAssertTrue(title.waitForExistence(within: 5))
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 100))
        title.typeText("A saved conversation")
        app.buttons["Save"].tap()
        XCTAssertEqual(app.staticTexts["noteTitle"].label, "A saved conversation")
        app.terminate()
        let reopened = launch(seed: false, reset: false)
        XCTAssertTrue(reopened.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A saved conversation")).firstMatch.exists)
    }
    // ports: TranscriptSemanticsTest#thePlayerButtonsAreDescribedAndBigEnough
    // ports: TranscriptSemanticsTest#theSliderIsPositionWithTenSecondSteps (label and value; the steps are in PlaybackSkipTests)
    @MainActor func testThePlayerIsDescribedAndItsButtonsAreBigEnough() {
        let app = launch(); openFixture(app)
        let play = app.buttons["playButton"]
        XCTAssertTrue(play.waitForExistence(within: 5))
        XCTAssertEqual(play.label, "Play")
        XCTAssertEqual(play.value as? String, "Paused")
        let position = app.descendants(matching: .any)["playbackPosition"]
        XCTAssertEqual(position.label, "Position")
        XCTAssertEqual(position.value as? String, "00:00 of 00:24")
        for button in [play, app.buttons["Back 10 seconds"], app.buttons["Forward 10 seconds"]] {
            XCTAssertTrue(button.exists)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, button.label)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, button.label)
        }
        app.buttons["Forward 10 seconds"].tap()
        XCTAssertEqual(position.value as? String, "00:10 of 00:24")
        app.buttons["Back 10 seconds"].tap()
        XCTAssertEqual(position.value as? String, "00:00 of 00:24")
        play.tap()
        let playing = NSPredicate(format: "label == %@ AND value == %@", "Pause", "Playing")
        XCTAssertTrue(play.wait(until: playing, within: 3))
        play.tap()
        XCTAssertEqual(play.label, "Play")
        XCTAssertEqual(play.value as? String, "Paused")
    }
    @MainActor private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }
    @MainActor func testTrashAndRestore() {
        let app = launch()
        openFixture(app)
        app.buttons["More actions"].tap()
        app.buttons["Move to Recently Deleted"].tap()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 5))
        XCTAssertTrue(app.staticTexts["“A quieter kind of productivity” moved to Recently Deleted"].waitForExistence(within: 5),
                      "every move lands on the Library with its snackbar")
        XCTAssertFalse(row(app, "A quieter kind of productivity").exists)
        app.buttons["Recently Deleted"].tap()
        XCTAssertTrue(app.buttons["Restore"].waitForExistence(within: 5))
        XCTAssertTrue(app.staticTexts["Deleted today · 30 days left"].exists)
        app.buttons["Restore"].tap()
        XCTAssertTrue(app.staticTexts["Recently Deleted is empty"].waitForExistence(within: 5))
        goBack(app)
        XCTAssertTrue(row(app, "A quieter kind of productivity").waitForExistence(within: 5))
    }
    // ports: LibraryViewModelTest#trashShowsTheSnackbarAndUndoRestores
    @MainActor func testUndoOnTheSnackbarBringsTheNoteBack() {
        let app = launch()
        let note = row(app, "Thoughts from the morning walk")
        XCTAssertTrue(note.waitForExistence(within: 5))
        note.press(forDuration: 1)
        app.buttons["Move to Recently Deleted"].tap()
        let snackbar = app.staticTexts["“Thoughts from the morning walk” moved to Recently Deleted"]
        XCTAssertTrue(snackbar.waitForExistence(within: 5))
        XCTAssertFalse(row(app, "Thoughts from the morning walk").exists)
        capture("Undo snackbar")
        app.buttons["Undo"].tap()
        XCTAssertTrue(row(app, "Thoughts from the morning walk").waitForExistence(within: 5))
        XCTAssertFalse(snackbar.exists)
    }
    // ports: LibraryViewModelTest#trashOfARunningNoteAsksFirst
    @MainActor func testMovingARunningNoteAsksFirst() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "processing", "--open-fixture", "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"]
        app.launchAndWait()
        XCTAssertTrue(app.descendants(matching: .any)["progressHeadline"].waitForExistence(within: 15))
        app.buttons["More actions"].tap()
        app.buttons["Move to Recently Deleted"].tap()
        let alert = app.alerts["Stop transcription and move to Recently Deleted?"]
        XCTAssertTrue(alert.waitForExistence(within: 5))
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].exists, "Cancel keeps the note where it is")
        app.buttons["More actions"].tap()
        app.buttons["Move to Recently Deleted"].tap()
        XCTAssertTrue(alert.waitForExistence(within: 5))
        alert.buttons["Move to Recently Deleted"].tap()
        XCTAssertTrue(app.staticTexts["“Weekly planning call” moved to Recently Deleted"].waitForExistence(within: 10))
        XCTAssertFalse(row(app, "Weekly planning call").exists)
    }
    @MainActor func testTranscribeWithTheModelInstalledStartsWithoutAskingAndWritesTheTranscript() {
        let app = launch()
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Thoughts from the morning walk")).firstMatch.tap()
        app.buttons["Transcribe"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "What if being productive")).firstMatch
            .waitForExistence(within: 15))
        XCTAssertFalse(app.staticTexts["Transcribe on this device"].exists, "an installed model needs no download consent")
    }
    @MainActor func testRecordingOrUnavailableInputRecovery() {
        let app = launch(seed: false)
        addUIInterruptionMonitor(withDescription: "Microphone permission") { alert in
            if alert.buttons["Allow"].exists { alert.buttons["Allow"].tap(); return true }
            return false
        }
        app.buttons["recordButton"].tap()
        let pause = app.buttons["Pause recording"]
        let couldNotStart = app.staticTexts["Couldn’t start the microphone"]
        // Pause shows, disabled, while the microphone starts: wait until it can pause or the screen says it could not.
        XCTAssertTrue(poll(within: 8) { (pause.exists && pause.isEnabled) || couldNotStart.exists })
        if couldNotStart.exists {
            // A host without an audio input: the screen says so and offers Try again.
            XCTAssertTrue(app.buttons["Try again"].exists)
            capture("Microphone unavailable")
            app.buttons["Library"].tap()
            XCTAssertTrue(app.buttons["recordButton"].waitForExistence(within: 5))
            XCTAssertTrue(app.buttons["importButton"].isEnabled)
            return
        }
        capture("Recording")
        pause.tap()
        XCTAssertTrue(app.buttons["Resume recording"].waitForExistence(within: 3))
        app.buttons["Resume recording"].tap()
        XCTAssertTrue(pause.waitForEnabled(within: 3))
        app.buttons["finishRecording"].tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 10))
        XCTAssertTrue(app.buttons["playButton"].isEnabled)
        app.buttons["playButton"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(within: 3))
    }
    @MainActor func testSpeakerRenameAppliesToAllPassagesAndPersists() {
        let app = launch(); openFixture(app)
        app.buttons["speakersButton"].tap()
        XCTAssertTrue(app.navigationBars["Speakers"].waitForExistence(within: 5))
        let alex = app.buttons["speaker-alex"]
        XCTAssertTrue(alex.waitForExistence(within: 5)); alex.tap()
        let field = app.textFields["speakerNameField"]
        XCTAssertTrue(field.waitForExistence(within: 5))
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30)); field.typeText("Alice")
        app.buttons["saveSpeakerName"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Alice")).firstMatch.waitForExistence(within: 5))
        capture("Speakers")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Alice, at")).firstMatch.exists,
                      "the passages' headers carry the name")
        app.terminate()
        let reopened = launch(seed: false, reset: false); openFixture(reopened)
        XCTAssertTrue(reopened.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Alice, at")).firstMatch.exists)
    }
    @MainActor func testEmptyTrashRequiresConfirmationAndRemovesRecording() {
        let app = launch(); openFixture(app)
        app.buttons["More actions"].tap(); app.buttons["Move to Recently Deleted"].tap()
        XCTAssertTrue(app.buttons["Recently Deleted"].waitForExistence(within: 5)); app.buttons["Recently Deleted"].tap()
        XCTAssertTrue(app.buttons["Empty"].waitForExistence(within: 5)); app.buttons["Empty"].tap()
        let alert = app.alerts["Delete 1 note for good?"]
        XCTAssertTrue(alert.waitForExistence(within: 5))
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Restore"].exists)
        app.buttons["Empty"].tap(); alert.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["Recently Deleted is empty"].waitForExistence(within: 5))
        XCTAssertFalse(app.buttons["Empty"].exists, "Empty is hidden on an empty Recently Deleted")
    }
    @MainActor func testDeleteNowAsksAboutTheNoteAndRemovesOnlyIt() {
        let app = launch(seed: false, arguments: ["--seed", "trash"])
        app.buttons["Recently Deleted"].tap()
        XCTAssertTrue(app.staticTexts["Old interview draft"].waitForExistence(within: 5))
        app.buttons.matching(identifier: "Delete now").firstMatch.tap()
        let alert = app.alerts["Delete “Old interview draft” for good?"]
        XCTAssertTrue(alert.waitForExistence(within: 5), "the oldest deletion is on top")
        alert.buttons["Delete"].tap()
        XCTAssertTrue(app.staticTexts["Duplicate voice memo"].waitForExistence(within: 5))
        let gone = NSPredicate(format: "exists == false")
        XCTAssertTrue(app.staticTexts["Old interview draft"].wait(until: gone, within: 5))
    }

    @MainActor func testSeededTrashShowsDaysLeftFromTheFixedClock() {
        let app = launch(seed: false, arguments: ["--seed", "trash"])
        app.buttons["Recently Deleted"].tap()
        XCTAssertTrue(app.staticTexts["Old interview draft"].waitForExistence(within: 5))
        XCTAssertTrue(app.staticTexts["Deleted Oct 1 · 23 days left"].exists)
        XCTAssertTrue(app.staticTexts["Deleted yesterday · 29 days left"].exists)
        capture("Trash")
    }
    @MainActor func testOpenFixtureOpensTheNamedNote() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed-test-data", "--open-fixture", "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"]
        app.launchAndWait()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 15))
        XCTAssertEqual(app.staticTexts["noteTitle"].label, "Thoughts from the morning walk")
    }
    // ports: RecordingFlowTest (record, pause, resume, minimise, return, finish)
    @MainActor func testTheRecordingSeedRecordsWithoutAMicrophone() {
        let app = launch(seed: false, arguments: ["--seed", "recording"])
        app.buttons["recordButton"].tap()
        let pause = app.buttons["Pause recording"]
        XCTAssertTrue(pause.waitForEnabled(within: 8))
        let title = app.textFields["recordingTitle"]
        XCTAssertEqual(title.value as? String, "Voice note 8 Oct, 09:41", "the field starts with the default title")
        XCTAssertTrue(app.images["Microphone level, last 7 seconds"].exists || app.otherElements["Microphone level, last 7 seconds"].exists)
        XCTAssertTrue(app.staticTexts["PCM 48 kHz"].exists)
        capture("Recording")
        pause.tap()
        XCTAssertTrue(app.buttons["Resume recording"].waitForExistence(within: 3))
        app.buttons["Resume recording"].tap()
        XCTAssertTrue(pause.waitForEnabled(within: 3))
        app.buttons["Library"].tap()
        let returnButton = app.buttons["recordButton"]
        XCTAssertTrue(returnButton.waitForExistence(within: 5))
        XCTAssertEqual(returnButton.label, "Return to recording", "the recording continues in the Library")
        // Back through the Library's card, which only shows the screen: it still minimises and finishes.
        let card = app.buttons["activeRecordingCard"]
        XCTAssertTrue(card.waitForExistence(within: 5))
        card.tap()
        XCTAssertTrue(app.buttons["finishRecording"].waitForExistence(within: 5))
        app.buttons["Library"].tap()
        XCTAssertTrue(card.waitForExistence(within: 5), "minimised again")
        card.tap()
        XCTAssertTrue(app.buttons["finishRecording"].waitForExistence(within: 5))
        app.buttons["finishRecording"].tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 10))
        XCTAssertEqual(app.staticTexts["noteTitle"].label, "Voice note 8 Oct, 09:41")
        XCTAssertTrue(app.buttons["playButton"].isEnabled)
    }
    @MainActor func testTheProcessingSeedShowsAJobInProgress() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "processing", "--open-fixture", "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"]
        app.launchAndWait()
        let headline = app.descendants(matching: .any)["progressHeadline"]
        XCTAssertTrue(headline.waitForExistence(within: 15))
        let frozen = NSPredicate(format: "label == %@", "Finding words, 60%")
        XCTAssertTrue(headline.wait(until: frozen, within: 10), headline.label)
        XCTAssertTrue(app.buttons["Stop and keep progress"].exists)
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
