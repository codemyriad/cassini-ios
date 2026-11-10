import XCTest

/// On a window wider than 560 pt (iPad, here in landscape beside the Library), each screen caps its content at 560 pt
/// and centres it in its column, while its background fills the column. The Library itself is the iPad's sidebar,
/// narrower than the cap, and Transcribing is the Note screen's processing mode, whose layout the note test covers.
// ports: WideScreenTest#readAndListen
// ports: WideScreenTest#recording
// ports: WideScreenTest#modelDownload
// ports: WideScreenTest#savedVoices
// ports: WideScreenTest#settings
// ports: WideScreenTest#trash
// ports: DialogLandscapeTest#theScrimCoversAWideWindow (the Rename form stays within its 560 pt band in landscape)
final class WideScreenTests: XCTestCase {
    private static let cap: CGFloat = 560

    @MainActor private func launch(_ arguments: [String]) throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a wide window")
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data"] + arguments
        app.launchAndWait()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15))
        return app
    }

    /// The detail column: the window right of the Library's sidebar, whose navigation bar is the narrowest.
    @MainActor private func detailColumn(_ app: XCUIApplication) -> CGRect {
        let window = app.windows.firstMatch.frame
        let sidebar = app.navigationBars.allElementsBoundByIndex.map(\.frame).min { $0.width < $1.width } ?? .zero
        return CGRect(x: sidebar.maxX, y: window.minY, width: window.maxX - sidebar.maxX, height: window.height)
    }

    /// Every element lies in the band of `cap` centred in `column`, and the widest of them is wider than a phone's
    /// content would leave, so the band is really used.
    @MainActor private func assertCentred(_ elements: [XCUIElement], in column: CGRect,
                                          file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThan(column.width, Self.cap + 40, "the column is wider than the cap", file: file, line: line)
        let band = CGRect(x: column.midX - Self.cap / 2, y: column.minY, width: Self.cap, height: .greatestFiniteMagnitude)
        for element in elements {
            XCTAssertTrue(element.waitForExistence(within: 5), "\(element)", file: file, line: line)
            let frame = element.frame
            XCTAssertGreaterThanOrEqual(frame.minX, band.minX - 1, element.label, file: file, line: line)
            XCTAssertLessThanOrEqual(frame.maxX, band.maxX + 1, element.label, file: file, line: line)
        }
    }

    @MainActor func testIPadNoteContentIsCappedAndCentred() throws {
        let app = try launch(["--seed", "library", "--open-fixture", "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"])
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 10))
        let turns = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "turn-"))
        assertCentred([app.staticTexts["noteTitle"], turns.element(boundBy: 0), app.buttons["playButton"]], in: detailColumn(app))
    }

    @MainActor func testIPadSettingsAndRecentlyDeletedAreCappedAndCentred() throws {
        let app = try launch(["--seed", "trash"])
        app.buttons["Recently Deleted"].tap()
        XCTAssertTrue(app.staticTexts["Old interview draft"].waitForExistence(within: 5))
        assertCentred([app.staticTexts["Old interview draft"], app.buttons["Restore"].firstMatch], in: detailColumn(app))
        app.buttons["Settings"].tap()
        let language = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "App language")).firstMatch
        assertCentred([language], in: detailColumn(app))
    }

    /// Recording covers the whole window.
    @MainActor func testIPadRecordingIsCappedAndCentred() throws {
        let app = try launch(["--seed", "recording"])
        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(within: 10))
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["Pause recording"].waitForEnabled(within: 8))
        assertCentred([app.descendants(matching: .any)["recordingTitle"], app.buttons["pauseResumeRecording"], app.buttons["finishRecording"]],
                      in: app.windows.firstMatch.frame)
    }

    /// Where the system has no Apple speech (`DeviceUnderTest`), the speech model to download is Parakeet's, whose
    /// part carries its size.
    @MainActor func testIPadModelDownloadIsCappedAndCentred() throws {
        let app = try launch(["--seed", "library", "--models-missing"] + DeviceUnderTest.downloadedSpeech)
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Thoughts from the morning walk")).firstMatch
        XCTAssertTrue(row.waitForExistence(within: 5))
        for _ in 0..<3 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.buttons["Transcribe"].waitForExistence(within: 5))
        app.buttons["Transcribe"].tap()
        let title = app.staticTexts["Transcribe on this device"]
        XCTAssertTrue(title.waitForExistence(within: 5))
        let speech = app.staticTexts[DeviceUnderTest.appleSpeech ? "Speech recognition" : "Speech recognition, 444 MB"]
        assertCentred([title, speech, app.buttons["Download and transcribe"]], in: detailColumn(app))
    }

    @MainActor func testIPadSavedVoicesAreCappedAndCentred() throws {
        let app = try launch(["--seed", "voices"])
        let language = app.buttons["appLanguageRow"]
        XCTAssertTrue(app.buttons["settingsButton"].tapWhenInteractive(in: app, until: { language.exists }), "Settings did not open")
        let row = app.buttons["savedVoicesRow"]
        XCTAssertTrue(app.scroll(attempts: 12) { row.exists && row.isHittable }, "Saved voices is not on the screen")
        row.tap()
        let person = app.buttons["Options for Alex Moreau"]
        XCTAssertTrue(person.waitForExistence(within: 5))
        assertCentred([person, app.buttons["forgetEveryone"]], in: detailColumn(app))
    }

    @MainActor func testIPadRenameStaysInItsBandInLandscape() throws {
        let app = try launch(["--seed", "library"])
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Thoughts from the morning walk")).firstMatch
        XCTAssertTrue(row.waitForExistence(within: 5))
        let list = app.scrollViews.containing(.button, identifier: "noteRow").firstMatch
        let capture = app.otherElements["captureBar"]
        // A short landscape window can put this row below the fixed capture bar even though it exists in AX.
        XCTAssertTrue(list.scroll(attempts: 12) {
            row.exists && row.isHittable && !row.frame.isEmpty
                && row.frame.minY >= app.navigationBars.firstMatch.frame.maxY && row.frame.maxY <= capture.frame.minY
        }, "the row is clear of the capture bar before the long press")
        row.press(forDuration: 1)
        app.buttons["Rename"].tapWhenSettled()
        let field = app.textFields["renameField"]
        XCTAssertTrue(field.waitForExistence(within: 5))
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(field.frame), "the form is inside the window")
        XCTAssertLessThanOrEqual(field.frame.width, Self.cap, "the field is at most 560 pt wide")
    }
}
