import XCTest

/// Xcode's accessibility audit on each screen in a seeded state close to its board: Library, Note, Recording,
/// Settings, Recently Deleted and Saved voices; then the same screens at the largest Dynamic Type size, where no text
/// may be clipped. Two checks are left to other tests, because their verdicts on this app's SwiftUI text change from run
/// to run: contrast to `ContrastTests`, which checks every token pair exactly in both appearances (the audit samples
/// rendered pixels, Liquid Glass buttons and anti-aliased text included), and Dynamic Type at the default size, which
/// flags standard text styles such as `.subheadline` (one different text each run) — the largest-size run below shows
/// that text grows without being cut.
// ports: ScreenAccessibilityTest#library
// ports: ScreenAccessibilityTest#noteReading
// ports: ScreenAccessibilityTest#recording
// ports: ScreenAccessibilityTest#settings
// ports: AppAccessibilityTest#theLibraryAndSettingsHaveNoFindings
final class AccessibilityAuditTests: XCTestCase {
    private static let fixture = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    /// The largest Dynamic Type size (AX5).
    private static let largestText = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]

    @MainActor private func launch(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data"] + arguments
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
        app.buttons["recordButton"].tap()
        XCTAssertTrue(app.buttons["Pause recording"].waitForEnabled(within: 8))
        return app
    }

    @MainActor private func settings(_ extra: [String] = []) -> XCUIApplication {
        let app = library(extra)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 5))
        return app
    }

    @MainActor private func trash(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["--seed", "trash"] + extra)
        XCTAssertTrue(app.buttons["Recently Deleted"].waitForExistence(within: 15))
        app.buttons["Recently Deleted"].tap()
        XCTAssertTrue(app.staticTexts["Old interview draft"].waitForExistence(within: 5))
        return app
    }

    @MainActor private func savedVoices(_ extra: [String] = []) -> XCUIApplication {
        let app = launch(["--seed", "voices"] + extra)
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(within: 15))
        app.buttons["Settings"].tap()
        let row = app.buttons["savedVoicesRow"]
        for _ in 0..<6 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.buttons["Options for Alex Moreau"].waitForExistence(within: 5))
        return app
    }

    /// The audit, failing on every issue but those the system owns (`AuditFilter`), each with the element it is about.
    @MainActor private func audit(_ app: XCUIApplication, _ types: XCUIAccessibilityAuditType = .all.subtracting([.contrast, .dynamicType]),
                                  file: StaticString = #filePath, line: UInt = #line) {
        var issues: [String] = []
        do {
            try app.performAccessibilityAudit(for: types) { issue in
                if !AuditFilter.isSystemOwned(issue, in: app) { issues.append(AuditFilter.describe(issue)) }
                return true
            }
        } catch {
            XCTFail("the audit could not run: \(error)", file: file, line: line)
        }
        if !issues.isEmpty {
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "audit-\(name)"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
        XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n"), file: file, line: line)
    }

    @MainActor func testTheLibraryPassesTheAudit() { audit(library()) }
    @MainActor func testTheNoteScreenPassesTheAudit() { audit(note()) }
    @MainActor func testTheRecordingScreenPassesTheAudit() { audit(recording()) }
    @MainActor func testSettingsPassesTheAudit() { audit(settings()) }
    @MainActor func testRecentlyDeletedPassesTheAudit() { audit(trash()) }
    @MainActor func testSavedVoicesPassesTheAudit() { audit(savedVoices()) }

    // MARK: Largest text

    /// At AX5 no text is cut: rows, the player, the cards and the capture bar grow or wrap instead.
    // ports: LargeFontScaleTest#theRowSuffixIsNotCutAtFontScale2 (AX5; every text, through the audit's clipping check)
    @MainActor func testNoTextIsClippedAtTheLargestTextSize() {
        for open in [library, note, settings, trash, savedVoices] as [@MainActor ([String]) -> XCUIApplication] {
            let app = open(Self.largestText)
            audit(app, .textClipped)
            app.terminate()
        }
    }

    // ports: LargeFontScaleTest#theSkipDigitsKeepTheirSizeAtFontScale2 (the player's buttons stay 44 pt or more)
    @MainActor func testThePlayerKeepsItsTargetsAtTheLargestTextSize() {
        let app = note(Self.largestText)
        for label in ["Play", "Back 10 seconds", "Forward 10 seconds"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(within: 5), label)
            XCTAssertGreaterThanOrEqual(button.frame.width, 44, label)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44, label)
        }
    }
}

/// Issues the audit reports that the app cannot or should not change, each for a stated reason.
enum AuditFilter {
    /// The bars that stop growing at AX1 by design and show the Large Content Viewer instead: the player and the
    /// capture bar (five or two buttons in a row that would not fit past it).
    static let cappedBars = ["playbackBar", "captureBar"]

    @MainActor static func isSystemOwned(_ issue: XCUIAccessibilityAuditIssue, in app: XCUIApplication) -> Bool {
        // Text clipping reported without an element is the system's own (the navigation bar title at AX5, which iOS
        // shrinks to fit beside the bar buttons); every text of the app's views comes with its element.
        guard let element = issue.element else { return issue.auditType == .textClipped }
        // The status bar and the keyboard belong to the system.
        if [.statusBar, .key, .keyboard].contains(element.elementType) { return true }
        // The UI-test launch marker, an invisible 1 pt text that only DEBUG builds draw.
        if element.identifier == "launchFinished" { return true }
        // A Library row's preview is an excerpt of two lines by design (Android maxLines = 2).
        if issue.auditType == .textClipped, element.identifier == "rowPreview" { return true }
        if issue.auditType == .dynamicType {
            // Navigation bars keep their size at every text size; their items show the Large Content Viewer.
            let bars = app.navigationBars.allElementsBoundByIndex.map(\.frame)
            if bars.contains(where: { $0.contains(element.frame) }) { return true }
            let capped = cappedBars.map { app.descendants(matching: .any)[$0] }.filter(\.exists).map(\.frame)
            if capped.contains(where: { $0.contains(element.frame) }) { return true }
        }
        return false
    }

    @MainActor static func describe(_ issue: XCUIAccessibilityAuditIssue) -> String {
        let what = issue.element.map { element in
            "\(element.elementType.rawValue) “\(element.label)” id=\(element.identifier) \(element.frame)"
        } ?? "no element"
        return "\(issue.compactDescription): \(what) — \(issue.detailedDescription)"
    }
}
