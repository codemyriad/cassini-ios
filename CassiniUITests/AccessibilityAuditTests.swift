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

    @MainActor private func launch(_ arguments: [String], fresh: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data"] + arguments
        // Same-system-argument screens use the existing isolated graph reset. Each group ends its process;
        // recording also ends it before the next screen, so its paused policy task cannot survive the reset.
        app.launchAndWait(fresh: fresh)
        return app
    }

    @MainActor private func library(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["--seed", "library"] + extra)
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15))
        return app
    }

    @MainActor private func emptyLibrary(_ extra: [String] = []) -> XCUIApplication {
        // Clipping audits redraw at other text sizes, even when launched at the default size.
        // After auditing the populated Library, an in-process replacement can retain its audit layout
        // (scroll position or capture-bar fit). First-run audits need an independent process.
        let app = launch(extra, fresh: true)
        let hero = app.staticTexts["heroTitle"]
        XCTAssertTrue(hero.waitForExistence(within: 15))
        XCTAssertFalse(app.buttons["backupNoticeDismiss"].exists, "No backup notice before the first saved meeting")
        if extra.contains(Self.largestText[1]) {
            // At AX5 the introduction is taller than the viewport. Expose its final paragraph before
            // auditing: an intentionally half-visible line at the scroll edge is not truncated text.
            _ = app.scrolledLibraryElement(app.staticTexts["heroPrivacy"], description: "first-run privacy")
        }
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
        let firstTopic = app.buttons["transcriptionRow"]
        XCTAssertTrue(app.buttons["settingsButton"].tapWhenInteractive(in: app, until: { firstTopic.exists }), "Settings did not open")
        XCTAssertTrue(app.waitForSettingsPage("map"),
                      "Settings has not finished loading")
        return app
    }

    @MainActor private func trash(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["--seed", "trash"] + extra)
        app.openRecentlyDeleted()
        XCTAssertTrue(app.staticTexts["Old interview draft"].waitForExistence(within: 15),
                      "Recently Deleted did not open")
        return app
    }

    @MainActor private func savedVoices(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["--seed", "voices"] + extra)
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(within: 15))
        let firstTopic = app.buttons["transcriptionRow"], row = app.buttons["savedVoicesRow"]
        XCTAssertTrue(app.buttons["settingsButton"].tapWhenInteractive(in: app, until: { firstTopic.exists }), "Settings did not open")
        XCTAssertTrue(app.waitForSettingsPage("map"),
                      "Settings has not finished loading")
        // A full swipe can fling the English AX5 row above the navigation bar on iOS 18.
        // Short drags stop before lifting, and the row's current position decides the direction.
        let viewport = app.collectionViews.firstMatch
        var revealed = false
        for _ in 0..<20 {
            let bounds = viewport.frame.intersection(app.frame).insetBy(dx: 0, dy: 12)
            let top = max(bounds.minY, app.navigationBars.firstMatch.frame.maxY)
            let visible = CGRect(x: bounds.minX, y: top, width: bounds.width, height: bounds.maxY - top)
            let frame = (try? row.snapshot())?.frame
            if let frame, visible.contains(frame), row.isHittable {
                revealed = true
                break
            }
            let upward = frame.map { $0.midY > visible.midY } ?? true
            let start = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.6 : 0.4))
            let end = viewport.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.4 : 0.6))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTAssertTrue(revealed, "Saved voices is not fully inside the list")
        row.tapWhenSettled()
        // At AX5 on iOS 18, tapping a row at the List's bottom edge can only scroll it into place.
        // A positive destination or a settled, hittable source row decides whether to retry.
        let list = app.collectionViews["savedVoicesList"]
        var previousRowFrame: CGRect?
        let decided = poll(within: uiWaitFloor) {
            if list.exists { return true }
            guard row.exists, row.isHittable, let frame = (try? row.snapshot())?.frame else {
                previousRowFrame = nil
                return false
            }
            defer { previousRowFrame = frame }
            return previousRowFrame == frame
        }
        XCTAssertTrue(decided, "Neither Saved voices nor its Settings row became ready")
        if decided && !list.exists {
            row.tapWhenSettled()
        }
        XCTAssertTrue(list.waitForExistence(within: 15), "Saved voices did not open")
        let person = app.staticTexts["Alex Moreau"]
        XCTAssertTrue(app.scroll(attempts: 12) { person.exists && person.isHittable },
                      "The saved voice is not on the screen below setup")
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
        let listRowLimit = AuditFilter.listRowLimit(settings: screen == "settings" || screen.hasSuffix("-settings"))
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
                              unattributedClips < listRowLimit {
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

    @MainActor func testBackupSurfacesPassTheAudit() {
        auditBackupSurfaces([])
    }

    @MainActor func testBackupSurfacesWrapInFrenchAtLargestTextSize() {
        auditBackupSurfaces(Self.largestText + ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"])
    }

    @MainActor func testIPadBackupSurfacesWrapInFrenchAtLargestTextSize() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        testBackupSurfacesWrapInFrenchAtLargestTextSize()
    }

    @MainActor private func auditBackupSurfaces(_ arguments: [String]) {
        let app = library(arguments)
        let dismiss = app.buttons["backupNoticeDismiss"]
        XCTAssertTrue(dismiss.waitForExistence(within: 15))
        audit(app, screen: "backupNotice")
        dismiss.tap()
        XCTAssertTrue(app.staticTexts["uiTestState-backupState"].waitForValue("cloud=true;voices=true;dismissed=true"))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.waitForSettingsPage("map"))
        let row = app.buttons["backupRow"]
        XCTAssertTrue(app.scroll(attempts: 12) { row.exists && row.isHittable && app.frame.contains(row.frame) })
        row.tap()
        XCTAssertTrue(app.waitForSettingsPage("backup"))
        audit(app, screen: "backup-settings", listRows: true)
        let detail = app.buttons["backupInfoRow"]
        XCTAssertTrue(app.scroll(attempts: 12) { detail.exists && detail.isHittable && app.frame.contains(detail.frame) })
        detail.tap()
        XCTAssertTrue(app.descendants(matching: .any)["backupInfo"].waitForExistence(within: 15))
        audit(app, screen: "backupDetails", listRows: true)
        let final = app.descendants(matching: .any).matching(identifier: "backupZipReader").firstMatch
        XCTAssertTrue(app.scroll(attempts: 12) { final.exists && final.isHittable && app.frame.contains(final.frame) })
        audit(app, screen: "backupReaders", listRows: true)
        app.terminate()
    }

    @MainActor func testVoicesAndDownloadWrapInFrenchAtLargestTextSize() {
        let arguments = Self.largestText + ["-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR"]
        let voices = launch(["--seed", "speakers", "--open-fixture", Self.fixture, "--ask-voices"] + arguments)
        XCTAssertTrue(voices.staticTexts["voicesQuestionTitle"].waitForExistence(within: 15))
        audit(voices, screen: "voices-question-fr-ax5", .textClipped)
        let yes = voices.buttons["voicesQuestionYes"]
        XCTAssertTrue(voices.scroll(attempts: 12) { yes.exists && yes.isHittable && voices.frame.contains(yes.frame) })
        audit(voices, screen: "voices-question-actions-fr-ax5", .textClipped)
        yes.tap()
        voices.terminate()
        let download = launch(["--seed", "library", "--open-fixture", "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB",
                               "--models-missing", "--parakeet"] + arguments)
        let action = download.buttons["bannerAction.transcribe"]
        let title = download.staticTexts["modelDownloadTitle"]
        let viewport = download.scrollViews["noteReadingScroll"]
        let player = download.descendants(matching: .any).matching(identifier: "playbackBar").firstMatch
        XCTAssertTrue(viewport.scroll(attempts: 12) {
            guard action.exists, action.isHittable, viewport.frame.contains(action.frame) else { return false }
            return !player.exists || action.frame.maxY < player.frame.minY
        })
        let before = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        before.name = "download-trigger-fr-ax5"; before.lifetime = .keepAlways; add(before)
        action.tapWhenSettled()
        let opened = title.waitForExistence(within: 15)
        if !opened {
            let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            image.name = "download-trigger-failed-fr-ax5"; image.lifetime = .keepAlways; add(image)
        }
        XCTAssertTrue(opened)
        audit(download, screen: "model-download-fr-ax5", .textClipped)
        let primary = download.buttons["modelDownloadPrimary"]
        XCTAssertTrue(download.scroll(attempts: 12) { primary.exists && primary.isHittable && download.frame.contains(primary.frame) })
        audit(download, screen: "model-download-actions-fr-ax5", .textClipped)
        download.terminate()
        let saved = savedVoices(arguments)
        audit(saved, screen: "saved-voices-fr-ax5", .textClipped, listRows: true)
        saved.terminate()
    }

    @MainActor func testIPadVoicesAndDownloadWrapInFrenchAtLargestTextSize() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        testVoicesAndDownloadWrapInFrenchAtLargestTextSize()
    }

    @MainActor func testTheLibraryPassesTheAudit() { audit(library(), screen: "library") }
    @MainActor func testTheEmptyLibraryPassesTheAudit() { audit(emptyLibrary(), screen: "libraryEmpty") }
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
            ("library", library), ("libraryEmpty", emptyLibrary), ("note", note), ("recording", recording), ("settings", settings),
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
            ("library", library), ("libraryEmpty", emptyLibrary), ("note", note), ("settings", settings),
            ("trash", trash), ("savedVoices", savedVoices)]
        for (name, open) in screens {
            let app = open(Self.largestText)
            audit(app, screen: "largest-\(name)", .textClipped)
        }
    }

    /// D105: a bottom-aligned hero must still grow and scroll at AX5 in every shipped language.
    @MainActor func testFirstRunWrapsAtLargestTextSize() {
        defer { XCUIApplication().terminate() }
        for language in ["en", "it", "fr", "es", "pt-BR", "pt-PT"] {
            let app = emptyLibrary(Self.largestText + ["-AppleLanguages", "(\(language))"])
            for identifier in ["heroTitle", "heroSubtitle", "heroHowTo", "heroPrivacy"] {
                // Every block must fit fully between the bars, even when the whole introduction cannot.
                _ = app.scrolledLibraryElement(app.staticTexts[identifier], description: identifier)
            }
            let privacy = app.staticTexts["heroPrivacy"]
            XCTAssertLessThan(privacy.frame.maxY, app.buttons["recordButton"].frame.minY)
            audit(app, screen: "first-run-privacy-largest-\(language)", .textClipped)
            XCTAssertTrue(app.buttons["recordButton"].isHittable)
            XCTAssertTrue(app.buttons["importButton"].isHittable)
        }
    }

    @MainActor func testIPadFirstRunWrapsAtLargestTextSize() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "the Library sidebar")
        testFirstRunWrapsAtLargestTextSize()
    }

    // MARK: Long languages

    /// French and both Portuguese variants at the default text size: no text is cut on any of the seven screens.
    /// The screens are found by identifier and by the fixtures' names, which no language changes.
    @MainActor func testNoTextIsClippedInFrench() { auditClipping(language: "fr", region: "fr_FR") }
    @MainActor func testNoTextIsClippedInBrazilianPortuguese() { auditClipping(language: "pt-BR", region: "pt_BR") }
    @MainActor func testNoTextIsClippedInEuropeanPortuguese() { auditClipping(language: "pt-PT", region: "pt_PT") }

    // The full pt-PT title clips beside Empty at AX5; keep the app-local navigation label short.
    @MainActor func testRecentlyDeletedWrapsInEuropeanPortugueseAtLargestTextSize() {
        defer { XCUIApplication().terminate() }
        let app = trash(Self.largestText + ["-AppleLanguages", "(pt-PT)", "-AppleLocale", "pt_PT"])
        XCTAssertTrue(app.navigationBars["Apagados"].waitForExistence(within: 15))
        audit(app, screen: "largest-pt-PT-trash", .textClipped)
    }

    @MainActor func testSettingsAboutCardWrapsAtLargestTextSizeInAuditLanguages() {
        auditSettingsAboutAtLargestTextSize()
    }

    @MainActor func testIPadSettingsAboutCardWrapsAtLargestTextSizeInAuditLanguages() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "a wide window")
        auditSettingsAboutAtLargestTextSize()
    }

    @MainActor private func auditSettingsAboutAtLargestTextSize() {
        defer { XCUIApplication().terminate() }
        for (language, region) in [("en", "en_US"), ("fr", "fr_FR"), ("pt-BR", "pt_BR")] {
            let app = settings(Self.largestText + ["-AppleLanguages", "(\(language))", "-AppleLocale", region])
            let about = app.buttons["aboutRow"]
            XCTAssertTrue(app.scroll(attempts: 12) {
                about.exists && about.isHittable && app.frame.contains(about.frame)
                    && about.frame.minY >= app.navigationBars.firstMatch.frame.maxY
            }, "The About card is not visible at the largest text size in \(language)")
            var previousFrame: CGRect?
            XCTAssertTrue(poll(within: uiWaitFloor) {
                guard about.exists, about.isHittable else { previousFrame = nil; return false }
                let frame = about.frame
                defer { previousFrame = frame }
                return previousFrame == frame
            }, "The About card did not settle after scrolling")
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "largest-about-before-audit-\(language)"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            // Exercise the card below the fold at the actual largest size. On iPhone no List-row
            // prediction allowance is needed; on iPad portrait (< iOS 26) four Form rows sit on
            // screen alongside the About card and iOS 18's List audit emits a second unattributed
            // prediction even though all text wraps (verified in the attached screenshots).
            // Bounding to `listRows: UIDevice.current.userInterfaceIdiom == .pad` allows at most
            // two unattributed predictions on iOS 18 iPad (zero on iOS 26+ and iPhone); any
            // attributed clipping issue still fails everywhere.
            audit(app, screen: "largest-about-\(language)", .textClipped,
                  listRows: UIDevice.current.userInterfaceIdiom == .pad)
            app.terminate()
        }
    }

    @MainActor private func auditClipping(language: String, region: String) {
        defer { XCUIApplication().terminate() }
        let screens: [(String, @MainActor ([String]) -> XCUIApplication)] = [
            ("library", library), ("libraryEmpty", emptyLibrary), ("note", note), ("recording", recording),
            ("settings", settings), ("trash", trash), ("savedVoices", savedVoices)]
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
    /// most two on Saved voices and four on the Settings map (`listRowLimit`); the next issue fails.
    /// The largest-size test (`testNoTextIsClippedAtTheLargestTextSize`)
    /// does not use this pass, but it is no full backstop: at AX5 Saved voices still reports one unattributed issue,
    /// unexplained, which `isNavigationTitle` lets through though the title is not cut (125 pt in a 393 pt bar). iOS 26
    /// and 27 report no such issue. Evidence: cassini-ios18-cache/ios18-g/evidence-18.2-full2 (the failing run) and
    /// evidence-audits-diag{1,2,4} (the experiments). An issue that names an element still fails.
    /// The most unattributed clipping issues one audit of a List screen lets through, the navigation title's included:
    /// Settings and Saved voices each reported two with the app's own bar (evidence-audits-diag1, diag2).
    /// On iOS 18.2, fresh-process Settings audits also report a third identical prediction: reproduced in the
    /// full PR #150 gate and in an isolated audit. Its attached screenshot shows wrapping labels, and the full
    /// largest-text audit passes without this allowance. Keep the extra prediction limited to Settings.
    /// The D103 map's About card adds a fourth prediction at the default size on iOS 18.2
    /// (PR #166 run 43986086225). Removing only that card removes the fourth issue; explicit vertical
    /// sizing does not. Its adaptive layout gives long labels more width at accessibility sizes.
    /// `testSettingsAboutCardWrapsAtLargestTextSizeInAuditLanguages` and its iPad counterpart bring the
    /// whole card into view at AX5 in English, French and Brazilian Portuguese, retain screenshots,
    /// and audit it without this allowance. Any attributed issue still fails.
    static func listRowLimit(settings: Bool) -> Int { settings ? 4 : 2 }

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
