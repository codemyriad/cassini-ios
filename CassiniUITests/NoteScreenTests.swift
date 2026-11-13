import XCTest

/// The Note screen end to end on the seeded fixture note "A quieter kind of productivity": three passages of Alex and
/// Sam over 24 s of audio.
final class NoteScreenTests: XCTestCase {
    private static let fixture = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"

    @MainActor private func open(seed: String = "library", _ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", seed, "--open-fixture", Self.fixture] + arguments
        app.launchAndWait()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 15))
        return app
    }

    @MainActor private func header(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "\(name), at")).firstMatch
    }

    @MainActor private func wait(_ predicate: String, _ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        element.wait(until: NSPredicate(format: predicate), within: timeout)
    }

    /// One element per paragraph and one per speaker header, not one per word; the header names the speaker and its
    /// time, and opens Name a speaker.
    @MainActor func testEachTurnIsOneElementWithAHeaderThatNamesTheSpeaker() {
        let app = open()
        let turns = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "turn-"))
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(app.links.count, 0, "no stop per word: the words are not links to VoiceOver")
        XCTAssertEqual(turns.element(boundBy: 0).label,
                       "What if being productive meant paying closer attention, rather than doing more?")
        let alex = header(app, "Alex")
        XCTAssertEqual(alex.label, "Alex, at 0 seconds")
        XCTAssertTrue(header(app, "Sam").exists)
        XCTAssertGreaterThanOrEqual(alex.frame.height, 44 - 0.001, "a 44 pt target, read through a floating-point transform")
        let inlineSpeakers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "headerSpeaker-"))
        XCTAssertEqual(inlineSpeakers.count, 2, "both speakers have individual header actions")
        XCTAssertTrue(app.buttons["headerSpeaker-alex"].isHittable)
        XCTAssertTrue(app.buttons["headerSpeaker-sam"].isHittable)
        alex.tap()
        XCTAssertTrue(app.textFields["speakerNameField"].waitForExistence(within: 5), "the header opens Name a speaker")
    }

    @MainActor func testAnInlineHeaderNameOpensNamingForThatSpeaker() {
        let app = open()
        let sam = app.buttons["headerSpeaker-sam"]
        XCTAssertTrue(sam.waitForExistence(within: 5))
        sam.tap()
        let name = app.textFields["speakerNameField"]
        XCTAssertTrue(name.waitForExistence(within: 5))
        XCTAssertTrue(name.waitForValue("Sam"), "the inline name opens its own speaker")
    }

    @MainActor func testCompactTitleFollowsTheHeaderOutOfAndBackIntoView() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "long", "--open-fixture",
                               "11111111-1111-1111-1111-111111111111"]
        app.launchAndWait()
        let title = app.staticTexts["noteTitle"]
        let compact = app.staticTexts["noteCompactTitle"]
        XCTAssertTrue(title.waitForExistence(within: 15))
        XCTAssertTrue(poll(within: uiWaitFloor) { title.isHittable && !compact.exists },
                      "the full header initially supplies the title")
        XCTAssertTrue(app.scroll(attempts: 8) { compact.exists && compact.isHittable && !title.isHittable })
        XCTAssertEqual(compact.label, "Three hour workshop")
        XCTAssertTrue(app.scroll(up: false, attempts: 8) { title.isHittable && !compact.exists },
                      "returning to the header removes the compact title")
        XCTAssertTrue(app.buttons["headerSpeaker-alex"].isHittable)
        XCTAssertTrue(app.buttons["headerSpeaker-sam"].isHittable)
    }

    /// The title hands off just beyond the navigation bar, rather than a viewport swipe later.
    @MainActor func testCompactTitleAppearsJustPastTheNavigationBarAndHidesTheOriginalFromAccessibility() {
        checkCompactTitleAtNavigationBoundary()
    }

    @MainActor func testIPadCompactTitleAppearsJustPastTheNavigationBarAndHidesTheOriginalFromAccessibility() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the iPad reading column")
        checkCompactTitleAtNavigationBoundary()
    }

    @MainActor private func checkCompactTitleAtNavigationBoundary() {
        let app = openLongMeeting()
        let title = app.staticTexts["noteTitle"]
        let boundary = app.navigationBars.allElementsBoundByIndex.map(\.frame.maxY).max() ?? 0
        let delta = title.frame.maxY - boundary + 8
        XCTAssertGreaterThan(delta, 0)
        let compact = app.staticTexts["noteCompactTitle"]
        // A pan consumes touch-recognition travel (different on iOS 18). Correct only while some
        // title pixels remain below the bar; a covered title without a compact replacement must fail.
        for _ in 0..<4 {
            guard !compact.exists, title.exists else { break }
            let remaining = title.frame.maxY - boundary
            guard remaining > 0 else { break }
            dragReading(app, by: max(24, remaining + 8))
        }
        assertSingleMeetingTitle(app, below: boundary, compact: true)

        for _ in 0..<8 {
            if title.exists, title.isHittable, title.frame.maxY > boundary, !compact.exists { break }
            dragReading(app, by: -max(delta + 24, 48))
        }
        assertSingleMeetingTitle(app, below: boundary, compact: false)
    }

    /// Find changes the scroll inset even without a new gesture; its opaque background must not cover the only title.
    @MainActor func testFindKeepsOneAccessibleTitleAcrossItsInsetAndGentleScrolling() {
        checkFindTitleAcrossInsetsAndScrolling()
    }

    @MainActor func testIPadFindKeepsOneAccessibleTitleAcrossItsInsetAndGentleScrolling() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the iPad reading column")
        checkFindTitleAcrossInsetsAndScrolling()
    }

    @MainActor private func checkFindTitleAcrossInsetsAndScrolling() {
        let app = openLongMeeting()
        let title = app.staticTexts["noteTitle"]
        let navBottom = app.navigationBars.allElementsBoundByIndex.map(\.frame.maxY).max() ?? 0
        let gentleDelta = max(0, title.frame.maxY - navBottom - 16)
        if gentleDelta > 0 { dragReading(app, by: gentleDelta) }
        app.buttons["searchTranscript"].tap()
        let close = app.buttons["Close search"]
        XCTAssertTrue(close.waitForExistence(within: uiWaitFloor))
        let findBottom = close.frame.maxY + 8 // the Find bar's opaque bottom padding
        assertSingleMeetingTitle(app, below: findBottom)

        // If opening Find preserved the header, move only far enough to cover its last eight points.
        let afterOpen = app.staticTexts["noteTitle"]
        let findDelta = afterOpen.exists ? max(24, afterOpen.frame.maxY - findBottom + 8) : 24
        dragReading(app, by: findDelta)
        assertSingleMeetingTitle(app, below: findBottom, compact: true)

        // Focusing Find can move the scroll offset independently of the user's drag. Return until the
        // actual header is exposed, checking before each gesture rather than assuming the inverse distance.
        let estimatedReturn = max(gentleDelta + findDelta + findBottom - navBottom + 32, 48)
        for _ in 0..<8 {
            let returnedTitle = app.staticTexts["noteTitle"]
            if returnedTitle.exists && returnedTitle.isHittable && returnedTitle.frame.maxY > findBottom
                && !app.staticTexts["noteCompactTitle"].exists { break }
            dragReading(app, by: -estimatedReturn)
        }
        assertSingleMeetingTitle(app, below: findBottom, compact: false)
        close.tap()
        XCTAssertTrue(app.textFields["transcriptSearch"].waitForNonExistence(within: uiWaitFloor))
        assertSingleMeetingTitle(app, below: navBottom, compact: false)
    }

    @MainActor private func openLongMeeting() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "long", "--open-fixture",
                               "11111111-1111-1111-1111-111111111111"]
        app.launchAndWait()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: uiWaitFloor))
        return app
    }

    /// Slow, measured drags avoid fling across the obscured-title interval. Completion is the actual scroll-idle event.
    @MainActor private func dragReading(_ app: XCUIApplication, by delta: CGFloat,
                                       file: StaticString = #filePath, line: UInt = #line) {
        let completed = app.staticTexts["uiTestState-readingScrollCompleted"]
        XCTAssertTrue(completed.waitForExistence(within: uiWaitFloor), file: file, line: line)
        let scroll = app.scrollViews["noteReadingScroll"]
        guard scroll.waitForExistence(within: uiWaitFloor) else {
            XCTFail("the reading scroll view must exist", file: file, line: line)
            return
        }
        var remaining = max(24, abs(delta)) * (delta >= 0 ? 1 : -1)
        while abs(remaining) > 0.001 {
            let frame = scroll.frame
            let close = app.buttons["Close search"]
            let navBottom = app.navigationBars.allElementsBoundByIndex.map(\.frame.maxY).max() ?? frame.minY
            let top = max(frame.minY, close.exists ? close.frame.maxY + 8 : navBottom) + 8
            let keyboard = app.keyboards.firstMatch
            let player = app.descendants(matching: .any).matching(identifier: "playbackBar").firstMatch
            var bottom = frame.maxY
            if keyboard.exists { bottom = min(bottom, keyboard.frame.minY) }
            if player.exists { bottom = min(bottom, player.frame.minY) }
            bottom -= 8
            let capacity = bottom - top
            guard capacity >= 24 else {
                XCTFail("a 24 pt reading drag must fit above the player and keyboard", file: file, line: line)
                return
            }
            // Split a long return into spatially bounded gestures; every endpoint remains in the reading viewport.
            let segments = ceil(abs(remaining) / capacity)
            let distance = remaining / segments
            guard abs(distance) >= 24 else {
                XCTFail("every bounded reading gesture must clear the 24 pt recognition distance", file: file, line: line)
                return
            }
            let centerY = (top + bottom) / 2
            let start = app.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: frame.midX, dy: centerY + distance / 2))
            let end = start.withOffset(CGVector(dx: 0, dy: -distance))
            let before = completed.value as? String
            start.press(forDuration: 0, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0)
            guard poll(within: uiWaitFloor, { (completed.value as? String) != before }) else {
                XCTFail("the measured drag must reach scroll idle", file: file, line: line)
                return
            }
            remaining -= distance
        }
    }

    @MainActor private func assertSingleMeetingTitle(_ app: XCUIApplication, below boundary: CGFloat,
                                                    compact expectedCompact: Bool? = nil,
                                                    file: StaticString = #filePath, line: UInt = #line) {
        let title = app.staticTexts["noteTitle"]
        let compact = app.staticTexts["noteCompactTitle"]
        let accessibleTitles = app.staticTexts.matching(NSPredicate(
            format: "identifier == 'noteTitle' OR identifier == 'noteCompactTitle'"))
        let coherent = poll(within: uiWaitFloor) {
            guard accessibleTitles.count == 1 else { return false }
            if let expectedCompact, compact.exists != expectedCompact { return false }
            if compact.exists {
                return compact.isHittable && !title.exists && compact.label == "Three hour workshop"
            }
            return title.exists && title.isHittable && title.frame.maxY > boundary
        }
        if !coherent {
            let state = app.staticTexts["uiTestState-meetingTitleGeometry"].value as? String ?? "no geometry"
            print("Title visibility: \(state); expected compact=\(String(describing: expectedCompact)); title=\(title.exists ? String(describing: title.frame) : "absent"); compact=\(compact.exists); boundary=\(boundary)")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Title visibility failure"
            shot.lifetime = .keepAlways
            add(shot)
        }
        XCTAssertTrue(coherent, "exactly one accessible meeting title remains visible above the transcript", file: file, line: line)
    }

    // ports: ScreenBehaviourTest#aWordTapAsksToPlayFromThatWord
    @MainActor func testAWordTapPlaysFromThere() {
        let app = open()
        let play = app.buttons["playButton"]
        XCTAssertTrue(play.waitForExistence(within: 5))
        let third = app.descendants(matching: .any)["turn-w2"]
        XCTAssertTrue(third.waitForExistence(within: 5))
        third.tap()
        XCTAssertTrue(wait("label == 'Pause'", play), "a word tap plays")
        let seek = app.staticTexts["uiTestState-playbackSeekTarget"]
        XCTAssertTrue(seek.waitForValue("14.0"), "the player sought to the tapped passage's exact start")
    }

    // ports: ScreenBehaviourTest#aDragDuringPlaybackPausesFollowingAndShowsTheChip
    // ports: ScreenBehaviourTest#aDragWithPlaybackPausedLeavesFollowingOn
    @MainActor func testADragDuringPlaybackShowsFollowPlaybackAndTheChipResumesIt() {
        // This test needs an actual scroll gesture: at the default phone size the short fixture can fit after
        // fonts settle. AX1 makes it overflow on a phone while keeping the second turn reachable; iPad needs AX5.
        let category = UIDevice.current.userInterfaceIdiom == .pad
            ? "UICTContentSizeCategoryAccessibilityXXXL" : "UICTContentSizeCategoryAccessibilityM"
        let app = open(["-UIPreferredContentSizeCategoryName", category])
        let chip = app.buttons["followPlayback"]
        let transcript = app.descendants(matching: .any)["turn-w0"]
        XCTAssertTrue(transcript.waitForExistence(within: 5))
        let scroll = app.staticTexts["uiTestState-readingScrollCompleted"]
        XCTAssertTrue(scroll.waitForExistence(within: 15))
        let before = scroll.value as? String
        let last = app.descendants(matching: .any)["turn-w2"]
        XCTAssertGreaterThan(last.frame.maxY, app.scrollViews.firstMatch.frame.maxY, "the fixture overflows before the drag")
        transcript.swipeUp()
        XCTAssertTrue(poll(within: uiWaitFloor) { (scroll.value as? String) != before }, "the drag finished")
        XCTAssertTrue((scroll.value as? String)?.hasSuffix(":true") == true, "paused: a drag leaves following on")
        XCTAssertFalse(chip.exists, "paused: no Follow playback chip after the drag finishes")
        let play = app.buttons["playButton"]
        play.tap()
        XCTAssertTrue(play.wait(until: NSPredicate(format: "label == 'Pause' AND value == 'Playing'"), within: 3))
        // Playing scrolls the transcript back to the active word; the drag comes once that scroll has stopped.
        let second = app.descendants(matching: .any)["turn-w1"]
        var frame = CGRect.null
        XCTAssertTrue(poll(within: uiWaitFloor) { defer { frame = second.frame }; return second.frame == frame })
        second.swipeDown()
        XCTAssertTrue(chip.waitForExistence(within: 3), "a drag during playback pauses following")
        chip.tap()
        XCTAssertTrue(wait("exists == false", chip), "the chip resumes following")
    }

    /// "1 of N", next and previous wrap, "No matches", Close search.
    @MainActor func testInNoteSearchCountsAndWraps() {
        let app = open()
        app.buttons["searchTranscript"].tap()
        let field = app.textFields["transcriptSearch"]
        XCTAssertTrue(field.waitForExistence(within: 5))
        field.typeText("no")
        let counter = app.staticTexts["searchCounter"]
        XCTAssertTrue(counter.waitForExistence(within: 5))
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
        let app = open(seed: "processing", DeviceUnderTest.workingSpeech)
        app.buttons["Share and more"].tap()
        app.buttons["transcribeAgain"].tapWhenSettled()
        XCTAssertTrue(app.staticTexts["Queued"].waitForExistence(within: 10))
        XCTAssertTrue(app.descendants(matching: .any)["turn-w0"].exists, "the transcript stays under the card")
        header(app, "Alex").tap()
        let alert = app.alerts["Wait until transcription finishes"]
        XCTAssertTrue(alert.waitForExistence(within: 5))
        alert.buttons["Close"].tap()
        XCTAssertFalse(app.textFields["speakerNameField"].exists, "no Name sheet")
        app.buttons["Share and more"].tap()
        let remove = app.collectionViews.buttons["Remove from queue"]
        XCTAssertTrue(remove.waitForExistence(within: 3), "no Transcribe again while queued")
        XCTAssertFalse(app.collectionViews.buttons["transcribeAgain"].exists)
        remove.tap()
        XCTAssertTrue(wait("exists == false", app.staticTexts["Queued"], timeout: 10))
    }

    /// The Queued card counts the queued notes before this one; the running job is not counted.
    @MainActor func testTheQueuedCardCountsTheNotesAheadOfIt() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "processing"] + DeviceUnderTest.workingSpeech
        app.launchAndWait()
        // The seed's job runs first, so the notes queued below wait behind it.
        let running = app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@",
                                                       "Weekly planning call")).firstMatch
        XCTAssertTrue(running.wait(until: NSPredicate(format: "label CONTAINS ', transcribing'"), within: 15))
        let fixture = app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@",
                                                       "A quieter kind of productivity")).firstMatch
        XCTAssertTrue(fixture.waitForExistence(within: 5))
        fixture.tap()
        app.buttons["Share and more"].tap()
        app.buttons["transcribeAgain"].tapWhenSettled()
        let ahead = app.staticTexts["queuedAhead"]
        XCTAssertTrue(ahead.waitForExistence(within: 10))
        XCTAssertEqual(ahead.label, "Starts after the current transcription.")

        app.navigationBars.buttons["Back to all meetings"].tap()
        let walk = app.buttons.matching(NSPredicate(format: "identifier == 'noteRow' AND label BEGINSWITH %@",
                                                    "Thoughts from the morning walk")).firstMatch
        XCTAssertTrue(walk.waitForExistence(within: 5))
        // The capture bar floats over the end of the list: the row is scrolled above it.
        let bar = app.buttons["recordButton"]
        XCTAssertTrue(app.scroll(attempts: 4) { walk.isHittable && walk.frame.maxY < bar.frame.minY }, "the row scrolls into view")
        walk.tap()
        let transcribe = app.buttons["Transcribe"].firstMatch
        XCTAssertTrue(transcribe.waitForExistence(within: 5))
        transcribe.tap()
        XCTAssertTrue(ahead.wait(until: NSPredicate(format: "label == '1 ahead of this note.'"), within: 10))
    }

    /// The back button reads "Back to all meetings" to VoiceOver.
    @MainActor func testTheBackButtonSaysBackToAllMeetings() {
        let app = open()
        let back = app.navigationBars.buttons["Back to all meetings"]
        XCTAssertTrue(back.waitForExistence(within: 5))
        back.tap()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 5))
    }

    // ports: NoteViewModelTest#searchFromTheLibraryIsPrefilledAndStepsThroughMatches
    /// A note opened from a Library search opens with its search filled in, scrolled to the first match, here the
    /// last of 60 paragraphs.
    @MainActor func testANoteOpenedFromALibrarySearchScrollsToTheFirstMatch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "long"]
        app.launchAndWait()
        let search = app.textFields["librarySearch"]
        XCTAssertTrue(search.waitForExistence(within: 15))
        search.tap()
        search.typeText("lighthouse")
        // The search answers a moment after the last keystroke; the workshop was on the screen before it did.
        XCTAssertTrue(app.staticTexts["Silent memo"].waitForNonExistence(within: 5), "the search has answered")
        let row = app.staticTexts["Three hour workshop"]
        XCTAssertTrue(row.waitForExistence(within: 5))
        row.tap()
        let counter = app.staticTexts["searchCounter"]
        XCTAssertTrue(counter.waitForExistence(within: 10))
        XCTAssertEqual(counter.label, "1 of 1")
        XCTAssertEqual(app.textFields["transcriptSearch"].value as? String, "lighthouse")
        let match = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "We end the day at the lighthouse."))
            .firstMatch
        XCTAssertTrue(match.waitForExistence(within: 5))
        XCTAssertTrue(wait("hittable == true", match), "the match is on screen")
    }

    // ports: ScreenBehaviourTest#aDocumentWithNoWordsSaysSo
    @MainActor func testANoteTranscribedToNoWordsSaysSo() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "long", "--open-fixture",
                               "22222222-2222-2222-2222-222222222222"]
        app.launchAndWait()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 15))
        XCTAssertTrue(app.descendants(matching: .any)["noSpeech"].waitForExistence(within: 5))
    }

    // ports: NoteOverlaysBehaviourTest#renameConfirmsTheNewTitle
    /// The title can be renamed while the transcript is read-only.
    @MainActor func testAQueuedNoteCanStillBeRenamed() {
        let app = open(seed: "processing", DeviceUnderTest.workingSpeech)
        app.buttons["Share and more"].tap()
        app.buttons["transcribeAgain"].tapWhenSettled()
        XCTAssertTrue(app.staticTexts["Queued"].waitForExistence(within: 10))
        app.buttons["Share and more"].tap()
        app.collectionViews.buttons["Rename"].tapWhenSettled()
        let field = app.textFields["renameField"]
        XCTAssertTrue(field.waitForExistence(within: 5))
        field.tap()
        field.clearAndType("Supplier call")
        app.buttons["Save"].tap()
        XCTAssertTrue(wait("label == 'Supplier call'", app.staticTexts["noteTitle"]))
    }

    // ports: ModelDownloadFlowTest (Cancel in the processing card's download banner)
    /// The job's model download shows its part in the card, and Cancel stops the job: the note is audio only again.
    /// Without Apple speech the downloaded speech model is Parakeet's (`DeviceUnderTest.downloadedSpeech`).
    @MainActor func testCancelInTheCardsDownloadStopsTheJob() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "processing", "--model-downloading",
                               "--open-fixture", "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"] + DeviceUnderTest.downloadedSpeech
        app.launchAndWait()
        let banner = app.descendants(matching: .any)["banner.DL_DOWNLOADING"]
        XCTAssertTrue(banner.waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts["Downloading speech recognition — 46%"].exists)
        banner.buttons["Cancel"].tap()
        XCTAssertTrue(banner.waitForNonExistence(within: 10))
        XCTAssertTrue(app.buttons["Transcribe"].waitForExistence(within: 10), "the note is audio only again")
    }

    // ports: ScreenBehaviourTest#newDraftTextKeepsTheProgressCardInView
    /// New draft text scrolls the end of the draft into view below the fixed card; a scroll up stops that, and a
    /// scroll back to the end starts it again.
    @MainActor func testTheDraftFollowsItsEndBelowTheFixedCard() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "processing", "--draft-growing",
                               "--open-fixture", "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"] + DeviceUnderTest.workingSpeech
        app.launchAndWait()
        app.appendDraft(sentences: 24)
        // The draft's header, its tag and its paragraphs all carry the section's identifier; the last one ends it.
        let parts = app.descendants(matching: .any).matching(identifier: "draftTranscript")
        XCTAssertTrue(parts.firstMatch.waitForExistence(within: 15))
        var draft: XCUIElement { parts.element(boundBy: parts.count - 1) }
        XCTAssertTrue(poll(within: 15) { app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Sentence 24 ")).firstMatch.exists },
                      "the requested draft arrived; parts: \(parts.allElementsBoundByIndex.map { $0.label })")
        let window = app.windows.firstMatch.frame
        let stop = app.buttons["Stop and keep progress"]
        // The draft outgrows the screen; its end stays in view and so does the card.
        XCTAssertTrue(poll(within: 30) { draft.frame.height > window.height / 2 && draft.frame.maxY <= window.maxY + 1 },
                      "the end of the draft follows the new text")
        XCTAssertTrue(stop.isHittable, "the card stays fixed above the draft")

        draft.swipeDown()
        XCTAssertTrue(poll(within: 15) { draft.frame.maxY > window.maxY + 100 })
        let follow = app.staticTexts["uiTestState-draftFollow"]
        XCTAssertTrue(follow.waitForValue("scrolling=false,following=false"),
                      "the user's scroll ended with automatic following paused")
        let endBeforeAppend = draft.frame.maxY
        app.appendDraft(sentences: 2)
        XCTAssertTrue(poll(within: 15) { app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Sentence 26 ")).firstMatch.exists },
                      "new text arrived after the drag; parts: \(parts.allElementsBoundByIndex.map { $0.label })")
        XCTAssertTrue(poll(within: 15) { draft.frame.maxY > endBeforeAppend + 1 },
                      "the rendered draft grew below its previous end")
        XCTAssertGreaterThan(draft.frame.maxY, window.maxY + 100, "after a scroll up, new text does not scroll")
        XCTAssertTrue(stop.isHittable)
    }

    /// The note screen's Rename is the Library's dialog: Save waits for a change, and a blank title says why.
    @MainActor func testRenameFollowsTheLibrarysRule() {
        let app = open()
        app.buttons["Share and more"].tap()
        app.collectionViews.buttons["Rename"].tapWhenSettled()
        let field = app.textFields["renameField"]
        XCTAssertTrue(field.waitForExistence(within: 5))
        XCTAssertFalse(app.buttons["Save"].isEnabled, "an unchanged title is not saved")
        field.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        field.clearAndType(" ")
        XCTAssertTrue(app.staticTexts["Enter a title."].waitForExistence(within: 3))
        XCTAssertFalse(app.buttons["Save"].isEnabled)
    }

    // ports: SheetBehaviourTest#aPlainNoteDisablesTextExportAndHasNoDocumentInfo
    @MainActor func testAPlainNotesMenuHasNoDocumentInfoAndCannotExportText() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed-test-data", "--open-fixture",
                               "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"] + DeviceUnderTest.workingSpeech
        app.launchAndWait()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 15))
        app.buttons["Share and more"].tap()
        let share = app.collectionViews.buttons["Share original audio"]
        XCTAssertTrue(app.collectionViews.buttons["Transcribe"].waitForExistence(within: 3))
        XCTAssertFalse(app.collectionViews.buttons["Document info"].exists)
        let export = app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Export transcript")).firstMatch
        XCTAssertEqual(export.label, "Export transcript, Available after transcription")
        XCTAssertTrue(share.exists && share.isEnabled, "the audio can be shared")
        // iOS can open a disabled submenu. Gate on its rendered rows before inspecting their enabled state.
        export.tapWhenSettled()
        let text = app.collectionViews.buttons["Transcript as text"]
        XCTAssertTrue(text.waitForExistence(within: 15), "the export submenu finished opening")
        XCTAssertFalse(text.isEnabled, "no transcript to export")
    }

    @MainActor func testDocumentInfoShowsTheNotesFacts() {
        let app = open()
        app.buttons["Share and more"].tap()
        app.buttons["Document info"].tapWhenSettled()
        XCTAssertTrue(app.navigationBars["Document info"].waitForExistence(within: 5))
        XCTAssertTrue(app.staticTexts["00:24"].exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(wait("exists == false", app.navigationBars["Document info"]))
    }

    /// The plain note's banner says what it is and offers Transcribe; the subtitle shows outside reading mode.
    @MainActor func testAPlainNoteShowsItsBannerAndSubtitle() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed-test-data", "--open-fixture",
                               "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"] + DeviceUnderTest.workingSpeech
        app.launchAndWait()
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts["Plain audio"].exists)
        XCTAssertTrue(app.staticTexts["No transcript yet."].exists)
        let subtitle = app.staticTexts["noteSubtitle"].label
        XCTAssertTrue(subtitle.hasPrefix("Yesterday, 9:41") && subtitle.hasSuffix("AM · 00:24"), subtitle)
        XCTAssertTrue(app.buttons["Transcribe"].exists)
        XCTAssertFalse(app.buttons["searchTranscript"].exists, "no search without a transcript")
        XCTAssertFalse(app.buttons["Dismiss"].exists, "Plain audio has no close, as in Android's catalogue")
    }
}

private extension XCUIElement {
    func clearAndType(_ text: String) {
        if let current = value as? String, !current.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        typeText(text)
    }
}
