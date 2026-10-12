import XCTest

/// The Note screen end to end on the seeded fixture note "A quieter kind of productivity": three passages of Alex and
/// Sam over 24 s of audio.
final class NoteScreenTests: XCTestCase {
    private static let fixture = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"

    @MainActor private func open(seed: String = "library") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", seed, "--open-fixture", Self.fixture]
        app.launch()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func header(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(name), at")).firstMatch
    }

    @MainActor private func wait(_ predicate: String, _ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)],
                       timeout: timeout) == .completed
    }

    /// One element per paragraph and one per speaker header, not one per word; the header names the speaker and its
    /// time, and opens Name a speaker.
    @MainActor func testEachTurnIsOneElementWithAHeaderThatNamesTheSpeaker() {
        let app = open()
        let turns = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "turn-"))
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns.element(boundBy: 0).label,
                       "What if being productive meant paying closer attention, rather than doing more?")
        let alex = header(app, "Alex")
        XCTAssertEqual(alex.label, "Alex, at 0 seconds")
        XCTAssertTrue(header(app, "Sam").exists)
        XCTAssertGreaterThanOrEqual(alex.frame.height, 44)
        XCTAssertTrue(app.buttons["speakersButton"].label.contains("2 speakers"))
        alex.tap()
        XCTAssertTrue(app.textFields["speakerNameField"].waitForExistence(timeout: 5), "the header opens Name a speaker")
    }

    // ports: ScreenBehaviourTest#aWordTapAsksToPlayFromThatWord
    @MainActor func testAWordTapPlaysFromThere() {
        let app = open()
        let play = app.buttons["playButton"]
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        let third = app.descendants(matching: .any)["turn-w2"]
        XCTAssertTrue(third.waitForExistence(timeout: 5))
        third.tap()
        XCTAssertTrue(wait("label == 'Pause'", play), "a word tap plays")
        let position = app.descendants(matching: .any)["playbackPosition"]
        XCTAssertTrue((position.value as? String)?.hasPrefix("00:1") == true, "it plays from the word: \(position.value ?? "")")
    }

    // ports: ScreenBehaviourTest#aDragDuringPlaybackPausesFollowingAndShowsTheChip
    // ports: ScreenBehaviourTest#aDragWithPlaybackPausedLeavesFollowingOn
    @MainActor func testADragDuringPlaybackShowsFollowPlaybackAndTheChipResumesIt() {
        let app = open()
        let chip = app.buttons["followPlayback"]
        let transcript = app.descendants(matching: .any)["turn-w0"]
        XCTAssertTrue(transcript.waitForExistence(timeout: 5))
        transcript.swipeUp()
        XCTAssertFalse(chip.waitForExistence(timeout: 1), "paused: a drag leaves following on")
        app.buttons["playButton"].tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 3))
        app.descendants(matching: .any)["turn-w1"].swipeDown()
        XCTAssertTrue(chip.waitForExistence(timeout: 3), "a drag during playback pauses following")
        chip.tap()
        XCTAssertTrue(wait("exists == false", chip), "the chip resumes following")
    }

    /// "1 of N", next and previous wrap, "No matches", Close search.
    @MainActor func testInNoteSearchCountsAndWraps() {
        let app = open()
        app.buttons["searchTranscript"].tap()
        let field = app.textFields["transcriptSearch"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.typeText("no")
        let counter = app.staticTexts["searchCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5))
        XCTAssertEqual(counter.label, "1 of 3")
        app.buttons["Next match"].tap()
        XCTAssertEqual(counter.label, "2 of 3")
        app.buttons["Next match"].tap()
        app.buttons["Next match"].tap()
        XCTAssertEqual(counter.label, "1 of 3", "next wraps around")
        app.buttons["Previous match"].tap()
        XCTAssertEqual(counter.label, "3 of 3", "previous wraps around")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "turn-")).count, 3,
                       "paragraphs without a match stay")
        field.typeText("zzz")
        XCTAssertTrue(wait("label == 'No matches'", counter))
        app.buttons["Close search"].tap()
        XCTAssertTrue(wait("exists == false", field))
    }

    // ports: NoteViewModelTest#aJobRowMakesTheSealedTranscriptReadOnly
    /// The processing seed runs a job that never ends, so Transcribe again queues the fixture behind it.
    @MainActor func testAQueuedNoteKeepsItsTranscriptButCannotBeRenamed() {
        let app = open(seed: "processing")
        app.buttons["More actions"].tap()
        app.buttons["Transcribe again"].tap()
        XCTAssertTrue(app.staticTexts["Queued"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.descendants(matching: .any)["turn-w0"].exists, "the transcript stays under the card")
        header(app, "Alex").tap()
        let alert = app.alerts["Wait until transcription finishes"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Close"].tap()
        XCTAssertFalse(app.textFields["speakerNameField"].exists, "no Name sheet")
        app.buttons["More actions"].tap()
        let remove = app.collectionViews.buttons["Remove from queue"]
        XCTAssertTrue(remove.waitForExistence(timeout: 3), "no Transcribe again while queued")
        XCTAssertFalse(app.collectionViews.buttons["Transcribe again"].exists)
        remove.tap()
        XCTAssertTrue(wait("exists == false", app.staticTexts["Queued"], timeout: 10))
    }

    @MainActor func testDocumentInfoShowsTheNotesFacts() {
        let app = open()
        app.buttons["More actions"].tap()
        app.buttons["Document info"].tap()
        XCTAssertTrue(app.navigationBars["Document info"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["00:24"].exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(wait("exists == false", app.navigationBars["Document info"]))
    }

    /// The plain note's banner says what it is and offers Transcribe; the subtitle shows outside reading mode.
    @MainActor func testAPlainNoteShowsItsBannerAndSubtitle() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed-test-data", "--open-fixture",
                               "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"]
        app.launch()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Plain audio"].exists)
        XCTAssertTrue(app.staticTexts["No transcript yet."].exists)
        let subtitle = app.staticTexts["noteSubtitle"].label
        XCTAssertTrue(subtitle.hasPrefix("Yesterday, 9:41") && subtitle.hasSuffix("AM · 00:24"), subtitle)
        XCTAssertTrue(app.buttons["Transcribe"].exists)
        XCTAssertFalse(app.buttons["searchTranscript"].exists, "no search without a transcript")
        app.buttons["Dismiss"].tap()
        XCTAssertTrue(wait("exists == false", app.staticTexts["Plain audio"]), "banners are dismissed by id")
    }
}
