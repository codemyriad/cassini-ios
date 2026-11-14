import XCTest

/// The README's screenshots, taken by `scripts/screenshots.sh` on an iPhone and an iPad in light and dark. Every shot
/// starts from a named seed (`--seed`), under the UI-test launch's fixed clock (Thursday 8 October 2026, 09:41) and its
/// language and region (en_US, or `CASSINI_SCREENSHOT_LANGUAGE` / `CASSINI_SCREENSHOT_REGION`), and is attached under
/// the file name the script saves it as. The script sets the appearance and the status bar; the tests skip in an
/// ordinary run (`CASSINI_SCREENSHOTS` unset), so `scripts/test.sh` never changes the device under the other tests.
/// The order of Android's README comes first (library, read and listen, transcribing, name a speaker, settings), then
/// the iOS screens.
final class ScreenshotTests: XCTestCase {
    private static let fixture = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    private static let processing = "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"

    private var environment: [String: String] { ProcessInfo.processInfo.environment }

    override func setUpWithError() throws {
        try XCTSkipUnless(environment["CASSINI_SCREENSHOTS"] == "1", "run by scripts/screenshots.sh")
        continueAfterFailure = false
    }

    // MARK: - iPhone, in the order of Android's README

    @MainActor func test01Library() throws {
        let app = try launchPhone(["--seed", "search"])
        XCTAssertTrue(row(app, "Notes from the design review").waitForExistence(within: 5))
        capture("01-library")
    }

