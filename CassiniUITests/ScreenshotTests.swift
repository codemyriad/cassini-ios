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

    /// The fixture note with its word times (the reading seed), paused 10 seconds in: a word of Sam's passage is the
    /// active one.
    @MainActor func test02ReadAndListen() throws {
        let app = try launchPhone(["--seed", "reading", "--open-fixture", Self.fixture])
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 10))
        skipTenSeconds(app)
        capture("02-read-and-listen")
    }

    @MainActor func test03Transcribing() throws {
        let app = try launchPhone(["--seed", "processing", "--open-fixture", Self.processing])
        let headline = app.descendants(matching: .any)["progressHeadline"]
        XCTAssertTrue(headline.wait(until: NSPredicate(format: "label CONTAINS %@", "%"), within: 15))
        XCTAssertTrue(element(app, containing: "agenda").waitForExistence(within: 10), "the draft so far shows")
        // The draft follows its end as it arrives; back at its start, its header shows under the card.
        let header = app.staticTexts.matching(NSPredicate(format: "label ==[c] %@", "Draft transcript")).firstMatch
        let parts = app.descendants(matching: .any).matching(identifier: "draftTranscript")
        let draft = parts.element(boundBy: parts.count - 1)
        XCTAssertTrue(draft.scroll(up: false, attempts: 3) { header.exists && header.isHittable })
        capture("03-transcribing")
    }

    /// Name a speaker on the speakers seed: the second speaker is still "Speaker 2", and the saved voice "Sam Rivera"
    /// may be them.
    @MainActor func test04NameASpeaker() throws {
        let app = try launchPhone(["--seed", "speakers", "--open-fixture", Self.fixture])
        let header = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Speaker 2, at")).firstMatch
        XCTAssertTrue(header.waitForExistence(within: 10))
        header.tap()
        let field = app.textFields["speakerNameField"]
        XCTAssertTrue(field.waitForExistence(within: 5))
        // Picking the likely saved voice fills in the name.
        let samRivera = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Sam Rivera")).firstMatch
        XCTAssertTrue(samRivera.waitForExistence(within: 5))
        samRivera.tap()
        XCTAssertTrue(field.wait(until: NSPredicate(format: "value == %@", "Sam Rivera"), within: 5))
        dismissKeyboard(app)
        capture("04-name-a-speaker")
    }

    @MainActor func test05Settings() throws {
        let app = try launchPhone(["--seed", "library"])
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 5))
        capture("05-settings")
    }

    // MARK: - iPhone, iOS screens

    /// The fake microphone of the recording seed, held at 24:07 after 7 s of speech-like levels.
    @MainActor func test06Recording() throws {
        let app = try launchPhone(["--seed", "recording", "--capture-held"])
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["Pause recording"].waitForEnabled(within: 8))
        XCTAssertTrue(element(app, containing: "24 minutes, 7 seconds").waitForExistence(within: 10), "the capture holds")
        capture("06-recording")
    }

    @MainActor func test07Search() throws {
        let app = try launchPhone(["--seed", "search"])
        let search = app.textFields["librarySearch"]
        search.tap()
        search.typeText("Thursday")
        XCTAssertTrue(row(app, "Garden plans for the spring").waitForExistence(within: 5))
        XCTAssertTrue(row(app, "Notes from the design review").waitForNonExistence(within: 5))
        dismissKeyboard(app)
        capture("07-search")
    }

    @MainActor func test08RecentlyDeleted() throws {
        let app = try launchPhone(["--seed", "trash"])
        app.buttons["Recently Deleted"].tap()
        XCTAssertTrue(app.staticTexts["Old interview draft"].waitForExistence(within: 5))
        capture("08-recently-deleted")
    }

    @MainActor func test09SavedVoices() throws {
        let app = try launchPhone(["--seed", "voices"])
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 5))
        let savedVoices = app.buttons["savedVoicesRow"]
        app.scroll(attempts: 6) { savedVoices.exists && savedVoices.isHittable }
        savedVoices.tap()
        XCTAssertTrue(element(app, containing: "Giulia Conti").waitForExistence(within: 5))
        capture("09-saved-voices")
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
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15)
                      || app.staticTexts["noteTitle"].waitForExistence(within: 5))
        return app
    }

    @MainActor private func launchPhone(_ arguments: [String]) throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "an iPhone screenshot")
        XCUIDevice.shared.orientation = .portrait
        return launch(arguments)
    }

    /// The fixture note beside the Library, whose reading seed fills the sidebar, paused 10 seconds in.
    @MainActor private func launchPad(orientation: UIDeviceOrientation) throws -> XCUIApplication {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "an iPad screenshot")
        XCUIDevice.shared.orientation = orientation
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        let app = launch(["--seed", "reading", "--open-fixture", Self.fixture])
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 10))
        XCTAssertTrue(row(app, "Garden plans for the spring").waitForExistence(within: 5))
        skipTenSeconds(app)
        return app
    }

    @MainActor private func skipTenSeconds(_ app: XCUIApplication) {
        let forward = app.buttons["Forward 10 seconds"]
        XCTAssertTrue(forward.waitForExistence(within: 5))
        forward.tap()
        let position = app.descendants(matching: .any)["playbackPosition"]
        XCTAssertTrue(position.wait(until: NSPredicate(format: "value BEGINSWITH %@", "00:10"), within: 5))
    }

    @MainActor private func row(_ app: XCUIApplication, _ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", title)).firstMatch
    }

    @MainActor private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    @MainActor private func dismissKeyboard(_ app: XCUIApplication) {
        guard app.keyboards.firstMatch.exists else { return }
        print("keyboard keys: \(app.keyboards.buttons.allElementsBoundByIndex.map(\.label))")
        app.keyboards.buttons.matching(NSPredicate(format: "label IN[c] %@", ["done", "return", "search"])).firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(within: 5), "the keyboard went away")
    }

    /// The whole screen, status bar included, under the name `scripts/screenshots.sh` saves it as.
    @MainActor private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
