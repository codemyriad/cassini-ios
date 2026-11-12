import XCTest

/// The Library end to end (Android `LibraryBehaviourTest` and the Library rows of `TextLimitBehaviourTest`): its
/// controls, the row statuses and inline actions, the search, the empty states and Rename.
final class LibraryUITests: XCTestCase {
    @MainActor private func launch(_ arguments: [String] = ["--seed-test-data"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data"] + arguments
        app.launchAndWait()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15))
        return app
    }

    @MainActor private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@", title)).firstMatch
    }

    /// The library's list. Swipes go to it: on iPad the middle of the screen is the note beside it.
    @MainActor private func list(_ app: XCUIApplication) -> XCUIElement {
        app.scrollViews.containing(.button, identifier: "noteRow").firstMatch
    }

    /// The row titled `title`, fully between the navigation and capture bars before a tap or long-press.
    @MainActor private func scrolledRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let element = row(app, title), bar = app.buttons["recordButton"]
        let viewport = list(app), navigation = app.navigationBars.firstMatch
        guard viewport.waitForExistence(within: uiWaitFloor), bar.waitForExistence(within: uiWaitFloor) else {
            XCTFail("The library's scroll region or capture bar is missing")
            return element
        }
        func clearFrame() -> CGRect {
            let frame = viewport.frame
            let top = max(frame.minY, navigation.exists ? navigation.frame.maxY : frame.minY) + 8
            let bottom = min(frame.maxY, bar.frame.minY) - 8
            return CGRect(x: frame.minX, y: top, width: frame.width, height: max(0, bottom - top))
        }
        for _ in 0..<12 {
            if element.exists, let frame = (try? element.snapshot())?.frame, !frame.isEmpty {
                let clear = clearFrame()
                guard let movement = RowScrollGeometry.correction(for: frame, within: clear) else {
                    XCTFail("The row \(title) cannot fit between the navigation and capture bars")
                    return element
                }
                if movement == 0 {
                    let ready = poll(within: uiWaitFloor) {
                        guard element.exists, let now = (try? element.snapshot())?.frame else { return false }
                        return RowScrollGeometry.correction(for: now, within: clearFrame()) == 0 && element.isHittable
                    }
                    if ready { return element }
                    XCTFail("The fully visible row \(title) did not become hittable")
                    return element
                }
                let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
                    .withOffset(CGVector(dx: 0, dy: clear.midY - viewport.frame.minY))
                start.press(forDuration: 0, thenDragTo: start.withOffset(CGVector(dx: 0, dy: movement)),
                            withVelocity: .slow, thenHoldForDuration: 0)
                continue
            }
            viewport.swipeUp(velocity: .slow)
        }
        XCTFail("The row \(title) did not become clear of the navigation and capture bars")
        return element
    }

    @MainActor private func waitFor(_ element: XCUIElement, label: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", label)
        return element.wait(until: predicate, within: timeout)
    }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// Every row status of the table shows, with its text, in a fixture (Recording is in the recording test below).
    @MainActor func testEveryRowStatusShowsWithItsText() {
        let app = launch(["--seed", "statuses"] + DeviceUnderTest.workingSpeech)
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
        // Each row's label as the list shows it, read a screen at a time: a swipe only when a row is still missing.
        var shown: [String: String] = [:]
        list(app).scroll {
            for label in labels(in: app, identifier: "noteRow") {
                for (title, _) in rows where label.hasPrefix(title) { shown[title] = label }
            }
            return shown.count == rows.count
        }
        for (title, status) in rows {
            if let label = shown[title], label.contains(status) { continue }
            // Not read yet with its status (the list was still filling in): the row itself, waited for.
            let element = scrolledRow(app, title)
            XCTAssertTrue(element.waitForExistence(within: 10), title)
            XCTAssertTrue(waitFor(element, label: status), "\(title): \(element.label)")
        }
    }

    /// Resume and Try again are inline buttons that queue the note again (the running job is frozen, so it waits).
    @MainActor func testResumeAndTryAgainQueueTheNote() {
        let app = launch(["--seed", "statuses"] + DeviceUnderTest.workingSpeech)
        let resume = app.buttons["Resume transcribing Paused standup"]
        list(app).scroll(attempts: 4) { resume.exists && resume.isHittable }
        XCTAssertTrue(resume.waitForExistence(within: 10))
        // The frame comes back through a floating-point transform: once on iOS 18.2 a 44 pt row read 43.99999999999997.
        XCTAssertGreaterThanOrEqual(resume.frame.height, 44 - 0.001, "a 44 pt target")
        resume.tap()
        XCTAssertTrue(waitFor(row(app, "Paused standup"), label: ", queued"), row(app, "Paused standup").label)
        let tryAgain = app.buttons["Try transcribing Hallway conversation again"]
        XCTAssertTrue(tryAgain.waitForExistence(within: 5))
        tryAgain.tap()
        XCTAssertTrue(waitFor(row(app, "Hallway conversation"), label: ", queued"), row(app, "Hallway conversation").label)
    }

    // ports: LibraryBehaviourTest#theControlsSendTheirEvents
    // ports: LibraryViewModelTest#theProgressBannerOpensTheRunningNoteOrSettings
    @MainActor func testTheControlsLeadWhereTheySay() {
        let app = launch(["--seed", "statuses"] + DeviceUnderTest.workingSpeech)
        let banner = app.buttons["progressBanner"]
        XCTAssertTrue(banner.waitForExistence(within: 15))
        XCTAssertTrue(waitFor(banner, label: "Transcribing Weekly planning call"), banner.label)
        XCTAssertTrue(waitFor(banner, label: "1 more in queue"), banner.label)
        XCTAssertTrue(app.buttons["importButton"].isEnabled)
        XCTAssertEqual(app.buttons["recordButton"].label, "Record a new note")
        banner.tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 5))
        XCTAssertEqual(app.staticTexts["noteTitle"].label, "Weekly planning call")
    }

    // ports: LibraryBehaviourTest#duringARecordingTheCardAndTheButtonReturnToIt
    @MainActor func testDuringARecordingTheCardTheButtonAndTheRowReturnToIt() {
        let app = launch(["--seed", "recording"])
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["Pause recording"].waitForEnabled(within: 8))
        app.buttons["Library"].tap()
        let card = app.buttons["activeRecordingCard"]
        XCTAssertTrue(card.waitForExistence(within: 5))
        XCTAssertTrue(card.label.contains("Recording · Voice note 8 Oct, 09:41"), card.label)
        XCTAssertTrue(card.label.contains("Tap to return"), card.label)
        let record = app.buttons["recordButton"]
        XCTAssertEqual(record.label, "Return to recording")
        let recordingRow = row(app, "Voice note 8 Oct, 09:41")
        XCTAssertTrue(recordingRow.waitForExistence(within: 5))
        XCTAssertTrue(waitFor(recordingRow, label: ", recording"), recordingRow.label)
        capture("Library while recording")
        record.tap()
        XCTAssertTrue(app.buttons["finishRecording"].waitForExistence(within: 5))
        app.buttons["Library"].tap()
        XCTAssertTrue(card.waitForExistence(within: 5))
        card.tap()
        XCTAssertTrue(app.buttons["finishRecording"].waitForExistence(within: 5))
        app.buttons["Library"].tap()
        XCTAssertTrue(recordingRow.waitForExistence(within: 5))
        recordingRow.tap()
        XCTAssertTrue(app.buttons["finishRecording"].waitForExistence(within: 5), "the recording's row returns to it")
    }

    /// Search shows flat results with their day, says when nothing matches, and opens a note.
    /// A note stored with the reason Whistle took its transcription shows the notice when it is opened after a
    /// launch; a note without one does not.
    @MainActor func testANoteWhistleTranscribedAfterParakeetCouldNotRunSaysSo() {
        let app = launch(["--seed", "search"])
        let notice = app.staticTexts["Parakeet Ultra couldn’t run on this device for this recording, so Whistle transcribed it."]
        let review = row(app, "Notes from the design review")
        XCTAssertTrue(review.waitForExistence(within: 15))
        review.tap()
        XCTAssertTrue(notice.waitForExistence(within: 15))
    }

    @MainActor func testSearchShowsFlatResultsAndSaysWhenNothingMatches() {
        let app = launch(["--seed", "search"])
        XCTAssertTrue(app.staticTexts["TODAY"].exists, "day headers without a search")
        let search = app.textFields["librarySearch"]
        search.tap()
        search.typeText("thurs")
        let garden = row(app, "Garden plans for the spring")
        XCTAssertTrue(garden.waitForExistence(within: 5))
        XCTAssertTrue(row(app, "A quieter kind of productivity").exists)
        XCTAssertTrue(row(app, "Notes from the design review").waitForNonExistence(within: 5))
        XCTAssertTrue(app.staticTexts["TODAY"].waitForNonExistence(within: 5), "the results are one flat list")
        XCTAssertTrue(garden.label.contains("Monday 5 Oct"), "each result carries its own day: \(garden.label)")
        capture("Library search")
        search.typeText(XCUIKeyboardKey.delete.rawValue + "zzz")
        XCTAssertTrue(app.staticTexts["Nothing matches “thurzzz”"].waitForExistence(within: 5))
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.staticTexts["TODAY"].waitForExistence(within: 5))
        search.tap()
        search.typeText("e-mail cafe ,")
        XCTAssertTrue(app.staticTexts["Nothing matches “e-mail cafe ,”"].waitForExistence(within: 5))
        app.buttons["Clear search"].tap()
        search.tap()
        search.typeText(", ?!")
        XCTAssertTrue(row(app, "Garden plans for the spring").waitForExistence(within: 5), "only punctuation shows everything")
        XCTAssertTrue(row(app, "Notes from the design review").exists)
    }

    @MainActor func testSearchDateMenuNarrowsMatchesAndClearingResetsIt() {
        let app = launch(["--seed", "search"])
        let search = app.textFields["librarySearch"]
        search.tap()
        search.typeText("thurs\n")
        let garden = row(app, "Garden plans for the spring")
        XCTAssertTrue(garden.waitForExistence(within: 15))
        let date = app.buttons["librarySearchDate"]
        XCTAssertTrue(date.waitForExistence(within: 15))
        date.tap()
        app.buttons["Today"].tapWhenSettled()
        XCTAssertTrue(garden.waitForNonExistence(within: 15))
        XCTAssertTrue(row(app, "A quieter kind of productivity").exists)
        date.tap()
        app.buttons["Past 7 days"].tapWhenSettled()
        XCTAssertTrue(garden.waitForExistence(within: 15))
        app.buttons["Clear search"].tap()
        XCTAssertTrue(app.staticTexts["TODAY"].waitForExistence(within: 15))
        XCTAssertFalse(date.exists, "Date filters only narrow typed Search")
        search.tap()
        search.typeText("thurs\n")
        XCTAssertTrue(garden.waitForExistence(within: 15))
        XCTAssertTrue(date.label.contains("Any date"), "A new search has no remembered date filter")
    }

    /// Search finds a spoken word of a note, a long press on the result opens its actions over the search, Move to
    /// Recently Deleted takes it out of the results, and Undo brings it back. The import half of Android's flow
    /// (ACTION_VIEW of a file) is the import flow's (WP12).
    // ports: LibraryFlowTest#importSearchActionsTrashAndUndo
    @MainActor func testSearchActionsTrashAndUndo() {
        let app = launch(["--seed", "search"])
        let search = app.textFields["librarySearch"]
        search.tap()
        search.typeText("tomatoe")
        let garden = row(app, "Garden plans for the spring")
        XCTAssertTrue(garden.waitForExistence(within: 5))
        XCTAssertTrue(row(app, "Notes from the design review").waitForNonExistence(within: 5))
        garden.press(forDuration: 1)
        app.buttons["Move to Recently Deleted"].tapWhenSettled()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(within: 5))
        // Undo is available before the asynchronous search results have rendered the removal.
        XCTAssertTrue(app.staticTexts["Nothing matches “tomatoe”"].waitForExistence(within: 5))
        XCTAssertFalse(garden.exists, "a note in Recently Deleted is not a result")
        app.buttons["Undo"].tap()
        XCTAssertTrue(garden.waitForExistence(within: 5), "Undo brings the result back")
        XCTAssertEqual(search.value as? String, "tomatoe", "the search stays open")
    }

    @MainActor func testAnEmptyLibraryOffersRecordAndImport() {
        let app = launch([])
        XCTAssertTrue(app.staticTexts["No notes yet"].waitForExistence(within: 5))
        XCTAssertTrue(app.staticTexts["Record something, or import an audio file."].exists)
        XCTAssertTrue(app.buttons["Record"].exists, "the LIB_EMPTY banner's own Record")
        XCTAssertTrue(app.buttons["Import"].exists, "and its own Import, as Android's banner")
        XCTAssertTrue(app.buttons["Import audio"].exists, "beside the capture bar's Import audio")
        XCTAssertTrue(app.staticTexts["Transcribed on this device. Audio never leaves it."].exists)
        capture("Library empty")
    }

    // ports: LibraryBehaviourTest#renameSavesTheTrimmedTitleOnlyWhenItChanged
    @MainActor func testRenameSavesTheTrimmedTitleOnlyWhenItChanged() {
        let app = launch()
        let field = openRename(app, "Thoughts from the morning walk")
        let save = app.buttons["Save"]
        XCTAssertFalse(save.isEnabled, "nothing changed yet")
        guard clear(field) else { return }
        XCTAssertTrue(app.staticTexts["Enter a title."].waitForExistence(within: 10),
                      "no blank-title message; the field holds \(String(describing: field.value))")
        XCTAssertFalse(save.isEnabled)
        field.typeText("  Thoughts from the morning walk ")
        XCTAssertTrue(field.waitForValue("  Thoughts from the morning walk "), "the field holds \(String(describing: field.value))")
        XCTAssertFalse(save.isEnabled, "the same title once trimmed")
        guard clear(field) else { return }
        field.typeText("  Morning walk, final  ")
        XCTAssertTrue(field.waitForValue("  Morning walk, final  "), "the field holds \(String(describing: field.value))")
        XCTAssertFalse(app.staticTexts["Enter a title."].exists)
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(row(app, "Morning walk, final,").waitForExistence(within: 5), "saved trimmed")
    }

    // ports: LibraryBehaviourTest#renameStopsAtTheTitleLimit
    // ports: TextLimitBehaviourTest#theNoteRenameStopsAtTheTitleLimit
    @MainActor func testTheNoteRenameStopsAtTheTitleLimit() {
        let app = launch()
        let field = openRename(app, "Thoughts from the morning walk")
        guard clear(field) else { return }
        let full = String(repeating: "a", count: 200)
        // Typed, not pasted: after a paste here the sheet's Save sometimes did not answer the next tap.
        field.typeText(full + "a")
        // The field cuts what goes past the limit as it changes, a moment after the typing on a busy machine.
        _ = field.wait(until: NSPredicate(format: "value == %@", full), within: 3)
        XCTAssertEqual(field.value as? String, full)
        field.typeText("x")
        _ = field.wait(until: NSPredicate(format: "value == %@", full), within: 3)
        XCTAssertEqual(field.value as? String, full)
        app.buttons["Save"].tap()
        XCTAssertTrue(row(app, String(repeating: "a", count: 200) + ",").waitForExistence(within: 5))
    }

    /// At the largest text size during a recording the bar grows; the last row still scrolls clear of it.
    // ports: LibraryBehaviourTest#theLastRowScrollsClearOfATallBottomBar
    @MainActor func testTheLastRowScrollsClearOfTheBottomBar() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "statuses",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchAndWait()
        let last = row(app, "Thoughts from the morning walk")
        // Up to the end of the list: once the last row is built, until a swipe no longer moves it.
        var previous = CGRect.null
        // This is a trip to the end, so fling further than the row-targeted swipes use.
        let reachedBottom = list(app).scroll(attempts: 20, velocity: XCUIGestureVelocity(rawValue: 3_000)) {
            guard last.exists else { return false }
            defer { previous = last.frame }
            return last.frame == previous
        }
        XCTAssertTrue(reachedBottom, "The last row must stop moving at the end of the list")
        XCTAssertTrue(last.waitForExistence(within: 5))
        let record = app.buttons["recordButton"]
        XCTAssertLessThanOrEqual(last.frame.maxY, record.frame.minY, "row \(last.frame) under the bar \(record.frame)")
    }

    /// The long-press menu: Start over and a Transcribe again that replaces the versions ask first.
    // ports: LibraryBehaviourTest#theConfirmationsOfTheSheetRows
    @MainActor func testTheActionsMenuAsksBeforeStartingOverOrReplacingTheVersions() {
        let app = launch(["--seed", "statuses"] + DeviceUnderTest.workingSpeech)
        let paused = scrolledRow(app, "Paused standup")
        XCTAssertTrue(paused.waitForExistence(within: 10))
        paused.press(forDuration: 1)
        app.buttons["Start over"].tapWhenSettled()
        let startOver = app.alerts["Start over?"]
        XCTAssertTrue(startOver.waitForExistence(within: 5))
        startOver.buttons["Cancel"].tap()
        XCTAssertTrue(waitFor(paused, label: ", paused at 00:12"), "Cancel keeps the progress: \(paused.label)")
        paused.press(forDuration: 1)
        app.buttons["Start over"].tapWhenSettled()
        XCTAssertTrue(startOver.waitForExistence(within: 5))
        startOver.buttons["Start over"].tap()
        XCTAssertTrue(waitFor(row(app, "Paused standup"), label: ", queued"), row(app, "Paused standup").label)

        let damaged = scrolledRow(app, "Damaged document")
        XCTAssertTrue(damaged.waitForExistence(within: 5))
        damaged.press(forDuration: 1)
        // The item reads "Transcribe again, Adds version 2."
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Transcribe again'")).firstMatch.tapWhenSettled()
        let fresh = app.alerts["Transcribe again?"]
        XCTAssertTrue(fresh.waitForExistence(within: 5), "a document whose versions can't be kept asks first")
        fresh.buttons["Cancel"].tap()
        XCTAssertTrue(waitFor(row(app, "Damaged document"), label: ", can’t read transcript"))
    }

    /// Export in the long-press menu opens the note, which runs the export: the share sheet offers the subtitles.
    // ports: LibraryBehaviourTest#theSubtitleChooserExportsTheNote
    @MainActor func testTheActionsMenuExportOpensTheNoteWhichSharesTheSubtitles() {
        assertActionsMenuShares("Subtitles · .vtt")
    }

    @MainActor func testTheActionsMenuMarkdownOpensTheNoteAndShares() {
        assertActionsMenuShares("Markdown")
    }

    @MainActor private func assertActionsMenuShares(_ format: String) {
        let app = launch(["--seed", "statuses"])
        let note = scrolledRow(app, "A quieter kind of productivity")
        XCTAssertTrue(note.waitForExistence(within: 5))
        note.press(forDuration: 1)
        app.buttons["Export"].tapWhenSettled()
        app.buttons[format].tapWhenSettled()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 5))
        XCTAssertEqual(app.staticTexts["noteTitle"].label, "A quieter kind of productivity")
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(within: 10), "the note shares the requested transcript format")
        // iOS 27 sometimes draws the sheet's Close in a floating bar outside the activity list, and the sheet's
        // contents come from another process a moment after the sheet itself: on a clone just booted, many seconds.
        guard let close = app.waitForShareSheetClose() else {
            XCTFail("the share sheet exposes its Close button")
            return
        }
        close.tapWhenSettled()
        XCTAssertTrue(shareSheet.waitForNonExistence(within: 5))
    }

    /// Document info in the long-press menu opens the note, which shows it.
    // ports: LibraryBehaviourTest#documentInfoOpensAsADialog
    @MainActor func testTheActionsMenuDocumentInfoOpensTheNote() {
        let app = launch(["--seed", "statuses"])
        let note = scrolledRow(app, "A quieter kind of productivity")
        XCTAssertTrue(note.waitForExistence(within: 5))
        note.press(forDuration: 1)
        app.buttons["Document info"].tapWhenSettled()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 5))
        XCTAssertEqual(app.staticTexts["noteTitle"].label, "A quieter kind of productivity")
    }

    @MainActor private func openRename(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let note = row(app, title)
        XCTAssertTrue(note.waitForExistence(within: 5))
        note.press(forDuration: 1)
        app.buttons["Rename"].tapWhenSettled()
        let field = app.textFields["renameField"]
        XCTAssertTrue(field.waitForExistence(within: 5))
        // The field exists before iOS 18 has expanded the sheet and delivered keyboard focus.
        // Sending deletes during that transition left a prefix in the failed full gate.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(within: 5), "Rename has keyboard focus before editing")
        return field
    }

    @MainActor private func clear(_ field: XCUIElement) -> Bool {
        let count = (field.value as? String)?.count ?? 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count + 2))
        guard XCUIApplication().staticTexts["Enter a title."].waitForExistence(within: 10) else {
            XCTFail("the blank-title state is visible before the next edit; the field holds \(String(describing: field.value))")
            return false
        }
        return true
    }
}
