import XCTest
import CassiniNotebook
import CassiniEngine
@testable import Cassini

@MainActor final class ExportStoreTests: XCTestCase {
    func testATranscriptExportShowsTheLatestEditAndIsRemovedWhenTheShareSheetCloses() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        var note = Note(title: "Riunione: lunedì", createdAt: Date(timeIntervalSince1970: 1_791_472_200), audioFilename: "audio.caf")
        note.duration = 65; note.status = .ready
        note.speakers = [NoteSpeaker(id: "S1", name: "Giulia"), NoteSpeaker(id: "S2", name: "Speaker 2")]
        note.transcript = [TranscriptSegment(text: "Ciao", start: 1, end: 2, speakerID: "S1"),
                           TranscriptSegment(text: "Buongiorno", start: 3, end: 4, speakerID: "S2")]
        try NoteRepository(root: test.root).save(note)
        await test.graph.start()
        test.graph.library.update(note.id) { $0.transcript[1].text = "Buonasera" }

        let url = try await test.graph.exports.exportTranscript(note.id, format: .text)

        XCTAssertEqual(url.lastPathComponent, "Riunione_ lunedì.txt")
        XCTAssertEqual(plainSpaces(try String(contentsOf: url, encoding: .utf8)),
                       "Riunione: lunedì\nOct 8, 2026, 3:10 PM · 01:05 · 2 speakers\n\n[00:01] Giulia\nCiao\n\n[00:03] Speaker 2\nBuonasera\n")
        test.graph.exports.discard(url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: test.graph.environment.exports.path))
    }

    func testAnAudioOnlyNoteHasNoTranscriptToExport() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = Note(title: "Solo audio", audioFilename: "audio.caf")
        try NoteRepository(root: test.root).save(note)
        await test.graph.start()
        do {
            _ = try await test.graph.exports.exportTranscript(note.id, format: .subtitles)
            XCTFail("an audio-only note exported a transcript")
        } catch {
            XCTAssertEqual(error, .notAvailable(.afterTranscription))
            XCTAssertEqual(ExportCopy.message(error), "Available after transcription")
        }
    }

    func testTheLaunchSweepRemovesExportsLeftFromTheLastRun() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let left = test.graph.environment.exports.appendingPathComponent("\(UUID().uuidString)/left.txt")
        try FileManager.default.createDirectory(at: left.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: left)

        let report = await test.graph.start()

        XCTAssertTrue(report.ran.contains(.sweep))
        XCTAssertFalse(FileManager.default.fileExists(atPath: test.graph.environment.exports.path))
    }

    func testTheSubtitleLineCountsSpeakersFromTwo() {
        let at = Date(timeIntervalSince1970: 1_791_472_200)
        let locale = Locale(identifier: "en_US"), utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(plainSpaces(ExportCopy.subtitle(createdAt: at, durationMs: 3_790_000, speakers: 3, locale: locale, timeZone: utc)),
                       "Oct 8, 2026, 3:10 PM · 1:03:10 · 3 speakers")
        XCTAssertEqual(plainSpaces(ExportCopy.subtitle(createdAt: at, durationMs: 4_000, speakers: 1, locale: locale, timeZone: utc)),
                       "Oct 8, 2026, 3:10 PM · 00:04")
    }

    /// The time formatter puts a narrow no-break space before "PM".
    private func plainSpaces(_ text: String) -> String { text.replacingOccurrences(of: "\u{202F}", with: " ") }
}
