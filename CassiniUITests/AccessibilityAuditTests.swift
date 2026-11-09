import XCTest

/// Xcode's accessibility audit on each screen in a seeded state close to its board: Library, Note, Recording,
/// Settings, Recently Deleted and Saved voices; then the same screens at the largest Dynamic Type size, where no text
/// may be clipped. Two checks are left to other tests, because their verdicts on this app's SwiftUI text change from run
/// to run: contrast to `ContrastTests`, which checks every token pair exactly in both appearances (the audit samples
/// rendered pixels, Liquid Glass buttons and anti-aliased text included), and Dynamic Type at the default size, which
/// flags standard text styles such as `.subheadline` (one different text each run) — the largest-size run below shows
/// that text grows without being cut. The six screens are audited on the iPad too, where the Library is the split
/// view's sidebar (`testIPadScreensPassTheAudit`, which `scripts/test.sh` runs on its iPad clone).
// ports: ScreenAccessibilityTest#library
// ports: ScreenAccessibilityTest#noteReading
// ports: ScreenAccessibilityTest#recording
// ports: ScreenAccessibilityTest#settings
// ports: AppAccessibilityTest#theLibraryAndSettingsHaveNoFindings
// Its waits allow 20 s: upper bounds for the iPad clone on a busy machine, where a screen can take that long to open.
// The taps that open a screen are tried again when it does not open (`tap(until:)`): the first after a launch can
// be dropped there.
final class AccessibilityAuditTests: XCTestCase {
    private static let fixture = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    /// The largest Dynamic Type size (AX5).
    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    @MainActor private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data"] + arguments
        // Within a screen group, launchAndWait resets the graph, library and preferences in-process. A changed
        // language or text size still starts a fresh process; each group terminates its final process afterwards.
        app.launchAndWait()
        return app
    }

    @MainActor private func library(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["--seed", "library"] + extra)
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15))
        return app
    }

    @MainActor private func note(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["--seed", "library", "--open-fixture", Self.fixture] + extra)
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 15))
        return app
    }

    @MainActor private func recording(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["--seed", "recording"] + extra)
        XCTAssertTrue(app.buttons["recordButton"].waitForExistence(within: 15))
        let pause = app.buttons["pauseResumeRecording"]
        app.buttons["recordButton"].tap(until: { pause.exists })
        XCTAssertTrue(pause.waitForEnabled(within: 8))
        return app
    }

    @MainActor private func settings(_ extra: [String] = []) -> XCUIApplication {
        let app = library(extra)
        let language = app.buttons["appLanguageRow"]
        XCTAssertTrue(app.buttons["settingsButton"].tap(until: { language.exists }), "Settings did not open")
        return app
    }

    @MainActor private func trash(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["--seed", "trash"] + extra)
        XCTAssertTrue(app.buttons["recentlyDeletedButton"].waitForExistence(within: 15))
        let draft = app.staticTexts["Old interview draft"]
        XCTAssertTrue(app.buttons["recentlyDeletedButton"].tap(until: { draft.exists }),
                      "Recently Deleted did not open")
        return app
    }

    @MainActor private func savedVoices(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["--seed", "voices"] + extra)
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(within: 15))
        let language = app.buttons["appLanguageRow"], row = app.buttons["savedVoicesRow"]
        XCTAssertTrue(app.buttons["settingsButton"].tap(until: { language.exists }), "Settings did not open")
        // At the largest text size the row is about six swipes down, more when a loaded host makes each fling shorter:
        // six once stopped a row short of it.
        XCTAssertTrue(app.scroll(attempts: 12) { row.exists && row.isHittable }, "Saved voices is not on the screen")
        row.tap()
        XCTAssertTrue(app.staticTexts["Alex Moreau"].waitForExistence(within: 20))
        return app
    }

    /// The audit, failing on every issue but those the system owns (`AuditFilter`), each with the element it is about.
    /// `transcript` is for a screen that draws a transcript, whose active word may yield one unattributed text issue
    /// (`AuditFilter.isActiveWord`). On a failure the screen is attached as "audit-<screen>".
    ///
    /// The element detection runs in an audit of its own, before the other checks. The clipping check renders the
    /// screen again at other text sizes, and an element detection in the same audit can read the pixels while the app
    /// is still drawing its way back to the screen's own size: text the new layout has not settled, with no element
    /// yet, reported as "Potentially inaccessible text" without an element. With animations slowed 30 times
    /// (`-UIAnimationDragCoefficient 30`) Settings, Saved voices and Recently Deleted reported it in most audits that
    /// ran both checks together, and never in 24 audits of the element detection alone, before or after the others; a
    /// busy machine (the full run's iPad beside three iPhones) slows the redraw the same way, now and then.
    @MainActor private func audit(_ app: XCUIApplication, screen: String,
                                  _ types: XCUIAccessibilityAuditType = .all.subtracting([.contrast, .dynamicType]),
                                  transcript: Bool = false,
                                  file: StaticString = #filePath, line: UInt = #line) {
        var issues: [String] = []
        var titleClipped = false
        // An iPad window has a resize handle in its corner (`AuditFilter.isWindowControl`).
        let window = UIDevice.current.userInterfaceIdiom == .pad
        let detection = types.intersection(.elementDetection)
        let passes = [detection, types.subtracting(.elementDetection)].filter { !$0.isEmpty }
        do {
            for pass in passes {
                #if targetEnvironment(simulator)
                // The failed iPad audit screenshot shows this first-boot system banner covering the
                // Recording header. Its interference is observed; attributing the unowned OCR text
                // finding specifically to the banner remains an inference. Wait for this exact setup
                // message before each pass; keep every audit and allow all other notifications to fail.
                let setupBanner = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                    .staticTexts["Ready for Apple Intelligence"]
                if setupBanner.exists {
                    XCTAssertTrue(setupBanner.waitForNonExistence(within: 30),
                                  "SpringBoard's first-boot setup banner still covers the audit screen",
                                  file: file, line: line)
                }
                #endif
                try app.performAccessibilityAudit(for: pass) { issue in
                    if AuditFilter.isNavigationTitle(issue, in: app, alreadySeen: titleClipped) {
                        titleClipped = true
                    } else if transcript, AuditFilter.isActiveWord(issue) {
                        // Passes: see `isActiveWord`.
                    } else if window, AuditFilter.isWindowControl(issue) {
                        // Passes: see `isWindowControl`.
                    } else if !AuditFilter.isSystemOwned(issue) {
                        issues.append(AuditFilter.describe(issue))
                    }
                    return true
                }
            }
        } catch {
            XCTFail("the audit could not run: \(error)", file: file, line: line)
        }
        if !issues.isEmpty {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "audit-\(screen)"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
        XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n"), file: file, line: line)
    }

    @MainActor func testTheLibraryPassesTheAudit() { audit(library(), screen: "library") }
    @MainActor func testTheNoteScreenPassesTheAudit() { audit(note(), screen: "note", transcript: true) }
    @MainActor func testTheRecordingScreenPassesTheAudit() { audit(recording(), screen: "recording") }
    @MainActor func testSettingsPassesTheAudit() { audit(settings(), screen: "settings") }
    @MainActor func testRecentlyDeletedPassesTheAudit() { audit(trash(), screen: "trash") }
    @MainActor func testSavedVoicesPassesTheAudit() { audit(savedVoices(), screen: "savedVoices") }

    // MARK: iPad

    /// The same screens on the iPad, beside the Library's sidebar (an iOS-only layout).
    @MainActor func testIPadScreensPassTheAudit() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the split view")
        defer { XCUIApplication().terminate() }
        // Six screens in one test: about 160 s on a calm host, over the 300 s default when it runs 2-4x slower.
        executionTimeAllowance = 600
        let screens: [(String, @MainActor ([String]) -> XCUIApplication)] = [
            ("library", library), ("note", note), ("recording", recording), ("settings", settings),
            ("trash", trash), ("savedVoices", savedVoices)]
        for (name, open) in screens {
            let app = open([])
            XCTContext.runActivity(named: name) { _ in audit(app, screen: "ipad-\(name)", transcript: name == "note") }
        }
    }

    // MARK: Largest text

    /// At AX5 no text is cut: rows, the player, the cards and the capture bar grow or wrap instead.
    // ports: LargeFontScaleTest#theRowSuffixIsNotCutAtFontScale2 (AX5; every text, through the audit's clipping check)
    @MainActor func testNoTextIsClippedAtTheLargestTextSize() {
        defer { XCUIApplication().terminate() }
        let screens: [(String, @MainActor ([String]) -> XCUIApplication)] = [
            ("library", library), ("note", note), ("settings", settings), ("trash", trash), ("savedVoices", savedVoices)]
        for (name, open) in screens {
            let app = open(Self.largestText)
            audit(app, screen: "largest-\(name)", .textClipped)
        }
    }

    // MARK: Long languages

    /// French and Brazilian Portuguese, the longest of the app's languages (D50), at the default text size: no text is
    /// cut on any of the six screens. The screens are found by identifier and by the fixtures' names, which no language
    /// changes.
    @MainActor func testNoTextIsClippedInFrench() { auditClipping(language: "fr", region: "fr_FR") }
    @MainActor func testNoTextIsClippedInBrazilianPortuguese() { auditClipping(language: "pt-BR", region: "pt_BR") }

    @MainActor private func auditClipping(language: String, region: String) {
        defer { XCUIApplication().terminate() }
        let screens: [(String, @MainActor ([String]) -> XCUIApplication)] = [
            ("library", library), ("note", note), ("recording", recording), ("settings", settings), ("trash", trash),
            ("savedVoices", savedVoices)]
        for (name, open) in screens {
            let app = open(["-AppleLanguages", "(\(language))", "-AppleLocale", region])
            if name == "library" {
                XCTAssertNotEqual(app.buttons["settingsButton"].label, "Settings", "the app is not in \(language)")
            }
            audit(app, screen: "\(language)-\(name)", .textClipped)
        }
    }

    // ports: LargeFontScaleTest#theSkipDigitsKeepTheirSizeAtFontScale2 (the player's buttons stay 44 pt or more)
    @MainActor func testThePlayerKeepsItsTargetsAtTheLargestTextSize() {
        let app = note(Self.largestText)
        for label in ["Play", "Back 10 seconds", "Forward 10 seconds"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(within: 20), label)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, label)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, label)
        }
    }
}

