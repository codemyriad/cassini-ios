import XCTest

/// The Library end to end (Android `LibraryBehaviourTest` and the Library rows of `TextLimitBehaviourTest`): its
/// controls, the row statuses and inline actions, the search, the empty states and Rename.
final class LibraryUITests: XCTestCase {
    @MainActor private func launch(_ arguments: [String] = ["--seed-test-data"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data"] + arguments
        app.launch()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(timeout: 15))
        return app
    }

    @MainActor private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@", title)).firstMatch
    }

    /// The row titled `title`, scrolled to when the list has not built it yet.
    @MainActor private func scrolledRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let element = row(app, title)
        for _ in 0..<8 where !element.exists || !element.isHittable { app.swipeUp() }
        return element
    }

    @MainActor private func waitFor(_ element: XCUIElement, label: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", label)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout) == .completed
    }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// Every row status of the table shows, with its text, in a fixture (Recording is in the recording test below).
    @MainActor func testEveryRowStatusShowsWithItsText() {
        let app = launch(["--seed", "statuses"])
        let rows: [(String, String)] = [
            ("Weekly planning call", ", transcribing"),
            ("Interview with the printer", ", queued"),
            ("A quieter kind of productivity", ", transcribed, 2 speakers"),
            ("Paused standup", ", paused at 00:12"),
            ("Hallway conversation", ", couldn’t transcribe"),
            ("Interrupted capture", ", can’t play"),
            ("Damaged document", ", can’t read transcript"),
            ("Document from a newer Cassini", ", newer format"),
            ("Quiet room", ", transcribed, no speech"),
            ("Thoughts from the morning walk", ", audio only"),
        ]
        capture("Library statuses")
        for (title, status) in rows {
            let element = scrolledRow(app, title)
            XCTAssertTrue(element.waitForExistence(timeout: 10), title)
            XCTAssertTrue(waitFor(element, label: status), "\(title): \(element.label)")
        }
    }

    /// Resume and Try again are inline buttons that queue the note again (the running job is frozen, so it waits).
    @MainActor func testResumeAndTryAgainQueueTheNote() {
        let app = launch(["--seed", "statuses"])
        let resume = app.buttons["Resume transcribing Paused standup"]
        for _ in 0..<4 where !resume.isHittable { app.swipeUp() }
        XCTAssertTrue(resume.waitForExistence(timeout: 10))
        XCTAssertGreaterThanOrEqual(resume.frame.height, 44, "a 44 pt target")
        resume.tap()
        XCTAssertTrue(waitFor(row(app, "Paused standup"), label: ", queued"), row(app, "Paused standup").label)
        let tryAgain = app.buttons["Try transcribing Hallway conversation again"]
        XCTAssertTrue(tryAgain.waitForExistence(timeout: 5))
        tryAgain.tap()
        XCTAssertTrue(waitFor(row(app, "Hallway conversation"), label: ", queued"), row(app, "Hallway conversation").label)
    }

    // ports: LibraryBehaviourTest#theControlsSendTheirEvents
    // ports: LibraryViewModelTest#theProgressBannerOpensTheRunningNoteOrSettings
    @MainActor func testTheControlsLeadWhereTheySay() {
        let app = launch(["--seed", "statuses"])
        let banner = app.buttons["progressBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 15))
        XCTAssertTrue(waitFor(banner, label: "Transcribing Weekly planning call"), banner.label)
        XCTAssertTrue(waitFor(banner, label: "1 more in queue"), banner.label)
        XCTAssertTrue(app.buttons["Import audio"].isEnabled)
        XCTAssertEqual(app.buttons["recordButton"].label, "Record a new note")
        banner.tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["noteTitle"].label, "Weekly planning call")
    }

    // ports: LibraryBehaviourTest#duringARecordingTheCardAndTheButtonReturnToIt
    @MainActor func testDuringARecordingTheCardTheButtonAndTheRowReturnToIt() {
        let app = launch(["--seed", "recording"])
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["Pause recording"].waitForExistence(timeout: 8))
        app.buttons["Library"].tap()
        let card = app.buttons["activeRecordingCard"]
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertTrue(card.label.contains("Recording · Voice note 8 Oct, 09:41"), card.label)
        XCTAssertTrue(card.label.contains("Tap to return"), card.label)
        let record = app.buttons["recordButton"]
        XCTAssertEqual(record.label, "Return to recording")
        let recordingRow = row(app, "Voice note 8 Oct, 09:41")
        XCTAssertTrue(recordingRow.waitForExistence(timeout: 5))
        XCTAssertTrue(recordingRow.label.contains(", recording"), recordingRow.label)
        capture("Library while recording")
        record.tap()
        XCTAssertTrue(app.buttons["finishRecording"].waitForExistence(timeout: 5))
        app.buttons["Library"].tap()
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        card.tap()
        XCTAssertTrue(app.buttons["finishRecording"].waitForExistence(timeout: 5))
        app.buttons["Library"].tap()
        XCTAssertTrue(recordingRow.waitForExistence(timeout: 5))
        recordingRow.tap()
        XCTAssertTrue(app.buttons["finishRecording"].waitForExistence(timeout: 5), "the recording's row returns to it")
    }

    /// Search shows flat results with their day, says when nothing matches, and opens a note.
    @MainActor func testSearchShowsFlatResultsAndSaysWhenNothingMatches() {
        let app = launch(["--seed", "search"])
        XCTAssertTrue(app.staticTexts["TODAY"].exists, "day headers without a search")
        let search = app.textFields["librarySearch"]
        search.tap()
        search.typeText("thurs")
        let garden = row(app, "Garden plans for the spring")
        XCTAssertTrue(garden.waitForExistence(timeout: 5))
        XCTAssertTrue(row(app, "A quieter kind of productivity").exists)
        XCTAssertFalse(row(app, "Notes from the design review").exists)
        XCTAssertFalse(app.staticTexts["TODAY"].exists, "the results are one flat list")
        XCTAssertTrue(garden.label.contains("Monday 5 Oct"), "each result carries its own day: \(garden.label)")
        capture("Library search")
        search.typeText(XCUIKeyboardKey.delete.rawValue + "zzz")
        XCTAssertTrue(app.staticTexts["Nothing matches “thurzzz”"].waitForExistence(timeout: 5))
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.staticTexts["TODAY"].waitForExistence(timeout: 5))
        search.tap()
        search.typeText("e-mail giovedi ,")
        XCTAssertTrue(app.staticTexts["Nothing matches “e-mail giovedi ,”"].waitForExistence(timeout: 5))
        app.buttons["Clear search"].tap()
        search.tap()
        search.typeText(", ?!")
        XCTAssertTrue(row(app, "Garden plans for the spring").waitForExistence(timeout: 5), "only punctuation shows everything")
        XCTAssertTrue(row(app, "Notes from the design review").exists)
    }

    @MainActor func testAnEmptyLibraryOffersRecordAndImport() {
        let app = launch([])
        XCTAssertTrue(app.staticTexts["No notes yet"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Record something, or import an audio file."].exists)
        XCTAssertTrue(app.buttons["Record"].exists, "the empty state's own Record")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'Import audio'")).count, 2, "and its own Import")
        XCTAssertTrue(app.staticTexts["Transcribed on this device. Audio never leaves it."].exists)
        capture("Library empty")
    }

    // ports: LibraryBehaviourTest#renameSavesTheTrimmedTitleOnlyWhenItChanged
    @MainActor func testRenameSavesTheTrimmedTitleOnlyWhenItChanged() {
        let app = launch()
        let field = openRename(app, "Thoughts from the morning walk")
        let save = app.buttons["Save"]
        XCTAssertFalse(save.isEnabled, "nothing changed yet")
        clear(field)
        XCTAssertTrue(app.staticTexts["Enter a title."].waitForExistence(timeout: 3))
        XCTAssertFalse(save.isEnabled)
        field.typeText("  Thoughts from the morning walk ")
        XCTAssertFalse(save.isEnabled, "the same title once trimmed")
        clear(field)
        field.typeText("  Morning walk, final  ")
        XCTAssertFalse(app.staticTexts["Enter a title."].exists)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(row(app, "Morning walk, final,").waitForExistence(timeout: 5), "saved trimmed")
    }

    // ports: LibraryBehaviourTest#renameStopsAtTheTitleLimit
    // ports: TextLimitBehaviourTest#theNoteRenameStopsAtTheTitleLimit
    @MainActor func testTheNoteRenameStopsAtTheTitleLimit() {
        let app = launch()
        let field = openRename(app, "Thoughts from the morning walk")
        clear(field)
        field.typeText(String(repeating: "a", count: 201))
        XCTAssertEqual(field.value as? String, String(repeating: "a", count: 200))
        field.typeText("x")
        XCTAssertEqual(field.value as? String, String(repeating: "a", count: 200))
        app.buttons["Save"].tap()
        XCTAssertTrue(row(app, String(repeating: "a", count: 200) + ",").waitForExistence(timeout: 5))
    }

    /// At the largest text size during a recording the bar grows; the last row still scrolls clear of it.
    // ports: LibraryBehaviourTest#theLastRowScrollsClearOfATallBottomBar
    @MainActor func testTheLastRowScrollsClearOfTheBottomBar() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "statuses",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let last = row(app, "Thoughts from the morning walk")
        for _ in 0..<20 { app.swipeUp() }
        XCTAssertTrue(last.waitForExistence(timeout: 5))
        let record = app.buttons["recordButton"]
        XCTAssertLessThanOrEqual(last.frame.maxY, record.frame.minY, "row \(last.frame) under the bar \(record.frame)")
    }

    @MainActor private func openRename(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let note = row(app, title)
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        note.press(forDuration: 1)
        app.buttons["Rename"].tap()
        let field = app.textFields["renameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        return field
    }

    @MainActor private func clear(_ field: XCUIElement) {
        let count = (field.value as? String)?.count ?? 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count + 2))
    }
}