    /// The fixture note with its word times (the reading seed), paused at the start with its first word active.
    @MainActor func test02ReadAndListen() throws {
        let app = try launchPhone(["--seed", "reading", "--open-fixture", Self.fixture])
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 10))
        waitForInitialPosition(app)
        capture("02-read-and-listen")
    }

    @MainActor func test03Transcribing() throws {
        let app = try launchPhone(["--seed", "processing", "--open-fixture", Self.processing])
        // Reports advance the injected uptime, so the compact strip's ETA follows the synthetic pace.
        let details = app.buttons["transcribingDetails"]
        XCTAssertTrue(details.wait(until: NSPredicate(format: "label CONTAINS %@", "min"), within: 15), details.label)
        XCTAssertTrue(element(app, containing: "agenda").waitForExistence(within: 10), "the draft so far shows")
        // The draft follows its end as it arrives; back at its start, its header shows under the status strip.
        let parts = app.descendants(matching: .any).matching(identifier: "draftTranscript")
        let header = parts.firstMatch, draft = app.scrollViews.firstMatch
        XCTAssertTrue(draft.scroll(up: false, attempts: 3) {
            guard header.exists else { return false }
            let frame = header.frame
            // This is a static heading, with no activation point while offscreen. Check that it is fully
            // visible inside the draft's viewport below the pinned card before taking the screenshot.
            let viewport = draft.frame.intersection(app.windows.firstMatch.frame)
            return !frame.isEmpty && !frame.isInfinite && viewport.contains(frame)
        })
        capture("03-transcribing")
    }

    /// Name a speaker on the speakers seed: the second speaker is still "Speaker 2", and the saved voice "Sam Rivera"
    /// may be them.
    @MainActor func test04NameASpeaker() throws {
        let app = try launchPhone(["--seed", "speakers", "--open-fixture", Self.fixture])
        // The second passage is Speaker 2's.
        let header = app.buttons["speakerHeader-w1"]
        XCTAssertTrue(header.waitForExistence(within: 10))
        header.tap()
        let field = app.textFields["speakerNameField"]
        XCTAssertTrue(field.waitForExistence(within: 5))
        // Picking the likely saved voice fills in the name.
        let samRivera = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sam Rivera")).firstMatch
        XCTAssertTrue(samRivera.waitForExistence(within: 5))
        samRivera.tap()
        XCTAssertTrue(field.wait(until: NSPredicate(format: "value == %@", "Sam Rivera"), within: 5))
        capture("04-name-a-speaker")
    }

    @MainActor func test05Settings() throws {
        let app = try launchPhone(["--seed", "library"])
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(within: 5), "Settings shows")
        XCTAssertTrue(app.staticTexts["uiTestState-settingsLoaded"].waitForExistence(within: 15),
                      "Settings finishes loading model and language availability before capture")
        capture("05-settings")
    }

    // MARK: - iPhone, iOS screens

    /// The fake microphone of the recording seed, held at 24:07 after 7 s of speech-like levels.
    @MainActor func test06Recording() throws {
        let app = try launchPhone(["--seed", "recording", "--capture-held"])
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["pauseResumeRecording"].waitForEnabled(within: 8))
        // The timer's value is spoken in the app's language: "24 minutes, 7 seconds".
        let held = NSPredicate(format: "value BEGINSWITH '24 ' AND value CONTAINS ' 7 '")
        XCTAssertTrue(app.staticTexts["recordingTimer"].wait(until: held, within: 10), "the capture holds")
        capture("06-recording")
    }

    @MainActor func test07Search() throws {
        let app = try launchPhone(["--seed", "search"])
        let search = app.textFields["librarySearch"]
        search.tap()
        // Search on the keyboard (a new line in the wrapping field) ends the search and hides the keyboard.
        search.typeText("Thursday\n")
        XCTAssertTrue(row(app, "Garden plans for the spring").waitForExistence(within: 5))
        XCTAssertTrue(row(app, "Notes from the design review").waitForNonExistence(within: 5))
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(within: 5))
        capture("07-search")
    }

    @MainActor func test08RecentlyDeleted() throws {
        let app = try launchPhone(["--seed", "trash"])
        app.buttons["recentlyDeletedButton"].tap()
        XCTAssertTrue(app.staticTexts["Old interview draft"].waitForExistence(within: 5))
        capture("08-recently-deleted")
    }

    @MainActor func test09SavedVoices() throws {
        let app = try launchPhone(["--seed", "voices"])
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.switches.firstMatch.waitForExistence(within: 5), "Settings shows")
        let savedVoices = app.buttons["savedVoicesRow"]
        app.scroll(attempts: 6) { savedVoices.exists && savedVoices.isHittable }
        savedVoices.tap()
        XCTAssertTrue(element(app, containing: "Giulia Conti").waitForExistence(within: 5))
        capture("09-saved-voices")
    }

    @MainActor func test10NoteExport() throws {
        let app = try launchPhone(["--seed", "reading", "--open-fixture", Self.fixture])
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 10))
        app.buttons["Share and more"].tap()
        app.collectionViews.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Export transcript'")).firstMatch.tapWhenSettled()
        captureExportMenu("10-note-export", app)
    }

    @MainActor func test11LibraryExport() throws {
        let app = try launchPhone(["--seed", "reading"])
        let note = row(app, "A quieter kind of productivity")
        XCTAssertTrue(note.waitForExistence(within: 5))
        note.press(forDuration: 1)
        app.buttons["Export"].tapWhenSettled()
        captureExportMenu("11-library-export", app)
    }

    /// Opens the real destructive confirmation without accepting it or deleting anything.
    @MainActor func test12DeleteDialog() throws {
        let app = try launchPhone(["--seed", "trash"])
        app.buttons["recentlyDeletedButton"].tap()
        XCTAssertTrue(app.staticTexts["Old interview draft"].waitForExistence(within: 5))
        app.buttons["Empty"].tapWhenSettled()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(within: 5))
        XCTAssertTrue(alert.buttons["Delete"].exists)
        capture("12-delete-dialog")
        alert.buttons["Cancel"].tapWhenSettled()
        XCTAssertTrue(app.staticTexts["Old interview draft"].waitForExistence(within: 5))
    }

    @MainActor func test13ErrorLine() throws {
        let app = try launchPhone(["--seed", "brandSpeakers", "--open-fixture", "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF"])
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 10))
        let failure = app.descendants(matching: .any)["banner.TX_FAILED"]
        XCTAssertTrue(failure.waitForExistence(within: 10), "the real failed-note banner shows its error line")
        capture("13-error-line")
    }

    @MainActor func test14SuccessBadge() throws {
        let app = try launchPhone(["--seed", "brandSpeakers"])
        XCTAssertTrue(row(app, "Community garden planning").waitForExistence(within: 5))
        XCTAssertTrue(element(app, containing: "Transcribed").waitForExistence(within: 5))
        capture("14-success-badge")
    }

    @MainActor func test15SevenSpeakerMeeting() throws {
        let app = try launchPhone(["--seed", "brandSpeakers", "--open-fixture", Self.fixture])
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 10))
        waitForInitialPosition(app)
        XCTAssertTrue(app.buttons["headerSpeaker-brand-0"].waitForExistence(within: 5))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "headerSpeaker-")).count, 7)
        capture("15-seven-speaker-meeting")
    }

    /// The actual Speakers sheet shows an unnamed first speaker reserving slot zero, plus six named speakers.
    @MainActor func test16SevenSpeakerColours() throws {
        let app = try launchPhone(["--seed", "brandSpeakers", "--open-fixture", Self.fixture])
        app.openNoteSpeakers()
        XCTAssertTrue(app.buttons["speaker-brand-0"].waitForExistence(within: 5))
        let last = app.buttons["speaker-brand-6"]
        XCTAssertTrue(app.scroll(attempts: 6) { last.exists && last.isHittable })
        XCTAssertTrue(app.buttons["speaker-brand-0"].isHittable, "all seven speaker rows fit together")
        capture("16-seven-speaker-colours")
    }

    @MainActor private func captureExportMenu(_ name: String, _ app: XCUIApplication) {
        let item = app.buttons["Transcript as text"]
        var last: CGRect?
        XCTAssertTrue(poll(within: 15) {
            guard item.exists && item.isHittable else { return false }
            let frame = item.frame
            defer { last = frame }
            return frame == last
        }, "the export submenu has settled")
        capture(name)
    }

    @MainActor func test17StatusBadges() throws {
        let app = try launchPhone(["--badge-gallery"])
        XCTAssertTrue(app.descendants(matching: .any)["badge-gallery-8"].waitForExistence(within: 15))
        capture("17-status-badges")
    }

    @MainActor func test18MeetingFind() throws {
        let app = try launchPhone(["--seed", "reading", "--open-fixture", Self.fixture])
        waitForInitialPosition(app)
        app.buttons["searchTranscript"].tap()
        let field = app.textFields["transcriptSearch"]
        XCTAssertTrue(field.waitForExistence(within: 5))
        field.typeText("attention")
        XCTAssertTrue(app.staticTexts["searchCounter"].wait(until: NSPredicate(format: "label == '1 of 1'"), within: 5))
        capture("18-meeting-find")
    }

    @MainActor func test19MeetingScrolled() throws {
        let app = try launchPhone(["--seed", "long", "--open-fixture", "11111111-1111-1111-1111-111111111111"])
        waitForInitialPosition(app)
        let compact = app.staticTexts["noteCompactTitle"]
        XCTAssertTrue(app.scroll(attempts: 8) {
            compact.exists && compact.isHittable && !app.staticTexts["noteTitle"].isHittable
        })
        XCTAssertEqual(compact.label, "Three hour workshop")
        capture("19-meeting-scrolled")
    }

    // MARK: - iPad

    @MainActor func testSplitViewLandscape() throws {
        let app = try launchPad(orientation: .landscapeLeft)
        capture("01-split-landscape")
        XCTAssertTrue(app.textFields["librarySearch"].isHittable, "the library shows beside the note")
    }

    @MainActor func testSplitViewPortrait() throws {
        let app = try launchPad(orientation: .portrait)
        capture("02-split-portrait")
        XCTAssertTrue(app.staticTexts["noteTitle"].isHittable)
    }

    // MARK: - Helpers

    /// The launch arguments of the language and region the screenshots are taken in.
    private var localeArguments: [String] {
        let language = environment["CASSINI_SCREENSHOT_LANGUAGE"] ?? "en"
        let region = environment["CASSINI_SCREENSHOT_REGION"] ?? "en_US"
        return ["-AppleLanguages", "(\(language))", "-AppleLocale", region]
    }

    @MainActor private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data"] + arguments + localeArguments
        app.launchAndWait()
        // One wait for either screen: waiting for the Library first cost a fixture launch its whole limit.
        let search = app.textFields["librarySearch"], title = app.staticTexts["noteTitle"]
        XCTAssertTrue(poll(within: max(15, uiWaitFloor)) {
            search.exists || title.exists || app.descendants(matching: .any)["badgeGallery"].exists
        })
        return app
    }

    @MainActor private func launchPhone(_ arguments: [String]) throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "an iPhone screenshot")
        XCUIDevice.shared.orientation = .portrait
        return launch(arguments)
    }

    /// The fixture note beside the Library, whose reading seed fills the sidebar, paused at its start.
    @MainActor private func launchPad(orientation: UIDeviceOrientation) throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "an iPad screenshot")
        XCUIDevice.shared.orientation = orientation
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = launch(["--seed", "reading", "--open-fixture", Self.fixture])
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 10))
        XCTAssertTrue(row(app, "Garden plans for the spring").waitForExistence(within: 5))
        waitForInitialPosition(app)
        return app
    }

    @MainActor private func waitForInitialPosition(_ app: XCUIApplication) {
        // Capturing just after tapping skipForward caught its transient pressed tint. Use an untouched player.
        let position = app.descendants(matching: .any)["playbackPosition"]
        XCTAssertTrue(position.wait(until: NSPredicate(format: "value BEGINSWITH %@", "00:00"), within: 5))
    }

    @MainActor private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    @MainActor private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    /// The whole screen, status bar included, under the name `scripts/screenshots.sh` saves it as. A landscape
    /// screenshot comes as portrait pixels with an orientation tag, which is drawn into the pixels here so the saved
    /// PNG is landscape whatever reads or strips its metadata.
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(image: upright(XCUIScreen.main.screenshot().image))
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func upright(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
    }
}
