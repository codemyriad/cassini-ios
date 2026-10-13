import XCTest

/// The Note screen end to end with the fake transcriber (Android `NoteFlowTest`, which runs the installed models on a
/// FLEURS clip): the audio-only note "Thoughts from the morning walk" is transcribed from its banner, its words show,
/// a word tap seeks there and plays, Transcribe again adds version 2 to Versions, and the transcript and the Cassini
/// document export through the share sheet.
///
/// iOS differences: the fake returns the fixture's three passages at once, so the progress card is not waited for;
/// the share sheet is a separate process, so the exported bytes are covered by the export goldens in the packages
/// (`ExportGoldenTests`, `ExportServiceTests`) rather than read back here.
final class NoteFlowTests: XCTestCase {
    private static let walk = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"

    // ports: NoteFlowTest#transcribeReadSeekVersionsAndExports
    @MainActor func testTranscribeReadSeekVersionsAndExports() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed-test-data", "--open-fixture", Self.walk]
        app.launchAndWait()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 15))

        // Transcribe from the Audio only banner.
        let transcribe = app.buttons["Transcribe"].firstMatch
        XCTAssertTrue(transcribe.waitForExistence(within: 5))
        transcribe.tap()
        let words = app.descendants(matching: .any)["turn-w2"]
        XCTAssertTrue(words.waitForExistence(within: 15), "the transcript shows")
        XCTAssertFalse(app.buttons["Transcribe"].exists, "the banner is gone")

        // A word tap seeks there and plays.
        let play = app.buttons["playButton"]
        XCTAssertTrue(play.waitForEnabled(within: 5))
        words.tap()
        XCTAssertTrue(play.wait(until: NSPredicate(format: "label == 'Pause'"), within: 5), "a word tap plays")
        let position = app.descendants(matching: .any)["playbackPosition"]
        XCTAssertTrue((position.value as? String)?.hasPrefix("00:1") == true, "from the word: \(position.value ?? "")")
        play.tap()
        XCTAssertTrue(play.wait(until: NSPredicate(format: "label == 'Play'"), within: 3))

        // Transcribe again: version 2, and Versions lists both.
        app.buttons["More actions"].tap()
        app.collectionViews.buttons["Transcribe again"].tap()
        let chip = app.buttons["versionChip"]
        XCTAssertTrue(chip.wait(until: NSPredicate(format: "label BEGINSWITH 'Version 2 of 2'"), within: 15),
                      "the second transcription is version 2")
        chip.tap()
        XCTAssertTrue(app.navigationBars["Versions"].waitForExistence(within: 5))
        XCTAssertTrue(app.staticTexts["Version 1"].exists)
        XCTAssertTrue(app.staticTexts["Version 2"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Versions"].waitForNonExistence(within: 5))

        // The exports reach the share sheet.
        app.buttons["More actions"].tap()
        app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Export transcript'")).firstMatch.tap()
        app.collectionViews.buttons["Transcript as text"].tap()
        closeShareSheet(app)
        app.buttons["More actions"].tap()
        app.collectionViews.buttons["Export Cassini document"].tap()
        closeShareSheet(app)
        XCTAssertTrue(app.staticTexts["noteTitle"].exists, "the exports leave the note open")
    }
}

extension XCTestCase {
    /// Waits for the share sheet and closes it. iOS 27 sometimes draws the sheet's Close in a floating bar outside the
    /// activity list, and the sheet's contents come from another process a moment after the sheet itself: on a clone
    /// just booted, many seconds.
    @MainActor func closeShareSheet(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(within: 15), "the share sheet opens", file: file, line: line)
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(within: 30), file: file, line: line)
        close.tap()
        XCTAssertTrue(shareSheet.waitForNonExistence(within: 5), file: file, line: line)
    }
}
