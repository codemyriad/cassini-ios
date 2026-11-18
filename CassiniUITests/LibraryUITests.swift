import XCTest
import Vision

/// The Library end to end (Android `LibraryBehaviourTest` and the Library rows of `TextLimitBehaviourTest`): its
/// controls, the row statuses and inline actions, the search, the empty states and Rename.
final class LibraryUITests: XCTestCase {
    @MainActor func testIPadRecordingTicksPreserveContextMenu() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        try testRecordingTicksPreserveContextMenu()
    }

    /// A live tick must update the label and pixels without dismissing the row's context menu.
    @MainActor func testRecordingTicksPreserveContextMenu() throws {
        let app = launch(["--seed", "recording"] + DeviceUnderTest.workingSpeech)
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["pauseResumeRecording"].waitForEnabled(within: uiWaitFloor))
        app.buttons["recordingAllMeetings"].tap()
        let meeting = row(app, "Voice note 8 Oct, 09:41")
        XCTAssertTrue(waitFor(meeting, label: ", recording"))
        let initial = meeting.label, frame = meeting.frame
        XCTAssertTrue(poll(within: uiWaitFloor) { meeting.label != initial }, "Live row duration advances")
        XCTAssertEqual(meeting.frame, frame, "Duration updates preserve the row's scroll position")
        try assertRowPixels(meeting, contain: "Recording")
        meeting.press(forDuration: 1)
        let rename = app.buttons["Rename"]
        XCTAssertTrue(rename.waitForExistence(within: uiWaitFloor))
        let card = app.buttons["activeRecordingCard"]
        assertLiveTicksPreserveMenu(rename, card: card)
        captureEvidence("Live recording context menu after duration tick", app)
        XCTAssertTrue(rename.exists, "A duration tick must preserve the open context menu")
        rename.tapWhenSettled()
        let field = app.textFields["renameField"]
        XCTAssertTrue(field.waitForExistence(within: uiWaitFloor))
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(within: uiWaitFloor))
        field.replaceText(with: "Live capture renamed")
        app.buttons["Save"].tap()
        let renamed = row(app, "Live capture renamed")
        XCTAssertTrue(renamed.waitForExistence(within: uiWaitFloor))
        renamed.press(forDuration: 1)
        assertLiveTicksPreserveMenu(app.buttons["Star"], card: card)
        app.buttons["Star"].tapWhenSettled()
        // Star changes the render key: require its result before starting another gesture.
        XCTAssertTrue(poll(within: uiWaitFloor) {
            renamed.label.contains(", starred") && !app.buttons["Star"].exists && renamed.isHittable
        }, "Star updates the row and closes its menu")
        renamed.press(forDuration: 1)
        assertLiveTicksPreserveMenu(app.buttons["Remove star"], card: card)
        app.buttons["Remove star"].tapWhenSettled()
        XCTAssertTrue(poll(within: uiWaitFloor) {
            !renamed.label.contains(", starred") && !app.buttons["Remove star"].exists && renamed.isHittable
        }, "Removing the star completes before returning to recording")
        app.buttons["activeRecordingCard"].tap()
        XCTAssertTrue(app.buttons["stopRecording"].waitForExistence(within: uiWaitFloor))
        app.buttons["stopRecording"].tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: uiWaitFloor))
        if UIDevice.current.userInterfaceIdiom != .pad { app.navigationBars.buttons["Back to all meetings"].tap() }
        XCTAssertTrue(waitFor(renamed, label: ", transcribed"))
        assertIPadSplitView(app)
        try assertRowPixels(renamed, contain: "2 speakers", excluding: "Recording")
    }

    @MainActor private func assertLiveTicksPreserveMenu(_ item: XCUIElement, card: XCUIElement,
                                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(item.waitForExistence(within: uiWaitFloor), file: file, line: line)
        // Exercise every menu across multiple ticks, including after a rename/star replaces the row.
        // Native menus can expose their final AX frame before their entrance animation accepts a tap.
        for _ in 0..<2 {
            let elapsed = card.label
            XCTAssertTrue(poll(within: uiWaitFloor) { card.label != elapsed }, "Capture advances with menu open", file: file, line: line)
            XCTAssertTrue(item.exists, "A live tick preserves the menu action", file: file, line: line)
        }
    }

    @MainActor func testPostRecordingFirstNoteAndActions() throws {
        let app = launch(["--seed", "recording"] + DeviceUnderTest.workingSpeech)
        // Keep the fixture's fake microphone, but empty its library through real actions.
        while app.buttons.matching(identifier: "noteRow").count > 0 {
            let count = app.buttons.matching(identifier: "noteRow").count
            let note = app.buttons.matching(identifier: "noteRow").firstMatch
            note.press(forDuration: 1)
            app.buttons["Move to Recently Deleted"].tapWhenSettled()
            XCTAssertTrue(app.buttons["Undo"].waitForExistence(within: uiWaitFloor))
            XCTAssertTrue(poll(within: uiWaitFloor) { app.buttons.matching(identifier: "noteRow").count < count })
        }
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(within: uiWaitFloor))
        captureEvidence("06-empty-library-before-first-recording", app)
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["pauseResumeRecording"].waitForEnabled(within: uiWaitFloor))
        app.buttons["recordingAllMeetings"].tap()
        let meeting = row(app, "Voice note 8 Oct, 09:41")
        XCTAssertTrue(waitFor(meeting, label: ", recording"))
        XCTAssertFalse(app.staticTexts["heroTitle"].exists)
        XCTAssertTrue(app.staticTexts["TODAY"].exists)
        try assertRowPixels(meeting, contain: "Recording")
        captureEvidence("07-first-recording-minimised", app)
        meeting.tap()
        XCTAssertTrue(app.buttons["pauseResumeRecording"].waitForEnabled(within: uiWaitFloor))
        app.buttons["pauseResumeRecording"].tap()
        XCTAssertTrue(app.buttons["Resume recording"].waitForExistence(within: uiWaitFloor))
        app.buttons["recordingAllMeetings"].tap()
        XCTAssertTrue(app.buttons["activeRecordingCard"].waitForExistence(within: uiWaitFloor))
        XCTAssertTrue(app.buttons["activeRecordingCard"].label.contains("Recording paused"))
        try assertRowPixels(meeting, contain: "Recording")
        captureEvidence("First recording paused in Library", app)
        app.buttons["activeRecordingCard"].tap()
        XCTAssertTrue(app.buttons["Resume recording"].waitForExistence(within: uiWaitFloor))
        app.buttons["pauseResumeRecording"].tap()
        XCTAssertTrue(app.buttons["Pause recording"].waitForExistence(within: uiWaitFloor))
        app.buttons["stopRecording"].tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: uiWaitFloor))
        captureEvidence("First recording detail", app)
        app.navigationBars.buttons["Back to all meetings"].tap()
        XCTAssertTrue(waitFor(meeting, label: ", transcribed"))
        try assertRowPixels(meeting, contain: "2 speakers", excluding: "Recording")
        XCTAssertFalse(app.buttons["activeRecordingCard"].exists)
        XCTAssertFalse(app.staticTexts["heroTitle"].exists)
        XCTAssertTrue(app.staticTexts["TODAY"].exists)
        XCTAssertEqual(app.buttons["recordButton"].label, "Record a new note")
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["pauseResumeRecording"].waitForEnabled(within: uiWaitFloor))
        app.buttons["stopRecording"].tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: uiWaitFloor))
        app.navigationBars.buttons["Back to all meetings"].tap()
        XCTAssertTrue(waitFor(meeting, label: ", transcribed"))
        let duplicates = app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@", "Voice note 8 Oct, 09:41"))
        XCTAssertTrue(poll(within: uiWaitFloor) { duplicates.count == 2 })
        for note in duplicates.allElementsBoundByIndex {
            XCTAssertTrue(waitFor(note, label: ", transcribed"))
            try assertRowPixels(note, contain: "2 speakers", excluding: "Recording")
        }
        captureEvidence("Two consecutive recordings with identical generated titles", app)
        let field = openRename(app, "Voice note 8 Oct, 09:41")
        field.replaceText(with: "First capture")
        app.buttons["Save"].tap()
        let first = row(app, "First capture")
        XCTAssertTrue(first.waitForExistence(within: uiWaitFloor))
        XCTAssertEqual(app.buttons.matching(identifier: "noteRow").count, 2)
        try assertRowPixels(first, contain: "2 speakers", excluding: "Recording")
        try assertRowPixels(meeting, contain: "2 speakers", excluding: "Recording")
        meeting.press(forDuration: 1)
        app.buttons["Star"].tapWhenSettled()
        app.buttons["Starred"].tapWhenSettled()
        XCTAssertTrue(poll(within: uiWaitFloor) { meeting.exists && !first.exists })
        app.buttons["All"].tapWhenSettled()
        XCTAssertTrue(first.waitForExistence(within: uiWaitFloor))
        let search = app.textFields["librarySearch"]
        search.tap(); search.typeText("Voice note\n")
        XCTAssertTrue(app.staticTexts["librarySearchCount"].waitForExistence(within: uiWaitFloor))
        try assertRowPixels(meeting, contain: "2 speakers", excluding: "Recording")
        app.buttons["closeLibrarySearch"].tapWhenSettled()
        let rename = openRename(app, "Voice note 8 Oct, 09:41")
        rename.replaceText(with: "Second capture")
        app.buttons["Save"].tap()
        let second = row(app, "Second capture")
        XCTAssertTrue(second.waitForExistence(within: uiWaitFloor))
        second.press(forDuration: 1)
        app.buttons["Move to Recently Deleted"].tapWhenSettled()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(within: uiWaitFloor))
        app.buttons["Undo"].tap()
        XCTAssertTrue(second.waitForExistence(within: uiWaitFloor))
        second.press(forDuration: 1)
        app.buttons["Move to Recently Deleted"].tapWhenSettled()
        XCTAssertTrue(app.buttons["Undo"].waitForExistence(within: uiWaitFloor))
        app.buttons["Recently Deleted"].tap()
        XCTAssertTrue(app.buttons["Restore"].firstMatch.waitForExistence(within: uiWaitFloor))
        // The fixed test clock gives all trash entries the same deletion date; locate this card by title.
        let deletedTitle = app.staticTexts["Second capture"]
        XCTAssertTrue(app.scrollViews.firstMatch.scroll { deletedTitle.exists && deletedTitle.isHittable })
        let belowTitle = app.buttons.matching(identifier: "Restore").allElementsBoundByIndex
            .filter { $0.frame.minY >= deletedTitle.frame.maxY }
        guard let restore = belowTitle.min(by: { $0.frame.minY < $1.frame.minY }) else {
            XCTFail("The recorded note's Restore button is missing"); return
        }
        restore.tapWhenSettled()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(second.waitForExistence(within: uiWaitFloor))
        try assertRowPixels(second, contain: "2 speakers", excluding: "Recording")
        captureEvidence("Post-recording renamed and restored", app)
    }

    @MainActor func testFinishedRecordingDeclinedModelsIsAudioOnly() throws {
        let app = launch(["--seed", "recording", "--models-missing"] + DeviceUnderTest.downloadedSpeech)
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["pauseResumeRecording"].waitForEnabled(within: uiWaitFloor))
        app.buttons["recordingAllMeetings"].tap()
        let meeting = scrolledRow(app, "Voice note 8 Oct, 09:41")
        XCTAssertTrue(waitFor(meeting, label: ", recording"))
        meeting.tap()
        XCTAssertTrue(app.buttons["stopRecording"].waitForExistence(within: uiWaitFloor))
        app.buttons["stopRecording"].tap()
        let notNow = app.buttons["modelDownloadNotNow"]
        XCTAssertTrue(notNow.waitForExistence(within: uiWaitFloor))
        captureEvidence("Post-recording missing model consent", app)
        notNow.tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: uiWaitFloor))
        XCTAssertTrue(app.buttons["Transcribe"].waitForExistence(within: uiWaitFloor))
        app.navigationBars.buttons["Back to all meetings"].tap()
        XCTAssertTrue(waitFor(meeting, label: ", audio only"))
        try assertRowPixels(meeting, contain: "Audio only", excluding: "Recording")
        captureEvidence("Post-recording declined consent audio only", app)
    }

    @MainActor func testSpeakerAndRecordedByMeChipsAndRememberedLibraryChoice() {
        let app = launch(["--seed", "libraryFilters"])
        let recovered = row(app, "Recovered budget")
        let imported = row(app, "Imported budget")
        XCTAssertTrue(imported.waitForExistence(within: uiWaitFloor))
        app.buttons["Starred"].tapWhenSettled()
        XCTAssertTrue(poll(within: uiWaitFloor) { recovered.exists && !imported.exists })
        app.launchArguments = ["--ui-testing", "--seed", "libraryFilters"]
        app.launchAndWait(fresh: true)
        XCTAssertTrue(recovered.waitForExistence(within: uiWaitFloor))
        XCTAssertFalse(imported.exists, "Starred survives a new process")
        app.buttons["All"].tapWhenSettled()
        XCTAssertTrue(imported.waitForExistence(within: uiWaitFloor))
        app.launchAndWait(fresh: true)
        XCTAssertTrue(imported.waitForExistence(within: uiWaitFloor), "All survives a new process")

        let search = app.textFields["librarySearch"]
        search.tap()
        search.typeText("budget\n")
        let speaker = app.buttons["librarySearchSpeaker"]
        XCTAssertTrue(speaker.waitForExistence(within: uiWaitFloor))
        speaker.tapWhenSettled()
        app.buttons["Alice"].tapWhenSettled()
        XCTAssertTrue(poll(within: uiWaitFloor) {
            app.staticTexts["librarySearchCount"].label == "0 meetings"
        })
        XCTAssertFalse(recovered.exists, "A title or Bob's words cannot match Alice")
        speaker.tapWhenSettled()
        app.buttons["Bob"].tapWhenSettled()
        XCTAssertTrue(waitFor(recovered, label: "belongs to Bob"))
        app.buttons["Clear search"].tapWhenSettled()
        speaker.tapWhenSettled()
        app.buttons["Alice"].tapWhenSettled()
        XCTAssertTrue(imported.waitForExistence(within: uiWaitFloor), "Filter-only search finds Alice")
        let own = app.buttons["libraryRecordedByMe"]
        // iOS 18 can report a clipped chip as hittable even when its centre is outside the scroll view.
        let filters = app.scrollViews["librarySearchFilters"]
        for _ in 0..<5 {
            if own.exists && filters.frame.contains(own.frame) { break }
            filters.swipeLeft()
        }
        XCTAssertTrue(filters.frame.contains(own.frame))
        own.tapWhenSettled()
        XCTAssertTrue(poll(within: uiWaitFloor) { own.isSelected })
        XCTAssertTrue(poll(within: uiWaitFloor) { recovered.exists && !imported.exists })
        app.buttons["closeLibrarySearch"].tapWhenSettled()
        XCTAssertTrue(imported.waitForExistence(within: uiWaitFloor), "Closing Search restores All")
    }

    @MainActor func testImportedProvenanceInLibrarySearchAndHeader() {
        let app = launch(["--seed", "importedProvenance"])
        let imported = row(app, "Imported audio planning")
        XCTAssertTrue(imported.waitForExistence(within: uiWaitFloor))
        XCTAssertTrue(imported.label.contains("imported"))
        XCTAssertTrue(imported.label.contains("transcribed"))
        let search = app.textFields["librarySearch"]
        search.tap()
        search.typeText("Imported audio planning\n")
        XCTAssertTrue(waitFor(imported, label: "imported"))
        imported.tap()
        let subtitle = app.staticTexts["noteSubtitle"]
        XCTAssertTrue(subtitle.waitForExistence(within: uiWaitFloor))
        XCTAssertTrue(subtitle.label.contains("Imported"))
        XCTAssertFalse(subtitle.label.contains("Transcribed on another device"))
    }

    @MainActor func testImportedDocumentHeaderNamesOtherDevice() {
        let app = launch(["--seed", "importedProvenance"])
        let imported = scrolledRow(app, "Imported document planning")
        XCTAssertTrue(imported.label.contains("imported"))
        imported.tap()
        let subtitle = app.staticTexts["noteSubtitle"]
        XCTAssertTrue(subtitle.waitForExistence(within: uiWaitFloor))
        XCTAssertTrue(subtitle.label.contains("Imported · Transcribed on another device"))
    }

    @MainActor private func launch(_ arguments: [String] = ["--seed-test-data"]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data"] + arguments
        app.launchAndWait()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15))
        return app
    }

    @MainActor func testImportingCardShowsSharedSpinnerBadge() {
        let app = launch(["--importing-fixture"])
        let card = app.descendants(matching: .any)["importingCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(within: 15))
        XCTAssertTrue(card.staticTexts["Audio.ogg"].exists)
        XCTAssertTrue(card.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Importing…")).firstMatch.exists)
        XCTAssertFalse(app.buttons["retryImport"].exists)
        XCTAssertFalse(app.buttons["dismissImport"].exists)
        capture("Importing audio")
    }

    @MainActor func testFailedImportKeepsNeedsAttentionCardAndCanRetryAndDismiss() {
        let app = launch(["--failed-import-fixture"])
        let card = app.descendants(matching: .any)["failedImportCard"].firstMatch
        XCTAssertTrue(card.waitForExistence(within: 15))
        XCTAssertTrue(card.staticTexts["Damaged audio.ogg"].exists)
        XCTAssertTrue(card.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Needs attention")).firstMatch.exists)
        XCTAssertTrue(app.buttons["retryImport"].exists)
        capture("Failed import - Needs attention")
        app.buttons["retryImport"].tapWhenSettled()
        XCTAssertTrue(app.buttons["dismissImport"].waitForExistence(within: 15))
        app.buttons["dismissImport"].tapWhenSettled()
        XCTAssertTrue(app.textFields["librarySearch"].exists)
        XCTAssertFalse(card.exists)
    }

    @MainActor private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@", title)).firstMatch
    }

    /// The library's list. Swipes go to it: on iPad the middle of the screen is the note beside it.
    @MainActor private func list(_ app: XCUIApplication) -> XCUIElement {
        app.scrollViews["libraryScroll"]
    }

    @MainActor private func scrolledRow(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.scrolledLibraryRow(title)
    }

    @MainActor private func waitFor(_ element: XCUIElement, label: String, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate(format: "label CONTAINS %@", label)
        return element.wait(until: predicate, within: timeout)
    }

    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor private func captureEvidence(_ name: String, _ app: XCUIApplication) {
        capture(name)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + " hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
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

    /// L-49: All meetings on the left, Stop in the centre and a labelled Pause or Resume on the right.
    @MainActor func testRecordingControlsPutStopInTheCentre() {
        let app = launch(["--seed", "recording"])
        app.buttons["recordButton"].tap()
        let pause = app.buttons["pauseResumeRecording"], stop = app.buttons["stopRecording"]
        let allMeetings = app.buttons["recordingAllMeetings"]
        XCTAssertTrue(pause.waitForEnabled(within: 8))
        XCTAssertEqual(stop.label, "Stop")
        XCTAssertEqual(pause.label, "Pause recording")
        XCTAssertEqual(allMeetings.label, "All meetings")
        XCTAssertFalse(app.staticTexts["Title"].exists, "no visible Title caption (L-48)")
        XCTAssertLessThan(allMeetings.frame.midX, stop.frame.midX)
        XCTAssertLessThan(stop.frame.midX, pause.frame.midX)
        XCTAssertEqual(stop.frame.midX, app.windows.firstMatch.frame.midX, accuracy: 2, "Stop is centred")
        XCTAssertGreaterThanOrEqual(stop.frame.height, 44)
        pause.tap()
        XCTAssertTrue(app.buttons["Resume recording"].waitForExistence(within: 5))
        stop.tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 10), "Stop saves and opens the note")
    }

    @MainActor func testFinishedRecordingRefreshesMaterializedRow() throws {
        try assertFinishedRecordingRow(minimised: true)
    }

    @MainActor func testFinishedRecordingRefreshesCoveredLibrary() throws {
        try assertFinishedRecordingRow(minimised: false)
    }

    @MainActor func testIPadFinishedRecordingRefreshesMaterializedRow() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        try assertFinishedRecordingRow(minimised: true)
    }

    @MainActor func testIPadFinishedRecordingRefreshesCoveredLibrary() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        try assertFinishedRecordingRow(minimised: false)
    }

    @MainActor func testFinishedAudioOnlyRecordingRefreshesMaterializedRow() throws {
        try assertFinishedRecordingRow(minimised: true, automatic: false)
    }

    @MainActor func testFinishedAudioOnlyRecordingRefreshesCoveredLibrary() throws {
        try assertFinishedRecordingRow(minimised: false, automatic: false)
    }

    @MainActor func testIPadFinishedAudioOnlyRecordingRefreshesMaterializedRow() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        try assertFinishedRecordingRow(minimised: true, automatic: false)
    }

    @MainActor func testIPadFinishedAudioOnlyRecordingRefreshesCoveredLibrary() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        try assertFinishedRecordingRow(minimised: false, automatic: false)
    }

    @MainActor func testFinishedRecordingRefreshesMaterializedSearchRow() throws {
        try assertFinishedRecordingRow(minimised: true, automatic: true, search: true)
    }

    @MainActor func testFinishedRecordingRefreshesCoveredSearchRow() throws {
        try assertFinishedRecordingRow(minimised: false, automatic: true, search: true)
    }

    @MainActor func testFinishedAudioOnlyRecordingRefreshesMaterializedSearchRow() throws {
        try assertFinishedRecordingRow(minimised: true, automatic: false, search: true)
    }

    @MainActor func testFinishedAudioOnlyRecordingRefreshesCoveredSearchRow() throws {
        try assertFinishedRecordingRow(minimised: false, automatic: false, search: true)
    }

    @MainActor func testIPadFinishedRecordingRefreshesMaterializedSearchRow() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        try assertFinishedRecordingRow(minimised: true, automatic: true, search: true)
    }

    @MainActor func testIPadFinishedRecordingRefreshesCoveredSearchRow() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        try assertFinishedRecordingRow(minimised: false, automatic: true, search: true)
    }

    @MainActor func testIPadFinishedAudioOnlyRecordingRefreshesMaterializedSearchRow() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        try assertFinishedRecordingRow(minimised: true, automatic: false, search: true)
    }

    @MainActor func testIPadFinishedAudioOnlyRecordingRefreshesCoveredSearchRow() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        try assertFinishedRecordingRow(minimised: false, automatic: false, search: true)
    }

    @MainActor private func assertFinishedRecordingRow(minimised: Bool, automatic: Bool = true, search: Bool = false) throws {
        // The 13-inch iPad destination has regular width in portrait too. Use the normal in-app
        // relaunch: terminating and rotating SpringBoard can wedge its idle wait on iOS 27.
        let app = launch(["--seed", "recording"] + DeviceUnderTest.workingSpeech)
        if !automatic {
            app.buttons["settingsButton"].tap()
            XCTAssertTrue(app.buttons["transcriptionRow"].waitForExistence(within: 15))
            app.buttons["transcriptionRow"].tap()
            let toggle = app.switches["autoTranscribeToggle"]
            XCTAssertTrue(toggle.waitForExistence(within: uiWaitFloor))
            // SwiftUI exposes the form row as a switch too; activate the nested UISwitch.
            if toggle.value as? String != "0" {
                toggle.switches.firstMatch.tap()
            }
            XCTAssertTrue(toggle.waitForValue("0"), "Automatic transcription is off before starting")
            app.navigationBars.buttons.firstMatch.tap()
            if UIDevice.current.userInterfaceIdiom != .pad {
                app.navigationBars.buttons["All meetings"].tap()
            }
        }
        if UIDevice.current.userInterfaceIdiom == .pad && automatic {
            // Finishing a recording must replace an existing detail, not push above the old selection.
            row(app, "A quieter kind of productivity").tap()
            XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: uiWaitFloor))
        }
        if search {
            app.textFields["librarySearch"].tap()
            app.textFields["librarySearch"].typeText("Voice note\n")
            XCTAssertTrue(app.staticTexts["librarySearchCount"].waitForExistence(within: uiWaitFloor))
        }
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["pauseResumeRecording"].waitForEnabled(within: uiWaitFloor))
        let meeting = row(app, "Voice note 8 Oct, 09:41")
        if minimised {
            app.buttons["recordingAllMeetings"].tap()
            XCTAssertTrue(waitFor(meeting, label: ", recording"), meeting.label)
            try assertRowPixels(meeting, contain: "Recording")
            meeting.tap()
            XCTAssertTrue(app.buttons["stopRecording"].waitForExistence(within: uiWaitFloor))
        }
        app.buttons["stopRecording"].tap()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: uiWaitFloor))
        // The regular-width Library stays alongside the detail; compact width returns via Back.
        if UIDevice.current.userInterfaceIdiom != .pad {
            app.navigationBars.buttons["Back to all meetings"].tap()
        }
        XCTAssertTrue(waitFor(meeting, label: automatic ? ", transcribed" : ", audio only"), meeting.label)
        XCTAssertFalse(meeting.label.localizedCaseInsensitiveContains("recording"), meeting.label)
        assertIPadSplitView(app)
        if UIDevice.current.userInterfaceIdiom == .pad { XCTAssertTrue(meeting.isSelected, "Finished note is selected beside its detail") }
        try assertRowPixels(meeting, contain: automatic ? "2 speakers" : "Audio only", excluding: "Recording")
        XCTAssertTrue(app.buttons["recordButton"].waitForEnabled(within: uiWaitFloor))
        XCTAssertEqual(app.buttons["recordButton"].label, "Record a new note")
        XCTAssertFalse(app.buttons["activeRecordingCard"].exists)
        try assertRowPixels(app.buttons["recordButton"], contain: "Record", excluding: "Recording")
        captureEvidence(UIDevice.current.userInterfaceIdiom == .pad ? "05-after-fix-ipad-split-view"
            : automatic ? "03-after-fix-after-stop-transcribed" : "04-after-fix-after-stop-audio-only", app)
        if UIDevice.current.userInterfaceIdiom == .pad && !automatic {
            app.buttons["Transcribe"].tap()
            XCTAssertTrue(waitFor(meeting, label: ", transcribed"), meeting.label)
            try assertRowPixels(meeting, contain: "2 speakers", excluding: "Recording")
            app.buttons["Share and more"].tap()
            app.buttons["Star"].tapWhenSettled()
            XCTAssertTrue(waitFor(meeting, label: ", starred"), meeting.label)
            XCTAssertTrue(meeting.isSelected)
            captureEvidence("iPad sidebar after detail Transcribe and Star", app)
        }
    }

    @MainActor private func assertIPadSplitView(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }
        let search = app.textFields["librarySearch"], title = app.staticTexts["noteTitle"]
        XCTAssertTrue(search.isHittable, "Library sidebar remains visible", file: file, line: line)
        XCTAssertTrue(title.isHittable, "Note detail remains visible", file: file, line: line)
        XCTAssertLessThanOrEqual(search.frame.maxX, title.frame.minX, "Library sits beside the detail", file: file, line: line)
    }

    @MainActor private func assertRowPixels(_ row: XCUIElement, contain expected: String, excluding forbidden: String? = nil) throws {
        var visible = ""
        XCTAssertTrue(poll(within: uiWaitFloor) {
            guard row.exists, row.isHittable, let image = row.screenshot().image.cgImage else { return false }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            do { try VNImageRequestHandler(cgImage: image).perform([request]) }
            catch { visible = String(describing: error); return false }
            visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            return visible.localizedCaseInsensitiveContains(expected)
                && !(forbidden.map { visible.localizedCaseInsensitiveContains($0) } ?? false)
        }, "Expected rendered \(expected), excluding \(forbidden ?? "nothing"): \(visible)")
    }

    // ports: LibraryBehaviourTest#duringARecordingTheCardAndTheButtonReturnToIt
    @MainActor func testDuringARecordingTheCardTheButtonAndTheRowReturnToIt() {
        let app = launch(["--seed", "recording"])
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["Pause recording"].waitForEnabled(within: 8))
        app.buttons["recordingAllMeetings"].tap()
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
        XCTAssertTrue(app.buttons["stopRecording"].waitForExistence(within: 5))
        app.buttons["recordingAllMeetings"].tap()
        XCTAssertTrue(card.waitForExistence(within: 5))
        card.tap()
        XCTAssertTrue(app.buttons["stopRecording"].waitForExistence(within: 5))
        app.buttons["recordingAllMeetings"].tap()
        XCTAssertTrue(recordingRow.waitForExistence(within: 5))
        recordingRow.tap()
        XCTAssertTrue(app.buttons["stopRecording"].waitForExistence(within: 5), "the recording's row returns to it")
    }

    /// Search shows flat results with their day, says when nothing matches, and opens a note.
    /// A note stored with the reason Whistle took its transcription shows the notice when it is opened after a
    /// launch; a note without one does not.
    @MainActor func testANoteWhistleTranscribedAfterParakeetCouldNotRunSaysSo() {
        let app = launch(["--seed", "search"])
        let notice = app.staticTexts["Parakeet Ultra couldn’t run on this device for this recording, so Whistle transcribed it."]
        let review = scrolledRow(app, "Notes from the design review")
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
        XCTAssertTrue(date.exists, "Search keeps its unified filter row after clearing the text")
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
        XCTAssertTrue(date.exists, "Open Search offers its filter row before typing", file: file, line: line)
        search.tap()
        search.typeText("Thursday\n")
        XCTAssertTrue(app.staticTexts["librarySearchCount"].waitForExistence(within: 5), file: file, line: line)
        XCTAssertTrue(date.waitForExistence(within: 5), file: file, line: line)
        dateControl(app).tapWhenSettled()
        app.buttons["Today"].tapWhenSettled()
        XCTAssertTrue(date.wait(until: NSPredicate(format: "label CONTAINS 'Today'"), within: 5), file: file, line: line)
        app.buttons["Clear search"].tapWhenSettled()
        XCTAssertTrue(app.staticTexts["TODAY"].waitForExistence(within: 5), file: file, line: line)
        XCTAssertTrue(date.exists, "Clearing Search keeps its filter row", file: file, line: line)
        close.tap()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(within: 5), file: file, line: line)
        XCTAssertFalse(close.exists, file: file, line: line)
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(within: 5), file: file, line: line)
        search.tap()
        XCTAssertTrue(close.waitForExistence(within: 5), file: file, line: line)
        XCTAssertTrue(date.exists, "Reopening Search offers the unified filter row", file: file, line: line)
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
        XCTAssertTrue(date.exists, "Open Search offers its filter row before typing")
        search.typeText("planning\n")
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(within: 5))
        XCTAssertTrue(date.waitForExistence(within: 5))
        // The iPadOS 18 Menu wrapper can report not-hittable; require the actual native menu action.
        dateControl(app).tapWhenSettled()
        app.buttons["Today"].tapWhenSettled()
        XCTAssertTrue(date.wait(until: NSPredicate(format: "label CONTAINS 'Today'"), within: 5))
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
        XCTAssertTrue(row(app, "Weekly planning call").waitForExistence(within: 15))
        XCTAssertEqual(app.descendants(matching: .any)["libraryHeading"].label, "All meetings")
        let initialSearchFrame = settledFrame(search)
        let emptyQueryValue = search.value as? String
        _ = scrolledRow(app, "Quiet room")
        capture("Library scrolled before opening Search")
        XCTAssertEqual(search.frame, initialSearchFrame, "Search is pinned outside the scrolling list")

        focusSearchWithPointer(app)
        capture("Empty Search focused after scrolling the Library")
        let date = app.buttons["librarySearchDate"]
        XCTAssertTrue(date.exists, "Open Search offers its filter row before typing")
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
        var visible = ""
        XCTAssertTrue(poll(within: 15) {
            guard let image = result.screenshot().image.cgImage else { return false }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            do { try VNImageRequestHandler(cgImage: image).perform([request]) }
            catch { visible = String(describing: error); return false }
            visible = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            return visible.contains("Thursday")
        }, "rowPreview must draw the matched word: \(visible)")
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

    // D105: first run is device-specific and independent of backup settings.
    @MainActor func testAnEmptyLibraryOffersRecordAndImport() {
        let app = launch([])
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let title = app.staticTexts["heroTitle"]
        XCTAssertTrue(title.waitForExistence(within: 15))
        XCTAssertEqual(title.label, "Every word written down.")
        let subtitle = app.descendants(matching: .any)["heroSubtitle"]
        XCTAssertTrue(subtitle.exists)
        XCTAssertEqual(subtitle.label, pad ? "Right here, on this iPad." : "Right here, on this iPhone.")
        let howTo = app.staticTexts["heroHowTo"]
        XCTAssertEqual(howTo.label, "Record something, or import an audio file.")
        let privacy = app.descendants(matching: .any)["heroPrivacy"]
        let expectedPrivacy = pad
            ? "Transcribed on this iPad.\nBackups follow your iCloud settings."
            : "Transcribed on this iPhone.\nBackups follow your iCloud settings."
        XCTAssertEqual(privacy.label, expectedPrivacy)
        XCTAssertFalse(app.staticTexts["No notes yet"].exists, "the Wave 5 hero replaces LIB_EMPTY")
        XCTAssertFalse(app.buttons["Starred"].exists, "the filter bar hides while the Library has no meetings")
        XCTAssertTrue(app.buttons["recordButton"].exists)
        XCTAssertTrue(app.buttons["Import audio"].exists, "Record and Import stay in the bottom capture bar")
        XCTAssertFalse(app.buttons["Import"].exists, "no duplicate Import banner button")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "never leaves")).firstMatch.exists)
        XCTAssertEqual(title.frame.minX, app.scrollViews["libraryScroll"].frame.minX + 16, accuracy: 1)
        XCTAssertEqual(title.frame.minX, app.buttons["importButton"].frame.minX, accuracy: 1)
        XCTAssertGreaterThan(title.frame.minY, app.frame.midY)
        XCTAssertLessThan(privacy.frame.maxY, app.buttons["recordButton"].frame.minY)
        capture("Library empty")
    }

    // D105: excluding backup keeps the same always-true first-run copy.
    @MainActor func testAnEmptyLibraryWithBackupExcludedKeepsTheSameFirstRunCopy() {
        let app = launch(["--backup-excluded"])
        let pad = UIDevice.current.userInterfaceIdiom == .pad
        let title = app.staticTexts["heroTitle"]
        XCTAssertTrue(title.waitForExistence(within: 15))
        XCTAssertEqual(title.label, "Every word written down.")
        let subtitle = app.descendants(matching: .any)["heroSubtitle"]
        XCTAssertEqual(subtitle.label, pad ? "Right here, on this iPad." : "Right here, on this iPhone.")
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "(except for encrypted cloud backup)")).firstMatch.exists)
        let privacy = app.descendants(matching: .any)["heroPrivacy"]
        let expectedPrivacy = pad
            ? "Transcribed on this iPad.\nBackups follow your iCloud settings."
            : "Transcribed on this iPhone.\nBackups follow your iCloud settings."
        XCTAssertEqual(privacy.label, expectedPrivacy)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "never leaves")).firstMatch.exists)
    }

    @MainActor func testIPadEmptyLibraryShowsIPadHeroAndPrivacyLines() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the Library sidebar")
        testAnEmptyLibraryOffersRecordAndImport()
        testAnEmptyLibraryWithBackupExcludedKeepsTheSameFirstRunCopy()
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
        // This regression measures the capture bar at the largest text size. The notice has its own
        // scroll/clearance regressions; dismiss it explicitly before exercising the underlying list.
        let closeNotice = app.buttons["backupNoticeDismiss"]
        XCTAssertTrue(closeNotice.waitForExistence(within: uiWaitFloor))
        closeNotice.tap()
        XCTAssertTrue(app.staticTexts["uiTestState-backupState"].waitForValue("cloud=true;voices=true;dismissed=true"))
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
        assertActionsMenuShares("vtt")
    }

    @MainActor func testTheActionsMenuMarkdownOpensTheNoteAndShares() {
        assertActionsMenuShares("markdown")
    }

    @MainActor func testTheActionsMenuExportCanBeCancelledAndReopened() {
        let app = launch(["--seed", "statuses"])
        let formats = app.buttons["exportChoice-cassiniFile"]
        for _ in 0..<2 {
            let note = scrolledRow(app, "A quieter kind of productivity")
            note.press(forDuration: 1)
            app.buttons["Export"].tapWhenSettled()
            XCTAssertTrue(formats.waitForExistence(within: uiWaitFloor))
            XCTAssertTrue(formats.isSelected, "A reopened selector starts with the default format")
            app.buttons["exportChoice-markdown"].tapWhenSettled()
            app.buttons["Cancel"].tapWhenSettled()
            XCTAssertTrue(formats.waitForNonExistence(within: uiWaitFloor))
            XCTAssertTrue(app.staticTexts["uiTestState-libraryInteractive"].waitForExistence(within: uiWaitFloor))
            XCTAssertFalse(app.staticTexts["noteTitle"].exists, "Cancel stays in the Library")
            XCTAssertFalse(app.otherElements["ActivityListView"].exists, "Selecting a format alone does not share it")
        }
    }

    @MainActor private func assertActionsMenuShares(_ format: String) {
        let app = launch(["--seed", "statuses"])
        XCTAssertTrue(app.buttons["backupNoticeDismiss"].waitForExistence(within: uiWaitFloor),
                      "Keep the multiline backup notice present for the scroll-and-export regression")
        let note = scrolledRow(app, "A quieter kind of productivity")
        XCTAssertTrue(note.waitForExistence(within: 5))
        note.press(forDuration: 1)
        app.buttons["Remove star"].tapWhenSettled()
        XCTAssertTrue(poll(within: uiWaitFloor) { note.exists && !note.label.contains("starred") })
        note.press(forDuration: 1)
        app.buttons["Star"].tapWhenSettled()
        XCTAssertTrue(waitFor(note, label: "starred"))
        note.press(forDuration: 1)
        XCTAssertTrue(app.buttons["Remove star"].waitForExistence(within: uiWaitFloor))
        app.buttons["Export"].tapWhenSettled()
        confirmExport(app, choice: format)
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
