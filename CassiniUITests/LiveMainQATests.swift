import Foundation
import XCTest

/// Opt-in, stateful QA of live production adapters on an otherwise fresh, owned simulator.
/// Run phases separately against the same installation; no fake environment, model overrides or seeds.
final class LiveMainQATests: XCTestCase {
    private struct QAError: Error { let message: String }

    @MainActor func testProductionJourney() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let phase = environment["CASSINI_QA_PHASE"], !phase.isEmpty else {
            throw XCTSkip("Live production QA requires an explicit CASSINI_QA_PHASE")
        }
        let phases = ["inspect", "download", "resume", "speakers", "import", "render", "export"]
        try require(phases.contains(phase), "Unknown QA phase: \(phase)")
        let output = environment["CASSINI_QA_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        // launchAndWait requires a marker published only by --ui-testing and would select the wrong environment.
        app.launch()
        defer { capture(app, name: "\(phase)-end", output: output) }
        try wait("Live Cassini did not show its library or restored note", timeout: 45) {
            app.buttons["importButton"].exists || app.buttons["settingsButton"].exists || app.buttons["noteActions"].exists
        }
        capture(app, name: "\(phase)-initial", output: output)
        switch phase {
        case "inspect":
            try openSettings(app)
            capture(app, name: "inspect-settings", output: output)
        case "download", "resume":
            try downloadParakeet(app, output: output)
        case "speakers":
            try openSettings(app)
            try downloadModel(app, name: "Telling speakers apart", output: output)
            let identify = app.switches["Identify speakers after transcription"]
            try require(app.scroll(until: { identify.isHittable }), "Speaker-identification toggle unavailable")
            if identify.value as? String == "0" { identify.tap() }
            try wait("Speaker identification did not enable", timeout: 15) { identify.value as? String == "1" }
        case "import":
            let url = try fixture(environment, key: "CASSINI_QA_AUDIO")
            app.open(url)
            try wait("Imported audio did not open a note", timeout: 120) { app.staticTexts["noteTitle"].exists }
            capture(app, name: "import-note", output: output)
            // Auto-transcribe is the production default. If Settings disabled it, invoke the actual menu action.
            if !self.hasTurns(app), !self.hasElement(app, "progressHeadline"), !self.hasElement(app, "draftTranscript") {
                app.buttons["noteActions"].tap()
                let transcribe = app.buttons.matching(NSPredicate(format: "label == %@", "Transcribe")).firstMatch
                if transcribe.waitForExistence(timeout: 5), transcribe.isEnabled { transcribe.tapWhenSettled() }
            }
            let consent = app.buttons["Download and transcribe"]
            if consent.exists, consent.isEnabled { consent.tap() }
            try wait("Live transcription did not produce sealed turns", timeout: 1800) {
                self.hasTurns(app) && !self.hasElement(app, "draftTranscript") && !self.hasElement(app, "progressHeadline")
            }
            try require(!app.staticTexts["noSpeech"].exists, "English speech fixture was classified as no speech")
        case "render":
            if let path = environment["CASSINI_QA_D84"], !path.isEmpty {
                app.open(try fixture(environment, key: "CASSINI_QA_D84"))
            }
            try wait("No rendered transcript paragraphs", timeout: 120) { self.hasTurns(app) }
            capture(app, name: "render-transcript", output: output)
        case "export":
            try wait("Export requires an open transcript note", timeout: 30) { app.buttons["noteActions"].exists && self.hasTurns(app) }
            app.buttons["noteActions"].tap()
            let submenu = app.buttons["Export transcript"]
            try require(submenu.waitForExistence(timeout: 15), "Export transcript menu missing")
            submenu.tapWhenSettled()
            let text = app.buttons["Transcript as text"]
            try require(text.waitForExistence(timeout: 15) && text.isEnabled, "Text export unavailable")
            text.tapWhenSettled()
            try wait("Export share sheet did not appear", timeout: 90) {
                app.buttons["Copy"].exists || app.buttons["Save to Files"].exists || app.otherElements["ActivityListView"].exists
            }
            // Keep the real share sheet open: root reads this simulator's tmp/Exports before dismissal deletes it.
            capture(app, name: "export-share-sheet", output: output)
        default: break
        }
    }

