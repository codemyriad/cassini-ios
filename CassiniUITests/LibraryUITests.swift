import XCTest
import Vision

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
        app.scrollViews["libraryScroll"]
    }

    /// The row titled `title`, fully between the navigation and capture bars before a tap or long-press.
    @MainActor private func scrolledRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        let element = row(app, title), bar = app.buttons["recordButton"]
        let viewport = list(app), navigation = app.navigationBars.firstMatch
        for _ in 0..<12 {
            if element.exists {
                let frame = element.frame
                let search = app.textFields["librarySearch"]
                let top = max(navigation.exists ? navigation.frame.maxY : viewport.frame.minY,
                              search.exists ? search.frame.maxY : viewport.frame.minY)
                if !frame.isEmpty {
                    if frame.minY >= top && frame.maxY <= bar.frame.minY && element.isHittable { return element }
                    if frame.minY < top {
                        viewport.swipeDown(velocity: .slow)
                        continue
                    }
                }
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

    /// Measure the resting capsule after its native morph, without turning animation duration into a test wait.
    @MainActor private func settledFrame(_ element: XCUIElement) -> CGRect {
        var previous: CGRect?
        var result = CGRect.null
        XCTAssertTrue(poll(within: 5) {
            guard let frame = (try? element.snapshot())?.frame, !frame.isEmpty else { previous = nil; return false }
            defer { previous = frame }
            guard frame == previous else { return false }
            result = frame
            return true
        }, "The search capsule never reached a resting frame")
        return result
    }

    /// A real pointer proves that the pinned field receives input. Native inset text fields can report
    /// not-hittable, while element.tap() auto-scrolls them; neither is proof of a user's tap at this position.
    @MainActor private func focusSearchWithPointer(_ app: XCUIApplication) {
        let search = app.textFields["librarySearch"]
        XCTAssertTrue(search.wait(until: NSPredicate(format: "hasKeyboardFocus == false"), within: 5),
                      "focus must change as a result of the pointer event")
        let frame = settledFrame(search)
        guard app.windows.firstMatch.frame.contains(frame) else {
            XCTFail("The complete search field must be visible before sending a pointer event")
            return
        }
        app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
        XCTAssertTrue(search.wait(until: NSPredicate(format: "hasKeyboardFocus == true"), within: 5),
                      "the visible pinned field receives a physical tap without accessibility auto-scrolling")
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
        let paused = scrolledRow(app, "Paused standup")
        XCTAssertTrue(paused.exists)
        let resume = app.buttons["Resume transcribing Paused standup"]
        XCTAssertTrue(resume.waitForExistence(within: 10))
        // A partially offscreen button can report hittable even when its centre is below the capture bar.
        // Require the whole card to be visible, then tap once after the Library's interaction event.
        XCTAssertGreaterThanOrEqual(resume.frame.height, 44 - 0.001, "a 44 pt target")
        XCTAssertLessThanOrEqual(resume.frame.maxY, app.buttons["recordButton"].frame.minY)
        XCTAssertTrue(resume.tapWhenInteractive(in: app) {
            row(app, "Paused standup").exists && row(app, "Paused standup").label.contains(", queued")
        }, row(app, "Paused standup").label)
        let failed = scrolledRow(app, "Hallway conversation")
        XCTAssertTrue(failed.exists)
        let tryAgain = app.buttons["Try transcribing Hallway conversation again"]
        XCTAssertTrue(tryAgain.waitForExistence(within: 5))
        XCTAssertGreaterThanOrEqual(tryAgain.frame.height, 44 - 0.001, "a 44 pt target")
        XCTAssertLessThanOrEqual(tryAgain.frame.maxY, app.buttons["recordButton"].frame.minY)
        XCTAssertTrue(tryAgain.tapWhenInteractive(in: app) {
            row(app, "Hallway conversation").exists && row(app, "Hallway conversation").label.contains(", queued")
        }, row(app, "Hallway conversation").label)
    }

    // ports: LibraryBehaviourTest#theControlsSendTheirEvents
    @MainActor func testTheControlsLeadWhereTheySay() {
        let app = launch(["--seed", "statuses"] + DeviceUnderTest.workingSpeech)
        let running = row(app, "Weekly planning call")
        XCTAssertTrue(running.waitForExistence(within: 15))
        XCTAssertTrue(waitFor(running, label: ", transcribing"), running.label)
        let queued = row(app, "Interview with the printer")
        XCTAssertTrue(queued.waitForExistence(within: 15))
        XCTAssertTrue(waitFor(queued, label: ", queued"), queued.label)
        XCTAssertFalse(app.buttons["progressBanner"].exists, "the running meeting reports progress in its row")
        XCTAssertTrue(app.buttons["importButton"].isEnabled)
        XCTAssertEqual(app.buttons["recordButton"].label, "Record a new note")
        running.tap()
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
        XCTAssertTrue(date.wait(until: NSPredicate(format: "label CONTAINS 'Any date'"), within: 5),
                      "Clear resets the date filter while Search stays open")
        XCTAssertTrue(app.buttons["closeLibrarySearch"].exists, "Clear keeps Search open")
        search.tap()
        search.typeText("thurs\n")
        XCTAssertTrue(garden.waitForExistence(within: 15))
        XCTAssertTrue(date.label.contains("Any date"), "A new search has no remembered date filter")
    }

    @MainActor func testOneSpeakerRowKeepsItsSpokenStateWithoutADoneChip() {
        let app = launch(["--seed", "oneSpeaker"])
        let solo = row(app, "Solo planning")
        XCTAssertTrue(solo.waitForExistence(within: 15))
        XCTAssertTrue(waitFor(solo, label: ", transcribed"), "the completed state remains available to VoiceOver")
        XCTAssertTrue(waitFor(solo, label: "1 speaker"), "a single known speaker has the same metadata as multiple speakers")
        XCTAssertFalse(app.staticTexts["Transcribed"].exists, "completed meetings do not repeat a visual done chip")
        capture("One speaker without done chip")
    }

    @MainActor func testIPadOneSpeakerRowKeepsItsSpokenStateWithoutADoneChip() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the Library sidebar")
        testOneSpeakerRowKeepsItsSpokenStateWithoutADoneChip()
    }

    @MainActor func testIPadOrdinaryRowsOmitQuotesAndSearchKeepsItsHighlightedExcerpt() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the Library sidebar")
        testOrdinaryRowsOmitQuotesAndSearchKeepsItsHighlightedExcerpt()
    }

    @MainActor private func assertSearchControlsAndSingleResultAreVisible(_ app: XCUIApplication,
                                                                         result: XCUIElement,
                                                                         file: StaticString = #filePath, line: UInt = #line) {
        let count = app.staticTexts["librarySearchCount"]
        let date = app.buttons["librarySearchDate"]
        XCTAssertTrue(poll(within: 5) {
            guard date.exists, dateControl(app).isEnabled else { return false }
            let pane = app.scrollViews["libraryScroll"].frame.intersection(app.windows.firstMatch.frame)
            return pane.contains(date.frame) && date.frame.minY >= app.textFields["librarySearch"].frame.maxY
                && date.frame.maxY <= app.buttons["recordButton"].frame.minY
        },
                      "opening Search brings the date filter into view without another swipe", file: file, line: line)
        XCTAssertTrue(count.wait(until: NSPredicate(format: "label == '1 meeting' AND hittable == true"), within: 15),
                      "the published result count is visible after the scrolled list is searched", file: file, line: line)
        XCTAssertTrue(result.wait(until: NSPredicate(format: "hittable == true"), within: 15),
                      "the matching meeting is in view without another swipe", file: file, line: line)
    }

    /// iPadOS 18 exposes an outer Menu wrapper with no activation point and its native button beneath it.
    /// Target the actual button when present, keeping the labeled wrapper for date-value assertions.
    @MainActor private func dateControl(_ app: XCUIApplication) -> XCUIElement {
        let menu = app.buttons["librarySearchDate"]
        let native = menu.buttons.firstMatch
        return native.exists ? native : menu
    }

    private var submitEmptyBeforeSidebarMenu: Bool {
        if #available(iOS 26.0, *) { return false }
        return true
    }

    /// iPadOS 18 can expose the sidebar scroll view beyond the window's left edge. Drag within its visible pane,
    /// clear of the pinned controls, rather than asking XCTest to swipe that unclipped accessibility frame.
    @MainActor private func scrollSidebar(_ app: XCUIApplication, up: Bool = true, until done: () -> Bool) -> Bool {
        for _ in 0..<12 {
            if done() { return true }
            let pane = app.scrollViews["libraryScroll"].frame.intersection(app.windows.firstMatch.frame)
            let top = max(pane.minY, app.textFields["librarySearch"].frame.maxY) + 24
            let bottom = min(pane.maxY, app.buttons["recordButton"].frame.minY) - 24
            guard !pane.isEmpty, bottom - top > 100 else { return false }
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: pane.midX, dy: up ? bottom : top))
            let end = origin.withOffset(CGVector(dx: pane.midX, dy: up ? top : bottom))
            start.press(forDuration: 0, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
        }
        return done()
    }

    @MainActor private func assertClosingEmptySearchResetsDate(_ app: XCUIApplication,
                                                             submitEmptyBeforeDate: Bool = false,
                                                             file: StaticString = #filePath, line: UInt = #line) {
        let search = app.textFields["librarySearch"]
        search.tap()
        capture("Empty Library search focused before choosing a date")
        let close = app.buttons["closeLibrarySearch"]
        XCTAssertTrue(close.waitForExistence(within: 5), file: file, line: line)
        if submitEmptyBeforeDate {
            // iPadOS 18 reports the landscape keyboard's AX frame in portrait coordinates, covering Any date.
            // Submit the still-empty field natively, then wait for keyboard dismissal before opening the menu.
            search.typeText("\n")
            XCTAssertTrue(search.wait(until: NSPredicate(format: "hasKeyboardFocus == false"), within: 5), file: file, line: line)
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(within: 5), file: file, line: line)
            XCTAssertFalse(app.staticTexts["librarySearchCount"].exists, "an empty Submit creates no query", file: file, line: line)
            XCTAssertTrue(close.isHittable, "empty Submit keeps Search open", file: file, line: line)
        }
        let date = app.buttons["librarySearchDate"]
        XCTAssertFalse(date.exists, "Date filtering requires a typed query", file: file, line: line)
        search.tap()
        search.typeText("Thursday\n")
        XCTAssertTrue(app.staticTexts["librarySearchCount"].waitForExistence(within: 5), file: file, line: line)
        XCTAssertTrue(date.waitForExistence(within: 5), file: file, line: line)
        dateControl(app).tapWhenSettled()
        app.buttons["Today"].tapWhenSettled()
        XCTAssertTrue(date.wait(until: NSPredicate(format: "label CONTAINS 'Today'"), within: 5), file: file, line: line)
        search.tap()
        search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        XCTAssertTrue(date.waitForNonExistence(within: 5), "Clearing Search removes its date filter", file: file, line: line)
        XCTAssertTrue(row(app, "Garden plans for the spring").waitForExistence(within: 5), file: file, line: line)
        if submitEmptyBeforeDate {
            search.typeText("\n")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(within: 5), file: file, line: line)
        }
        close.tap()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(within: 5), file: file, line: line)
        XCTAssertFalse(close.exists, file: file, line: line)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(within: 5), file: file, line: line)
        search.tap()
        XCTAssertTrue(close.waitForExistence(within: 5), file: file, line: line)
        XCTAssertFalse(date.exists, "Reopening empty Search offers no date filter", file: file, line: line)
        XCTAssertTrue(search.wait(until: NSPredicate(format: "hasKeyboardFocus == true"), within: 5), file: file, line: line)
        if submitEmptyBeforeDate {
            // A simulator with a hardware keyboard connected shows iPadOS 18's shortcut bar instead of a software
            // keyboard, so the field's own focus is the refocus check on this path.
        } else {
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(within: 5), file: file, line: line)
        }
        if submitEmptyBeforeDate {
            // The same incorrect keyboard frame can also cover Close; the phone path below exercises focused Close.
            search.typeText("\n")
            XCTAssertTrue(search.wait(until: NSPredicate(format: "hasKeyboardFocus == false"), within: 5), file: file, line: line)
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(within: 5), file: file, line: line)
            XCTAssertFalse(app.staticTexts["librarySearchCount"].exists, file: file, line: line)
        }
        close.tap()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(within: 5), file: file, line: line)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(within: 5), file: file, line: line)
    }

    @MainActor func testClosingEmptySearchResetsItsDateFilter() {
        let app = launch(["--seed", "search"])
        assertClosingEmptySearchResetsDate(app)
    }

    @MainActor func testIPadPinnedSearchRetainsItsQueryWhileSidebarReplacesDetail() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the persistent Library sidebar")
        continueAfterFailure = false
        let app = XCUIApplication()
        // Finish the old scene before rotating, as in the other split-view regressions.
        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15))
        XCUIDevice.shared.orientation = .landscapeLeft
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "statuses"] + DeviceUnderTest.workingSpeech
        app.launchAndWait(fresh: true)
        let search = app.textFields["librarySearch"]
        XCTAssertTrue(search.waitForExistence(within: 15))
        assertClosingEmptySearchResetsDate(app, submitEmptyBeforeDate: submitEmptyBeforeSidebarMenu)
        let sidebar = app.scrollViews["libraryScroll"]
        let initialSearchFrame = settledFrame(search)
        let quiet = row(app, "Quiet room")
        let reachedQuiet = scrollSidebar(app) {
            quiet.exists && quiet.isHittable && quiet.frame.maxY < app.buttons["recordButton"].frame.minY
        }
        capture("iPad Library scrolled before opening Search")
        XCTAssertTrue(reachedQuiet, "row=\(quiet.exists ? quiet.frame : .null), sidebar=\(sidebar.frame), record=\(app.buttons["recordButton"].frame)")
        XCTAssertEqual(search.frame, initialSearchFrame, "the sidebar search stays pinned while its rows scroll")
        focusSearchWithPointer(app)
        capture("iPad empty Search focused after scrolling the Library")
        let date = app.buttons["librarySearchDate"]
        let close = app.buttons["closeLibrarySearch"]
        XCTAssertTrue(close.waitForExistence(within: 5))
        if submitEmptyBeforeSidebarMenu {
            search.typeText("\n")
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(within: 5))
        }
        // The iPadOS 18 Menu wrapper reports not-hittable even when its native button opens it. Require the
        // actual menu action after scrolling, rather than treating that incorrect AX proxy as interaction proof.
        dateControl(app).tapWhenSettled()
        app.buttons["Today"].tapWhenSettled()
        XCTAssertTrue(date.wait(until: NSPredicate(format: "label CONTAINS 'Today'"), within: 5))
        search.tap()
        search.typeText("planning\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(within: 5))
        let planning = row(app, "Weekly planning call")
        XCTAssertTrue(planning.waitForExistence(within: 15))
        assertSearchControlsAndSingleResultAreVisible(app, result: planning)
        planning.tap()
        let title = app.staticTexts["noteTitle"]
        XCTAssertTrue(title.wait(until: NSPredicate(format: "label == 'Weekly planning call'"), within: 15))
        focusSearchWithPointer(app)
        XCTAssertTrue(close.isHittable)
        XCTAssertTrue(search.waitForValue("planning"), "selecting a meeting keeps the sidebar query")
        close.tap()
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(within: 5))
        XCTAssertTrue(app.buttons["recentlyDeletedButton"].exists)
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 15))
        XCTAssertTrue(app.windows.firstMatch.frame.contains(search.frame), "Settings replaces only the detail column")
        XCTAssertTrue(scrollSidebar(app, up: false) { planning.exists && planning.isHittable })
        planning.tap()
        XCTAssertTrue(title.wait(until: NSPredicate(format: "label == 'Weekly planning call'"), within: 15),
                      "selecting the meeting again replaces Settings without a root-detail Back button")
        XCTAssertTrue(settings.isHittable)
        focusSearchWithPointer(app)
        close.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(within: 5))
    }

    @MainActor func testPinnedSearchClosesAndResetsItsDateFilterAcrossNoteNavigation() {
        let app = launch(["--seed", "statuses"] + DeviceUnderTest.workingSpeech)
        let search = app.textFields["librarySearch"]
        let list = app.scrollViews["libraryScroll"]
        XCTAssertTrue(row(app, "Weekly planning call").waitForExistence(within: 15))
        XCTAssertEqual(app.descendants(matching: .any)["libraryHeading"].label, "All meetings")
        let initialSearchFrame = settledFrame(search)
        let emptyQueryValue = search.value as? String
        let last = row(app, "Quiet room")
        XCTAssertTrue(list.scroll(attempts: 12) {
            last.exists && last.isHittable && last.frame.maxY < app.buttons["recordButton"].frame.minY
        })
        capture("Library scrolled before opening Search")
        XCTAssertEqual(search.frame, initialSearchFrame, "Search is pinned outside the scrolling list")

        focusSearchWithPointer(app)
        capture("Empty Search focused after scrolling the Library")
        let date = app.buttons["librarySearchDate"]
        XCTAssertTrue(date.wait(until: NSPredicate(format: "hittable == true"), within: 5))
        let close = app.buttons["closeLibrarySearch"]
        XCTAssertTrue(close.waitForExistence(within: 5))
        XCTAssertFalse(app.buttons["settingsButton"].exists)
        XCTAssertFalse(app.buttons["recentlyDeletedButton"].exists)
        search.typeText("planning\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(within: 5), "Search submission dismisses the keyboard")
        let planning = row(app, "Weekly planning call")
        XCTAssertTrue(planning.waitForExistence(within: 15))
        assertSearchControlsAndSingleResultAreVisible(app, result: planning)
        date.tap()
        app.buttons["Today"].tapWhenSettled()
        XCTAssertTrue(date.wait(until: NSPredicate(format: "label CONTAINS 'Today'"), within: 5))
        close.tap()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(within: 5))
        XCTAssertTrue(app.buttons["recentlyDeletedButton"].exists)
        XCTAssertFalse(close.exists)
        XCTAssertTrue(poll(within: uiWaitFloor) { (search.value as? String).map { $0.isEmpty || $0 == emptyQueryValue } ?? false },
                      "Close clears the query")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(within: 5))

        search.tap()
        XCTAssertTrue(close.waitForExistence(within: 5))
        search.typeText("planning\n")
        XCTAssertTrue(planning.waitForExistence(within: 15))
        assertSearchControlsAndSingleResultAreVisible(app, result: planning)
        XCTAssertTrue(date.wait(until: NSPredicate(format: "label CONTAINS 'Any date'"), within: 5),
                      "closing Search resets the date filter")
        planning.tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 5))
        XCTAssertEqual(app.staticTexts["noteTitle"].label, "Weekly planning call")
        app.navigationBars.buttons["Back to all meetings"].tap()
        XCTAssertTrue(search.waitForExistence(within: 5), "the note returns to the Library")
        XCTAssertTrue(close.waitForExistence(within: 5))
        XCTAssertTrue(search.waitForValue("planning"), "the open Search survives visiting a meeting")
        assertSearchControlsAndSingleResultAreVisible(app, result: planning)
        close.tap()
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(within: 5))
        settings.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 5), "destination navigation bars are restored")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(search.waitForExistence(within: 5))
        XCTAssertTrue(settings.isHittable)
    }

    @MainActor func testOrdinaryRowsOmitQuotesAndSearchKeepsItsHighlightedExcerpt() {
        let app = launch(["--seed", "search"])
        let fixture = row(app, "A quieter kind of productivity")
        XCTAssertTrue(fixture.waitForExistence(within: 15))
        XCTAssertFalse(app.descendants(matching: .any)["rowPreview"].exists, "ordinary rows omit transcript quote previews")
        XCTAssertTrue(fixture.label.contains("What if being productive"), "VoiceOver retains the transcript context while the visual quote is omitted")
        let search = app.textFields["librarySearch"]
        search.tap()
        search.typeText("tomatoe\n")
        let garden = row(app, "Garden plans for the spring")
        XCTAssertTrue(garden.waitForExistence(within: 15))
        XCTAssertTrue(waitFor(garden, label: "tomatoes"), "the Search result retains its matched excerpt")
        XCTAssertTrue(garden.label.contains("sunny corner"), "the excerpt retains context around the matching word")
        XCTAssertTrue(fixture.waitForNonExistence(within: 5), "a nonmatching meeting is filtered out")
    }

    @MainActor func testThursdaySearchKeepsTheMatchedTurnInTheVisiblePreview() throws {
        let app = launch(["--seed", "search"])
        let search = app.textFields["librarySearch"]
        search.tap()
        search.typeText("Thursday\n")
        XCTAssertTrue(app.staticTexts["librarySearchCount"].waitForExistence(within: 15))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(within: 5))
        let result = row(app, "A quieter kind of productivity")
        XCTAssertTrue(result.waitForExistence(within: 15))
        // rowPreview is intentionally hidden from VoiceOver (the row speaks as one button). Read its rendered
        // pixels instead of the combined row label, which includes text even when the excerpt clips it away.
        let image = try XCTUnwrap(result.screenshot().image.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertTrue(visible.contains("Thursday"), "rowPreview must draw the matched word: \(visible)")
        capture("Thursday remains visible in the multi-turn search excerpt")
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
        XCTAssertFalse(app.staticTexts["Transcribed on this device. Audio never leaves it."].exists,
                       "the Library does not repeat the first-run privacy line")
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
