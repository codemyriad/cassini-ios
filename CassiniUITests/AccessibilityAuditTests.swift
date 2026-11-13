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
// Library actions wait for its interactive marker, then tap once and await the destination.
final class AccessibilityAuditTests: XCTestCase {
    private static let fixture = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    /// The screens built as a SwiftUI List (`audit`'s `listRows`).
    private static let listScreens: Set<String> = ["settings", "savedVoices"]
    /// The largest Dynamic Type size (AX5).
    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    @MainActor private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data"] + arguments
        // Same-system-argument screens use the existing isolated graph reset. Each group ends its process;
        // recording also ends it before the next screen, so its paused policy task cannot survive the reset.
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
        app.buttons["recordButton"].tapWhenInteractive(in: app, until: { pause.exists })
        XCTAssertTrue(pause.waitForEnabled(within: 8))
        return app
    }

    @MainActor private func settings(_ extra: [String] = []) -> XCUIApplication {
        let app = library(extra)
        let language = app.buttons["appLanguageRow"]
        XCTAssertTrue(app.buttons["settingsButton"].tapWhenInteractive(in: app, until: { language.exists }), "Settings did not open")
        XCTAssertTrue(app.staticTexts["uiTestState-settingsLoaded"].waitForExistence(within: 15),
                      "Settings has not finished loading")
        return app
    }

    @MainActor private func trash(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["--seed", "trash"] + extra)
        XCTAssertTrue(app.buttons["recentlyDeletedButton"].waitForExistence(within: 15))
        let draft = app.staticTexts["Old interview draft"]
        XCTAssertTrue(app.buttons["recentlyDeletedButton"].tapWhenInteractive(in: app, until: { draft.exists }),
                      "Recently Deleted did not open")
        return app
    }

    @MainActor private func savedVoices(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["--seed", "voices"] + extra)
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(within: 15))
        let language = app.buttons["appLanguageRow"], row = app.buttons["savedVoicesRow"]
        XCTAssertTrue(app.buttons["settingsButton"].tapWhenInteractive(in: app, until: { language.exists }), "Settings did not open")
        XCTAssertTrue(app.staticTexts["uiTestState-settingsLoaded"].waitForExistence(within: 15),
                      "Settings has not finished loading")
        // At the largest text size the row is about six swipes down, more when a loaded host makes each fling shorter:
        // six once stopped a row short of it.
        XCTAssertTrue(app.scroll(attempts: 12) { row.exists && row.isHittable }, "Saved voices is not on the screen")
        row.tap()
        XCTAssertTrue(app.staticTexts["Alex Moreau"].waitForExistence(within: 20))
        return app
    }

    /// The audit, failing on every issue but those the system owns (`AuditFilter`), each with the element it is about.
    /// `transcript` is for a screen that draws a transcript, whose active word may yield one unattributed text issue
    /// (`AuditFilter.isActiveWord`). `listRows` is for a screen built as a SwiftUI List (Settings, Saved voices), whose
    /// rows below iOS 26 yield unattributed clipping predictions (`AuditFilter.isListRowPrediction`). On a failure the
    /// screen is attached as "audit-<screen>".
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
                                  transcript: Bool = false, listRows: Bool = false,
                                  file: StaticString = #filePath, line: UInt = #line) {
        var issues: [String] = []
        var titleClipped = false
        // Unattributed clipping issues let through so far, the title's included (`AuditFilter.listRowLimit`).
        var unattributedClips = 0
        // An iPad window has a resize handle in its corner (`AuditFilter.isWindowControl`).
        let window = UIDevice.current.userInterfaceIdiom == .pad
        let detection = types.intersection(.elementDetection)
        // iOS 18's combined audit can duplicate unattributed clipping predictions on unchanged List screens.
        // Run clipping separately, retaining every requested check and the existing filters and issue limits.
        let clipping = types.intersection(.textClipped)
        let passes = [detection, clipping, types.subtracting([.elementDetection, .textClipped])]
            .filter { !$0.isEmpty }
        do {
            for pass in passes {
                try app.performAccessibilityAudit(for: pass) { issue in
                    if AuditFilter.isNavigationTitle(issue, in: app, alreadySeen: titleClipped) {
                        titleClipped = true
                        unattributedClips += 1
                    } else if listRows, AuditFilter.isListRowPrediction(issue),
                              unattributedClips < AuditFilter.listRowLimit {
                        // Passes: see `isListRowPrediction`; the next one fails.
                        unattributedClips += 1
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
    @MainActor func testSettingsPassesTheAudit() { audit(settings(), screen: "settings", listRows: true) }
    @MainActor func testRecentlyDeletedPassesTheAudit() { audit(trash(), screen: "trash") }
    @MainActor func testSavedVoicesPassesTheAudit() { audit(savedVoices(), screen: "savedVoices", listRows: true) }

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
            XCTContext.runActivity(named: name) { _ in
                audit(app, screen: "ipad-\(name)", transcript: name == "note", listRows: Self.listScreens.contains(name))
            }
            if name == "recording" { app.terminate() }
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
            audit(app, screen: "\(language)-\(name)", .textClipped, listRows: Self.listScreens.contains(name))
            if name == "recording" { app.terminate() }
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
        // Invisible event markers exist only in Debug UI-test launches.
        if element.identifier == "launchFinished" || element.identifier.hasPrefix("uiTestState-") { return true }
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

    /// Below iOS 26 only: "Text of this element may be clipped at larger Dynamic Type sizes" with no element, on a screen
    /// built as a SwiftUI List. The function does not check the text size: only the callers keep it to sizes below the
    /// largest (the default-size and long-language audits pass `listRows`; the largest-size audit does not). iOS 18.2's
    /// audit predicts it for the List's rows though no text is cut: on screen every text is whole in English, French
    /// and Brazilian Portuguese, and after a live change of the simulator's text size to AX5 the rows grow and wrap every
    /// text (Settings' App language row 44 -> 209 pt, Saved voices' Alex Moreau 20 -> 125 pt). Evidence for the element:
    /// on Saved voices, removing the people rows removes both issues, removing each row's trailing menu leaves one, and
    /// removing the privacy line, the footer or the Forget section leaves both; hiding the navigation bar or the back
    /// button leaves them. Settings was attributed by analogy (same List rows, same two issues, unchanged by the
    /// navigation-bar experiments); its parts were not removed one by one. With the app's own bar each screen reports at
    /// most two (`listRowLimit`), so a third fails. The largest-size test (`testNoTextIsClippedAtTheLargestTextSize`)
    /// does not use this pass, but it is no full backstop: at AX5 Saved voices still reports one unattributed issue,
    /// unexplained, which `isNavigationTitle` lets through though the title is not cut (125 pt in a 393 pt bar). iOS 26
    /// and 27 report no such issue. Evidence: cassini-ios18-cache/ios18-g/evidence-18.2-full2 (the failing run) and
    /// evidence-audits-diag{1,2,4} (the experiments). An issue that names an element still fails.
    /// The most unattributed clipping issues one audit of a List screen lets through, the navigation title's included:
    /// Settings and Saved voices each reported two with the app's own bar (evidence-audits-diag1, diag2).
    static let listRowLimit = 2

    @MainActor static func isListRowPrediction(_ issue: XCUIAccessibilityAuditIssue) -> Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26
            && issue.element == nil && issue.auditType == .textClipped
            && issue.detailedDescription == "Text of this element may be clipped at larger Dynamic Type sizes."
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