    @MainActor private func openSettings(_ app: XCUIApplication) throws {
        if app.navigationBars["Settings"].exists { return }
        let settings = app.buttons["settingsButton"]
        if !settings.isHittable, app.navigationBars.buttons.element(boundBy: 0).exists {
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        try require(settings.waitForExistence(timeout: 15) && settings.isHittable, "Library Settings control unavailable")
        settings.tap()
        try wait("Settings did not open", timeout: 20) {
            app.navigationBars["Settings"].exists || app.buttons["appLanguageRow"].exists
        }
    }

    @MainActor private func downloadParakeet(_ app: XCUIApplication, output: URL?) throws {
        try openSettings(app)
        try downloadModel(app, name: "Parakeet Ultra", output: output, suggestionID: "downloadParakeetSuggestion")
        capture(app, name: "download-ready", output: output)
        let choice = app.buttons["speechModelChoice"]
        if choice.exists, choice.isEnabled {
            choice.tap()
            let option = app.buttons["Parakeet Ultra"]
            try require(option.waitForExistence(timeout: 15) && option.isEnabled, "Verified Parakeet choice missing")
            option.tapWhenSettled()
        }
    }

    @MainActor private func downloadModel(_ app: XCUIApplication, name: String, output: URL?, suggestionID: String? = nil) throws {
        let ready = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", name, "Ready")).firstMatch
        let model = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        let suggestion = suggestionID.map { app.buttons[$0] }
        let reachable = app.scroll {
            ready.exists || model.isHittable || suggestion?.isHittable == true
        }
        try require(reachable, "No reachable \(name) model row or download control; inspect capabilities")
        if ready.exists { return }
        if let suggestion, suggestion.isHittable { suggestion.tap() } else { model.tap() }
        let download = app.buttons["Download"]
        try require(download.waitForExistence(timeout: 20) && download.isEnabled, "Standalone \(name) download consent unavailable")
        capture(app, name: "download-\(name)-consent", output: output)
        download.tap()
        try wait("\(name) did not finish downloading/checking", timeout: 1800) {
            self.answerNotificationPrompt(app)
            return ready.exists || app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND label CONTAINS %@", name, "Download failed")).firstMatch.exists
        }
        try require(ready.exists, "\(name) download failed; inspect captured UI and network diagnostics")
        capture(app, name: "download-\(name)-ready", output: output)
    }

    @MainActor private func hasElement(_ app: XCUIApplication, _ identifier: String) -> Bool {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists
    }

    @MainActor private func answerNotificationPrompt(_ app: XCUIApplication) {
        for owner in [app, XCUIApplication(bundleIdentifier: "com.apple.springboard")] {
            let alert = owner.alerts.firstMatch
            guard alert.exists else { continue }
            let text = alert.label + " " + alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
            if text.contains("Cassini"), text.localizedCaseInsensitiveContains("notifications"), alert.buttons["Allow"].exists {
                alert.buttons["Allow"].tap()
                return
            }
        }
    }

    @MainActor private func hasTurns(_ app: XCUIApplication) -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "turn-")).firstMatch.exists
    }

    private func fixture(_ environment: [String: String], key: String) throws -> URL {
        guard let path = environment[key], !path.isEmpty, FileManager.default.fileExists(atPath: path) else {
            XCTFail("Missing accessible QA fixture: \(key)")
            throw QAError(message: "Missing QA fixture: \(key)")
        }
        return URL(fileURLWithPath: path)
    }

    @MainActor private func wait(_ message: String, timeout: TimeInterval, condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        try require(XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed, message)
    }

    private func require(_ condition: Bool, _ message: String) throws {
        XCTAssertTrue(condition, message)
        if !condition { throw QAError(message: message) }
    }

    @MainActor private func capture(_ app: XCUIApplication, name: String, output: URL?) {
        let tree = app.debugDescription
        let screenshot = app.screenshot()
        let image = XCTAttachment(screenshot: screenshot)
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let description = XCTAttachment(string: tree)
        description.name = "\(name)-accessibility"
        description.lifetime = .keepAlways
        add(description)
        if let output {
            do {
                try tree.write(to: output.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
                try screenshot.pngRepresentation.write(to: output.appendingPathComponent("\(name).png"), options: .atomic)
            } catch { XCTFail("Could not write QA evidence: \(error)") }
        }
    }
}
