import Foundation
import XCTest
import UIKit
import Vision

/// QA only: real adapters and UI, one stateful journey on an owned, fresh simulator.
final class LiveMainJourneyQATests: XCTestCase {
    private struct Failure: Error { let message: String }
    private let names = ["acknowledgment", "monologue", "overlapping-turns"]

    @MainActor func testRealMainJourney() throws {
        let env = ProcessInfo.processInfo.environment
        guard let inputsPath = env["CASSINI_QA_INPUTS"], let outputPath = env["CASSINI_QA_OUTPUT"] else {
            throw XCTSkip("Live QA requires CASSINI_QA_INPUTS and CASSINI_QA_OUTPUT")
        }
        executionTimeAllowance = 2400 // Outer hang guard, never a performance assertion.
        let inputs = URL(fileURLWithPath: inputsPath, isDirectory: true)
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let app = XCUIApplication(bundleIdentifier: "io.codemyriad.cassini")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        XCUIDevice.shared.orientation = .portrait
        app.launch() // No --ui-testing, seeds, memory overrides or fake completion marker.
        defer { capture(app, "journey-end", output) }
        try wait(app, "Library unavailable", 45) { app.buttons["settingsButton"].exists }
        let container = try ownedContainer() // Resolve after launch, which can rotate simulator container UUIDs.
        capture(app, "library", output)
        try tap(app, app.buttons["settingsButton"])
        try download(app, "Parakeet Ultra", output, suggestion: "downloadParakeetSuggestion")
        try download(app, "Telling speakers apart", output)
        let identify = app.switches["Identify speakers after transcription"]
        try require(app.scroll(until: { identify.isHittable }), "Identify speakers toggle unavailable")
        if identify.value as? String == "0" { try tap(app, identify) }
        try wait(app, "Speaker identification not enabled", 15) { identify.value as? String == "1" }
        let choice = app.buttons["speechModelChoice"]
        if app.scroll(up: false, until: { choice.isHittable }), choice.exists {
            try tap(app, choice)
            try tap(app, app.buttons["Parakeet Ultra"])
        }
        let autoTranscribe = app.switches["Transcribe after recording or import"]
        try require(app.scroll(up: false, until: { autoTranscribe.isHittable }), "Auto-transcribe preference unavailable")
        if autoTranscribe.value as? String == "0" { try tap(app, autoTranscribe) }
        try wait(app, "Auto-transcribe did not enable", 15) { autoTranscribe.value as? String == "1" }
        capture(app, "models-ready", output)
        let audio = URL(fileURLWithPath: env["CASSINI_QA_AUDIO"] ?? inputs.appendingPathComponent("synthetic-english.wav").path)
        try require(FileManager.default.fileExists(atPath: audio.path), "Synthetic English WAV missing")
        app.open(audio)
        let asrTitles = Set([env["CASSINI_QA_ASR_TITLE"] ?? "synthetic-english", audio.deletingPathExtension().lastPathComponent, audio.lastPathComponent])
        try wait(app, "Imported ASR note title does not match synthetic English fixture", 120) {
            let title = app.staticTexts["noteTitle"]
            return title.exists && asrTitles.contains(title.label)
        }
        capture(app, "asr-imported", output)
        let consent = app.buttons["Download and transcribe"]
        if consent.exists { try tap(app, consent) }
        try wait(app, "ASR did not seal successfully", 1800) {
            if self.has(app, "noSpeech") { throw Failure(message: "Synthetic English speech produced noSpeech") }
            return !self.paragraphs(app).isEmpty && !self.has(app, "draftTranscript") && !self.has(app, "progressHeadline")
        }
        capture(app, "asr-sealed", output)
        try snapshotJSON(container, into: output.appendingPathComponent("asr-json"))
        try export(app, format: "Transcript as text", ext: "txt", name: "actual-asr", container, output)
        try export(app, format: "Timed transcript · JSON", ext: "json", name: "actual-asr", container, output)
        for name in names {
            let title = "CONTROLLED D84 - NOT ASR - " + name
            let document = inputs.appendingPathComponent("controlled-documents/D84-CONTROLLED-NOT-ASR-" + name + ".opus")
            try require(FileManager.default.fileExists(atPath: document.path), "Controlled D84 document missing: " + name)
            let expected = try expectedRows(name, inputs)
            app.open(document)
            try wait(app, "Controlled import did not open exact title: " + title, 120) {
                let label = app.staticTexts["noteTitle"]
                return label.exists && label.label == title
            }
            try wait(app, "Controlled transcript did not render: " + name, 60) { !self.paragraphs(app).isEmpty }
            let observed = try collectParagraphs(app, expected: expected, canonical: canonicalRows(name, inputs), name: name, output)
            try require(observed == expected, "Full controlled paragraphs differ from canonical rows: " + name)
            try writeJSON(["controlledNotASR": true, "title": title, "expected": expected, "observed": observed],
                          output.appendingPathComponent(name + "-paragraphs.json"))
            if name == "acknowledgment" { try chipLabelSeek(app, output) }
            try export(app, format: "Transcript as text", ext: "txt", name: name, container, output)
        }
        try snapshotJSON(container, into: output.appendingPathComponent("final-json"))
        try writeJSON(["status": "passed", "actualASRTextAndJSONExported": true, "controlledDocumentCount": names.count,
                       "controlledNotASR": true, "chipLabelSeek": "OCR exact (Ben: prefix tapped; playback paused near 3.05s, whole-second AX precision"],
                      output.appendingPathComponent("journey-result.json"))
    }

