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
        XCTAssertTrue(app.scrollViews["libraryScroll"].waitForExistence(within: 5))
        XCTAssertEqual(app.descendants(matching: .any)["libraryHeading"].label, "All meetings", "the Library names its meeting list")
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
        app.buttons["Share and more"].tap()
        app.buttons["Rename"].tapWhenSettled()
        let title = app.textFields["renameField"]
        XCTAssertTrue(title.waitForExistence(within: 5))
        title.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        title.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 100))
        title.typeText("A saved conversation")
        XCTAssertTrue(title.waitForValue("A saved conversation"), "the field holds \(String(describing: title.value))")
        app.buttons["Save"].tap()
        let noteTitle = app.staticTexts["noteTitle"]
        XCTAssertTrue(noteTitle.wait(until: NSPredicate(format: "label == %@", "A saved conversation"), within: 5),
                      "the title reads \(noteTitle.label)")
        app.terminate()
        let reopened = launch(seed: false, reset: false)
        XCTAssertTrue(reopened.buttons.matching(NSPredicate(format: "label CONTAINS %@", "A saved conversation")).firstMatch
            .waitForExistence(within: 5))
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
        app.buttons["Share and more"].tap()
        app.buttons["Move to Recently Deleted"].tapWhenSettled()
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
        app.buttons["Move to Recently Deleted"].tapWhenSettled()
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
            + DeviceUnderTest.workingSpeech
        app.launchAndWait()
        XCTAssertTrue(app.buttons["transcribingDetails"].waitForExistence(within: 15))
        // The seed's job reports three results a little over a second apart, and each one rebuilds an open menu, which
        // drops a tap that lands then. Its last result is 29:53 processed; after it the job is frozen.
        XCTAssertTrue(app.staticTexts["uiTestState-transcribingAudioDone"].waitForValue("29:53 of 48:13"))
        app.buttons["Share and more"].tap()
        app.buttons["Move to Recently Deleted"].tapWhenSettled()
        let alert = app.alerts["Stop transcription and move to Recently Deleted?"]
        XCTAssertTrue(alert.waitForExistence(within: 5))
        alert.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].exists, "Cancel keeps the note where it is")
        app.buttons["Share and more"].tap()
        app.buttons["Move to Recently Deleted"].tapWhenSettled()
        XCTAssertTrue(alert.waitForExistence(within: 5))
        alert.buttons["Move to Recently Deleted"].tap()
        XCTAssertTrue(app.staticTexts["“Weekly planning call” moved to Recently Deleted"].waitForExistence(within: 10))
        XCTAssertFalse(row(app, "Weekly planning call").exists)
    }
    @MainActor func testTranscribeWithTheModelInstalledStartsWithoutAskingAndWritesTheTranscript() {
        let app = launch(arguments: DeviceUnderTest.workingSpeech)
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
        // The permission alert is answered here too: the monitor above only runs when the test touches the app.
        // Answering it took 4 to 7 s in passing runs (springboard is slow to look at), and on a busy machine the
        // microphone can take about 30 s to fail to start, so the wait is a minute.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        XCTAssertTrue(poll(within: 60) {
            if allow.exists { allow.tap() }
            return (pause.exists && pause.isEnabled) || couldNotStart.exists
        }, "Allow \(allow.exists), Pause \(pause.exists) enabled \(pause.exists && pause.isEnabled), "
           + "could not start \(couldNotStart.exists), record \(app.buttons["recordButton"].exists)")
        if couldNotStart.exists {
            // A host without an audio input: the screen says so and offers Try again.
            XCTAssertTrue(app.buttons["Try again"].exists)
            capture("Microphone unavailable")
            app.buttons["recordingAllMeetings"].tap()
            XCTAssertTrue(app.buttons["recordButton"].waitForExistence(within: 5))
            XCTAssertTrue(app.buttons["importButton"].isEnabled)
            return
        }
        capture("Recording")
        pause.tap()
        XCTAssertTrue(app.buttons["Resume recording"].waitForExistence(within: 3))
        app.buttons["Resume recording"].tap()
        XCTAssertTrue(pause.waitForEnabled(within: 3))
        app.buttons["stopRecording"].tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 10))
        XCTAssertTrue(app.buttons["playButton"].waitForEnabled(within: 5), "the sealed recording plays")
        app.buttons["playButton"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(within: 3))
    }
    @MainActor func testSpeakerRenameAppliesToAllPassagesAndPersists() {
        let app = launch(); openFixture(app)
        app.openNoteSpeakers()
        XCTAssertTrue(app.navigationBars["Speakers"].waitForExistence(within: 5))
        let alex = app.buttons["speaker-alex"]
        XCTAssertTrue(alex.waitForExistence(within: 5)); alex.tap()
        let field = app.textFields["speakerNameField"]
        XCTAssertTrue(field.waitForExistence(within: 5))
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30)); field.typeText("Alice")
        XCTAssertTrue(field.waitForValue("Alice"), "the field holds \(String(describing: field.value))")
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
        app.buttons["Share and more"].tap(); app.buttons["Move to Recently Deleted"].tap()
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
        XCTAssertTrue(app.staticTexts["Deleted 1 Oct · 23 days left"].exists)
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
        app.buttons["recordingAllMeetings"].tap()
        let returnButton = app.buttons["recordButton"]
        XCTAssertTrue(returnButton.waitForExistence(within: 5))
        XCTAssertEqual(returnButton.label, "Return to recording", "the recording continues in the Library")
        // Back through the Library's card, which only shows the screen: it still minimises and finishes.
        let card = app.buttons["activeRecordingCard"]
        XCTAssertTrue(card.waitForExistence(within: 5))
        card.tap()
        XCTAssertTrue(app.buttons["stopRecording"].waitForExistence(within: 5))
        app.buttons["recordingAllMeetings"].tap()
        XCTAssertTrue(card.waitForExistence(within: 5), "minimised again")
        card.tap()
        XCTAssertTrue(app.buttons["stopRecording"].waitForExistence(within: 5))
        app.buttons["stopRecording"].tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 10))
        XCTAssertEqual(app.staticTexts["noteTitle"].label, "Voice note 8 Oct, 09:41")
        XCTAssertTrue(app.buttons["playButton"].waitForEnabled(within: 5), "the sealed recording plays")
    }
    @MainActor func testTheProcessingSeedShowsAJobInProgress() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "processing", "--open-fixture", "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"]
            + DeviceUnderTest.workingSpeech
        app.launchAndWait()
        let details = app.buttons["transcribingDetails"]
        let stop = app.buttons["transcribingStop"]
        XCTAssertTrue(details.waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts["uiTestState-transcribingAudioDone"].waitForValue("29:53 of 48:13"))
        XCTAssertTrue(details.label.hasPrefix("Transcribing · "), details.label)
        XCTAssertEqual(details.value as? String, "50%")
        XCTAssertEqual(stop.label, "Stop and keep progress")
        XCTAssertGreaterThanOrEqual(details.frame.height, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(stop.frame.width, 44 - 0.001)
        XCTAssertGreaterThanOrEqual(stop.frame.height, 44 - 0.001)
        XCTAssertFalse(details.frame.intersects(stop.frame), "the details trigger and Stop are separate 44 pt targets")
        capture("Processing")
    }
    @MainActor func testIPadShowsTheLibraryBesideTheNote() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "split view is for regular width")
        XCUIDevice.shared.orientation = .landscapeLeft
        // The tests after this one expect the device as they found it.
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = launch()
        openFixture(app)
        let search = app.textFields["librarySearch"], title = app.staticTexts["noteTitle"]
        XCTAssertTrue(search.isHittable, "the library stays beside the note")
        XCTAssertTrue(title.isHittable, "the note shows in the detail column")
        XCTAssertLessThanOrEqual(search.frame.maxX, title.frame.minX, "the library sits to the left of the note")
        capture("iPad split")
    }
}
