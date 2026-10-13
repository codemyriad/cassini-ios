import XCTest

/// The Note screen end to end with the fake transcriber (Android `NoteFlowTest`, which runs the installed models on a
/// FLEURS clip): the audio-only note "Thoughts from the morning walk" is transcribed from its banner, its words show,
/// a word tap seeks there and plays, Transcribe again adds version 2 to Versions, and the transcript and the Cassini
/// document export through the share sheet.
///
/// iOS differences: the fake returns the fixture's three passages at once, so the progress card is not waited for.
/// Android's `variants = 1` after the first Transcribe is checked as no version chip (the chip shows from version 2).
/// A note transcribed on iOS is not sealed into a Cassini document until it is exported, so it has no trust chip and
/// "Verified" is not checked here (an imported document's trust is, in `DocumentTrustTests`). The fixture's
/// passages carry no word timings, so the tap is on the third passage and the position, which the slider gives in
/// whole seconds, is checked against that passage's start with Android's slack. The share sheet is a separate
/// process, so the text, SRT, VTT and document exports are checked to reach it, and their bytes are covered by the
/// export goldens in the packages (`ExportGoldenTests`, `ExportServiceTests`) rather than read back here.
/// The fake hears the same words again on Transcribe again, which adds version 2 all the same, as on Android.
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
        XCTAssertFalse(app.buttons["versionChip"].exists, "the first transcription is the note's only version")

        // A word tap seeks there and plays.
        let play = app.buttons["playButton"]
        XCTAssertTrue(play.waitForEnabled(within: 5))
        words.tap()
        XCTAssertTrue(play.wait(until: NSPredicate(format: "label == 'Pause'"), within: 5), "a word tap plays")
        let position = app.descendants(matching: .any)["playbackPosition"]
        let seconds = Self.seconds(position.value as? String)
        XCTAssertTrue(seconds.map(Self.playsFromThirdPassage.contains) == true, "from the passage: \(position.value ?? "")")
        play.tap()
        XCTAssertTrue(play.wait(until: NSPredicate(format: "label == 'Play'"), within: 3))

        // Transcribe again: version 2, and Versions lists both.
        app.buttons["Share and more"].tap()
        let again = app.collectionViews.buttons["transcribeAgain"]
        XCTAssertTrue(again.waitForExistence(within: 3))
        XCTAssertTrue(again.label.contains("Adds version 2."), "the menu says which version it adds: \(again.label)")
        again.tap()
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
        app.buttons["Share and more"].tap()
        app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Export transcript'")).firstMatch.tap()
        app.collectionViews.buttons["Transcript as text"].tap()
        closeShareSheet(app)
        for subtitles in ["Subtitles · .srt", "Subtitles · .vtt"] {
            app.buttons["Share and more"].tap()
            app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Export transcript'")).firstMatch.tap()
            app.collectionViews.buttons[subtitles].tap()
            closeShareSheet(app)
        }
        app.buttons["Share and more"].tap()
        app.collectionViews.buttons["Export Cassini document"].tap()
        closeShareSheet(app)
        XCTAssertTrue(app.staticTexts["noteTitle"].exists, "the exports leave the note open")
    }

    /// The third passage starts at 14 s: Android's slack of 300 ms before and 3 s after, in the slider's whole seconds.
    private static let playsFromThirdPassage = 13...17

    /// The position in whole seconds of the slider's "mm:ss of mm:ss".
    private static func seconds(_ value: String?) -> Int? {
        guard let clock = value?.split(separator: " ").first else { return nil }
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return parts[0] * 60 + parts[1]
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