    @MainActor private func chipLabelSeek(_ app: XCUIApplication, _ output: URL) throws {
        let paragraph = paragraphs(app).first { $0.label.contains("(Ben:") && $0.frame.intersects(app.frame) }
        guard let paragraph else { throw Failure(message: "Controlled Ben chip paragraph not visible") }
        try require(app.state == .runningForeground, "Cassini must be foreground for controlled OCR")
        let screen = XCUIScreen.main.screenshot().image
        guard let raw = screen.cgImage else { throw Failure(message: "Screenshot has no pixels") }
        let sideways: Bool
        switch screen.imageOrientation {
        case .left, .leftMirrored, .right, .rightMirrored: sideways = true
        default: sideways = false
        }
        let size = CGSize(width: sideways ? raw.height : raw.width, height: sideways ? raw.width : raw.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            screen.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let pixels = normalized.cgImage else { throw Failure(message: "Screenshot normalization failed") }
        let frame = app.frame
        try require(abs(frame.minX) < 1 && abs(frame.minY) < 1 && frame.width > 0 && frame.height > 0,
                    "App origin/size does not match a full-screen screenshot")
        try require(abs(CGFloat(pixels.width) / CGFloat(pixels.height) - frame.width / frame.height) < 0.025,
                    "Normalized screenshot aspect does not match app; no OCR tap")
        let region = paragraph.frame.intersection(frame)
        try require(!region.isEmpty, "Chip paragraph outside screenshot")
        let sx = CGFloat(pixels.width) / frame.width, sy = CGFloat(pixels.height) / frame.height
        let rect = CGRect(x: region.minX * sx, y: region.minY * sy, width: region.width * sx, height: region.height * sy).integral
        guard let crop = pixels.cropping(to: rect), let png = UIImage(cgImage: crop).pngData() else {
            throw Failure(message: "Cannot crop controlled chip paragraph")
        }
        try png.write(to: output.appendingPathComponent("chip-prefix-ocr.png"), options: .atomic)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: crop, orientation: .up).perform([request])
        var matches: [CGRect] = []
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first,
                  let range = candidate.string.range(of: "(Ben:"),
                  let box = try candidate.boundingBox(for: range) else { continue }
            matches.append(box.boundingBox)
        }
        try require(matches.count == 1, "Expected one OCR exact (Ben: prefix, found \(matches.count); no blind tap")
        let box = matches[0]
        let point = CGPoint(x: region.minX + box.midX * region.width, y: region.minY + (1 - box.midY) * region.height)
        try require(region.contains(point) && app.frame == frame, "OCR/app geometry changed; no tap")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x - frame.minX, dy: point.y - frame.minY)).tap()
        let play = app.buttons["playButton"]
        try wait(app, "Ben prefix tap did not start playback", 10) { self.isPlaying(app) }
        play.tap() // Pause immediately after the Playing event, without a timed playback interval.
        try wait(app, "Chip playback did not pause", 10) { play.exists && !self.isPlaying(app) }
        let clock = app.descendants(matching: .any).matching(identifier: "playbackPosition").firstMatch
        guard let value = clock.value as? String,
              let range = value.range(of: #"\d{1,2}:\d{2}(?::\d{2})?"#, options: .regularExpression) else {
            throw Failure(message: "Paused playback clock unavailable")
        }
        let seconds = value[range].split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 }
        try require(seconds >= 3 && seconds <= 4, "Paused playback clock not near Ben's 3050ms word")
        try writeJSON(["controlledNotASR": true, "target": "(Ben:", "ocrExactPrefix": true,
                       "expectedChipFirstWordMs": 3050, "observedPausedSeconds": seconds,
                       "precision": "AX whole seconds; does not prove exact 3.05s or distinguish 3.00s",
                       "tapPoint": [point.x, point.y], "rawPixels": [raw.width, raw.height],
                       "imageOrientation": screen.imageOrientation.rawValue, "normalizedPixels": [pixels.width, pixels.height]],
                      output.appendingPathComponent("chip-prefix-seek.json"))
        capture(app, "chip-prefix-seek-paused", output)
    }

    @MainActor private func isPlaying(_ app: XCUIApplication) -> Bool {
        let play = app.buttons["playButton"]
        return play.exists && ((play.value as? String) == "Playing" || play.label == "Pause")
    }

    private func ownedContainer() throws -> URL {
        let envOwner = ProcessInfo.processInfo.environment["CASSINI_QA_OWNER"] ?? "INVALID"
        let parent = URL(fileURLWithPath: NSHomeDirectory()).deletingLastPathComponent()
        let directories = try FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)
        let matches = directories.filter {
            let marker = $0.appendingPathComponent("Documents/qa-owned-app.marker")
            return (try? String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)) == envOwner
        }
        try require(matches.count == 1, "Expected exactly one owned Cassini container marker, found \(matches.count)")
        return matches[0]
    }

    @MainActor private func download(_ app: XCUIApplication, _ name: String, _ output: URL, suggestion: String? = nil) throws {
        let failed = app.descendants(matching: .any).matching(NSPredicate(
            format: "label BEGINSWITH %@ AND (label CONTAINS %@ OR label CONTAINS %@)", name, "Download failed", "Not available")).firstMatch
        let ready = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@ AND label ENDSWITH %@", name, "Ready")).firstMatch
        let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", name)).firstMatch
        let suggestionButton = suggestion.map { app.buttons[$0] }
        try require(app.scroll(until: { ready.exists || button.isHittable || suggestionButton?.isHittable == true }), "Model row unavailable: " + name)
        if ready.exists { return }
        if let suggestionButton, suggestionButton.isHittable { try tap(app, suggestionButton) } else { try tap(app, button) }
        try tap(app, app.buttons["Download"])
        try wait(app, "Model installation did not finish: " + name, 1800) {
            if failed.exists {
                throw Failure(message: "Model installation failed: " + failed.label)
            }
            return ready.exists
        }
        capture(app, "ready-" + name, output)
    }

    private func canonicalRows(_ name: String, _ inputs: URL) throws -> [[String: Any]] {
        let candidates = [inputs.appendingPathComponent("vectors/" + name + ".expected.json"),
                          inputs.appendingPathComponent("controlled-documents/" + name + "-expected.json")]
        guard let url = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let rows = object["rows"] as? [[String: Any]], !rows.isEmpty else { throw Failure(message: "Expected vector missing: " + name) }
        return rows
    }

    private func expectedRows(_ name: String, _ inputs: URL) throws -> [String] {
        let rows = try canonicalRows(name, inputs)
        let labels = ["ada": "Ada", "ben": "Ben", "cy": "Cy"]
        return try rows.map { row in
            guard let members = row["members"] as? [[String: Any]] else { throw Failure(message: "Malformed row members") }
            return try members.map { member -> String in
                guard let text = member["text"] as? String else { throw Failure(message: "Malformed member text") }
                if member["kind"] as? String == "interjection" {
                    guard let speaker = member["speaker"] as? String, let label = labels[speaker] else { throw Failure(message: "Unknown controlled speaker") }
                    return "(" + label + ": " + text + ")"
                }
                return text
            }.joined(separator: " ")
        }
    }

    @MainActor private func collectParagraphs(_ app: XCUIApplication, expected: [String], canonical: [[String: Any]], name: String, _ output: URL) throws -> [String] {
        var ids: [String] = [], labels: [String: String] = [:], headers: [String: String] = [:]
        for viewport in 0..<30 { // Work bound only; check completion before every swipe.
            for element in self.paragraphs(app) where element.frame.intersects(app.frame) && !element.frame.isEmpty {
                if labels[element.identifier] == nil { ids.append(element.identifier) }
                labels[element.identifier] = element.label
                let headerID = "speakerHeader-" + String(element.identifier.dropFirst("turn-".count))
                let header = app.descendants(matching: .any).matching(identifier: headerID).firstMatch
                if header.exists { headers[element.identifier] = header.label }
            }
            capture(app, name + "-viewport-\(viewport)", output)
            if ids.count >= expected.count {
                try writeJSON(ids.enumerated().map { ["rowIndex": $0.offset, "paragraphID": $0.element,
                                                      "header": headers[$0.element] ?? "MISSING"] as [String: Any] },
                              output.appendingPathComponent(name + "-headers.json"))
                try validateHeaders(ids, headers, canonical)
                return ids.compactMap { labels[$0] }
            }
            app.swipeUp()
        }
        throw Failure(message: "Not all controlled paragraphs reachable: " + name + " observed \(ids.count)/\(expected.count)")
    }

    private func validateHeaders(_ ids: [String], _ headers: [String: String], _ rows: [[String: Any]]) throws {
        try require(ids.count == rows.count, "Header row count differs from canonical vector")
        let names = ["ada": "Ada", "ben": "Ben", "cy": "Cy"]
        for (index, id) in ids.enumerated() {
            guard let header = headers[id] else { throw Failure(message: "Speaker header missing for canonical row \(index)") }
            let row = rows[index]
            if let speaker = row["speaker"] as? String, let name = names[speaker] {
                let continuation = row["continuation"] as? Bool == true
                try require(header.contains(name) == !continuation,
                            "Speaker name repetition/omission on row \(index): " + header)
            }
            let over = (row["over"] as? [String] ?? []).compactMap { names[$0] }
            if over.isEmpty {
                try require(!header.contains("(over "), "Unexpected over header on canonical row \(index): " + header)
            } else {
                let list = over.count == 1 ? over[0] : over.dropLast().joined(separator: ", ") + " and " + over.last!
                try require(header.contains("(over " + list + ")"), "Competing speakers missing on canonical row \(index): " + header)
            }
        }
    }

    @MainActor private func export(_ app: XCUIApplication, format: String, ext: String, name: String, _ container: URL, _ output: URL) throws {
        try tap(app, app.buttons["noteActions"])
        try tap(app, app.buttons["Export transcript"])
        try tap(app, app.buttons[format])
        try wait(app, "Share sheet unavailable for " + format, 90) {
            app.buttons["Copy"].exists || app.buttons["Save to Files"].exists || app.otherElements["ActivityListView"].exists
        }
        capture(app, name + "-" + ext + "-share", output)
        let folder = container.appendingPathComponent("tmp/Exports")
        let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey])
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension.lowercased() == ext }
        try require(files.count == 1, "Expected one actual " + ext + " export while sheet open, found \(files.count)")
        let bytes = try Data(contentsOf: files[0])
        try require(!bytes.isEmpty, "Actual export is empty")
        if ext == "json" { _ = try JSONSerialization.jsonObject(with: bytes) }
        try bytes.write(to: output.appendingPathComponent(name + "." + ext), options: .atomic)
        try writeJSON(["source": files[0].path, "bytes": bytes.count, "format": format, "copiedWhileShareSheetOpen": true],
                      output.appendingPathComponent(name + "-" + ext + "-export-evidence.json"))
        let close = app.buttons["Close"]
        let cancel = app.buttons["Cancel"]
        if close.exists && close.isHittable { try tap(app, close) }
        else if cancel.exists && cancel.isHittable { try tap(app, cancel) }
        else { app.swipeDown() }
        try wait(app, "Share sheet did not dismiss", 20) {
            !app.buttons["Copy"].exists && !app.buttons["Save to Files"].exists && !app.otherElements["ActivityListView"].exists
        }
    }

    private func snapshotJSON(_ container: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let root = container.appendingPathComponent("Library/Application Support/Cassini")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "json" }
        try require(!files.isEmpty, "Owned note/job/provenance JSON missing")
        var paths: [String] = []
        for source in files {
            let relative = String(source.path.dropFirst(root.path.count + 1))
            let destination = folder.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bytes = try Data(contentsOf: source)
            _ = try JSONSerialization.jsonObject(with: bytes)
            try bytes.write(to: destination, options: .atomic)
            paths.append(relative)
        }
        try writeJSON(["sourceRoot": root.path, "files": paths.sorted()], folder.appendingPathComponent("snapshot-index.json"))
    }

    @MainActor private func paragraphs(_ app: XCUIApplication) -> [XCUIElement] {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "turn-")).allElementsBoundByIndex
    }
    @MainActor private func has(_ app: XCUIApplication, _ identifier: String) -> Bool {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch.exists
    }
    @MainActor private func tap(_ app: XCUIApplication, _ element: XCUIElement) throws {
        try wait(app, "Control unavailable: " + element.identifier + " " + element.label, 25) { element.exists && element.isHittable && element.isEnabled }
        element.tapWhenSettled()
    }
    @MainActor private func wait(_ app: XCUIApplication, _ message: String, _ timeout: TimeInterval, _ condition: @escaping () throws -> Bool) throws {
        var failure: Error?
        let predicate = NSPredicate { _, _ in
            self.notifications(app)
            do { return try condition() } catch { failure = error; return true }
        }
        let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout)
        if let failure { throw failure }
        try require(result == .completed, message)
    }
    @MainActor private func notifications(_ app: XCUIApplication) {
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
    private func require(_ value: Bool, _ message: String) throws {
        XCTAssertTrue(value, message)
        if !value { throw Failure(message: message) }
    }
    private func writeJSON(_ object: Any, _ url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String, _ output: URL) {
        let image = app.screenshot()
        let attachment = XCTAttachment(screenshot: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        do {
            try image.pngRepresentation.write(to: output.appendingPathComponent(name + ".png"), options: .atomic)
            try app.debugDescription.write(to: output.appendingPathComponent(name + ".txt"), atomically: true, encoding: .utf8)
        } catch { XCTFail("Could not save QA evidence: \(error)") }
    }
}
