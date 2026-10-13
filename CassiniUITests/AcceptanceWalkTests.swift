import XCTest

/// The acceptance walk (Android `AcceptanceWalkTest`) on the recording seed, which fakes the microphone, the
/// transcriber and the speaker analysis: record, finish, the automatic transcription, read and play, name a speaker, export, move to Recently
/// Deleted and restore. Each board is attached as a named screenshot.
///
/// iOS differences: Android's walk is a manual run on the installed models that seeds a dozen notes and saves a
/// screenshot per board; here it is one ordinary UI test over the fakes, and the boards it does not walk (the model
/// download states, the statuses, Settings and Saved voices) have their own UI tests (`ModelDownloadFlowTests`,
/// `LibraryUITests`, `SettingsFlowTests`, `SpeakerNamingFlowTests`).
final class AcceptanceWalkTests: XCTestCase {
    private static let title = "Voice note 8 Oct, 09:41"

    // ports: AcceptanceWalkTest#realModels (the walk through the boards, over the fakes)
    @MainActor func testRecordTranscribeReadNameExportTrashAndRestore() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "recording"]
        app.launchAndWait()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15))
        shot("00-library")

        // Record, then finish: the note opens and transcribes on its own (the models are installed).
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["Pause recording"].waitForEnabled(within: 8))
        shot("01-recording")
        app.buttons["finishRecording"].tap()
        let title = app.staticTexts["noteTitle"]
        XCTAssertTrue(title.waitForExistence(within: 10))
        XCTAssertEqual(title.label, Self.title)
        let words = app.descendants(matching: .any)["turn-w2"]
        // Compression, the hand-off, the job and its save run one after another; on a loaded machine they took 30 s.
        XCTAssertTrue(words.waitForExistence(within: 60), "the recording is transcribed after it is saved")

        // Read and listen: a word tap plays from there.
        let play = app.buttons["playButton"]
        XCTAssertTrue(play.waitForEnabled(within: 10), "the sealed recording plays")
        words.tap()
        XCTAssertTrue(play.wait(until: NSPredicate(format: "label == 'Pause'"), within: 5), "a word tap plays")
        shot("03-read-and-listen")
        play.tap()
        XCTAssertTrue(play.wait(until: NSPredicate(format: "label == 'Play'"), within: 3))

        // Name a speaker from its passage header: every passage of the first speaker carries the new name.
        let first = speakerHeader(app, "Speaker 1")
        XCTAssertTrue(first.waitForExistence(within: 15), "the speakers are told apart after the words")
        // A transcription and its speakers are one version, as on Android: there is no version chip yet.
        XCTAssertFalse(app.buttons["versionChip"].exists, "the first transcription is the note's only version")
        first.tap()
        let field = app.textFields["speakerNameField"]
        XCTAssertTrue(field.waitForExistence(within: 5))
        field.tap()
        field.replaceText(with: "Anna Ricci")
        shot("04-name-a-speaker")
        app.buttons["saveSpeakerName"].tap()
        XCTAssertTrue(field.waitForNonExistence(within: 5), "Save closes the sheet")
        XCTAssertTrue(speakerHeader(app, "Anna Ricci").waitForExistence(within: 5))
        XCTAssertFalse(speakerHeader(app, "Speaker 1").exists, "no passage keeps the placeholder")
        XCTAssertTrue(speakerHeader(app, "Speaker 2").exists, "the other speaker keeps theirs")

        // Export the transcript as subtitles.
        app.buttons["More actions"].tap()
        app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Export transcript'")).firstMatch.tap()
        app.collectionViews.buttons["Subtitles · .srt"].tap()
        closeShareSheet(app)

        // Move to Recently Deleted: the Library says so; Restore brings the note back with its names.
        app.buttons["More actions"].tap()
        app.buttons["Move to Recently Deleted"].tap()
        XCTAssertTrue(app.staticTexts["“\(Self.title)” moved to Recently Deleted"].waitForExistence(within: 10))
        XCTAssertFalse(row(app).exists)
        app.buttons["Recently Deleted"].tap()
        let restore = app.buttons["Restore"]
        XCTAssertTrue(restore.waitForExistence(within: 5))
        shot("09-trash")
        restore.tap()
        XCTAssertTrue(app.staticTexts["Recently Deleted is empty"].waitForExistence(within: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(row(app).waitForExistence(within: 5), "the note is back in the Library")
        row(app).tap()
        XCTAssertTrue(speakerHeader(app, "Anna Ricci").waitForExistence(within: 10), "the restored note keeps its names")
    }

    @MainActor private func row(_ app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@", Self.title)).firstMatch
    }

    @MainActor private func speakerHeader(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(name), at")).firstMatch
    }

    @MainActor private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