/// Issues the audit reports that the app cannot or should not change, each for a stated reason.
enum AuditFilter {
    @MainActor static func isSystemOwned(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        guard let element = issue.element else { return false }
        // The status bar and the keyboard belong to the system.
        if [.statusBar, .key, .keyboard].contains(element.elementType) { return true }
        // The UI-test launch marker, an invisible 1 pt text that only DEBUG builds draw.
        if element.identifier == "launchFinished" { return true }
        // A Library row's title and preview stop at two lines by design (Android maxLines = 2); in the iPad's sidebar a
        // long title reaches them.
        if issue.auditType == .textClipped, ["rowPreview", "rowTitle"].contains(element.identifier) { return true }
        return false
    }

    /// The one clipping a screen's navigation bar title may report at AX5: iOS shrinks the title to fit beside the bar
    /// buttons, and the audit reports that without an element. Every text of the app's own views comes with its
    /// element, so only the first such issue, on a screen that shows a navigation bar, passes; a second is the app's.
    @MainActor static func isNavigationTitle(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication,
                                             alreadySeen: Bool) -> Bool {
        issue.element == nil && issue.auditType == .textClipped && !alreadySeen && app.navigationBars.firstMatch.exists
    }

    /// "Potentially inaccessible text" with no element, on a screen that draws a transcript. The element detection reads
    /// text off the rendered pixels; the active word is drawn inverted inside its paragraph (the whole passage, for the
    /// fixture's passages without word timing), and the detection can take it for text of its own while the paragraph,
    /// one element that VoiceOver reads whole, holds it. Its verdict on that word changes from run to run, as the
    /// contrast check's does. An issue that names an element still fails.
    @MainActor static func isActiveWord(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        issue.element == nil && issue.auditType == .elementDetection
    }

    /// A hit region too small with no element, on an iPad: the window's resize handle in its corner, which iPadOS
    /// draws over every app window and the app does not own. Every control of the app's own views comes with its element.
    @MainActor static func isWindowControl(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        issue.element == nil && issue.auditType == .hitRegion
    }

    @MainActor static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
        let what = issue.element.map { element in
            "\(element.elementType.rawValue) “\(element.label)” id=\(element.identifier) \(element.frame)"
        } ?? "no element"
        return "\(issue.compactDescription): \(what) — \(issue.detailedDescription)"
    }
}
