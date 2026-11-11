import XCTest
import CassiniNotebook
import CassiniEngine
@testable import Cassini

@MainActor final class ExportStoreTests: XCTestCase {
    func testATranscriptExportShowsTheLatestEditAndIsRemovedWhenTheShareSheetCloses() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        var note = Note(title: "Meeting: Monday", createdAt: Date(timeIntervalSince1970: 1_791_472_200), audioFilename: "audio.caf")
        note.duration = 65; note.status = .ready
        note.speakers = [NoteSpeaker(id: "S1", name: "Giulia"), NoteSpeaker(id: "S2", name: "Speaker 2")]
        note.transcript = [TranscriptSegment(text: "Hello", start: 1, end: 2, speakerID: "S1"),
                           TranscriptSegment(text: "Welcome", start: 3, end: 4, speakerID: "S2")]
        try NoteRepository(root: test.root).save(note)
        await test.graph.start()
        test.graph.library.update(note.id) { $0.transcript[1].text = "Good evening" }

        let url = try await test.graph.exports.exportTranscript(note.id, format: .text)

        XCTAssertEqual(url.lastPathComponent, "Meeting_ Monday.txt")
        XCTAssertEqual(plainSpaces(try String(contentsOf: url, encoding: .utf8)),
                       "Meeting: Monday\nOct 8, 2026, 3:10 PM · 01:05 · 2 speakers\n\n[00:01] Giulia\nHello\n\n[00:03] Speaker 2\nGood evening\n")
        test.graph.exports.discard(url)
        await test.graph.exports.waitForDiscards()
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

    func testAnExportMadeDuringLaunchWaitsForTheSweepAndSurvivesIt() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = transcribedNote()
        try NoteRepository(root: test.root).save(note)
        let export = Task { try await test.graph.exports.exportTranscript(note.id, format: .subtitles) }

        await test.graph.start()
        let url = try await export.value

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the launch sweep ran before the export")
    }

    func testTheShareSheetRemovesAnExportOnceItIsDismissedAndNotWhenAnActivityIsCancelled() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let note = transcribedNote()
        try NoteRepository(root: test.root).save(note)
        await test.graph.start()
        let url = try await test.graph.exports.exportTranscript(note.id, format: .webVTT)
        let item = test.graph.exports.shareItem(url)
        var session = ShareSession()
        session.present(item)

        XCTAssertFalse(ShareSheet.closes(activity: .mail, completed: false), "backing out of Mail keeps the sheet")
        XCTAssertTrue(ShareSheet.closes(activity: .airDrop, completed: true))
        XCTAssertTrue(ShareSheet.closes(activity: nil, completed: false), "closing the sheet without an activity")
        XCTAssertNil(session.dismiss(current: item), "the sheet still shows the item")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let dismissed = try XCTUnwrap(session.dismiss(current: nil))
        dismissed.onComplete?()
        dismissed.onComplete?()
        await test.graph.exports.waitForDiscards()

        XCTAssertEqual(dismissed.id, item.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNil(session.dismiss(current: nil), "a dismissal ends one item once")
    }

    func testTheMenuGivesTheReasonATranscriptCannotBeExported() {
        XCTAssertNil(ExportCopy.reason(.available))
        XCTAssertEqual(ExportCopy.reason(.afterTranscription), "Available after transcription")
        XCTAssertEqual(ExportCopy.reason(.notReadable), "Not available for this transcript")
        var damaged = transcribedNote()
        damaged.document = DocumentInfo(state: .invalidMetadata)
        XCTAssertEqual(TranscriptExports.availability(of: damaged), .notReadable)
    }

    func testExportDateAndClockUseTheSameExplicitZoneAcrossMidnight() throws {
        let cases: [(TimeZone, String, String)] = [
            (try XCTUnwrap(TimeZone(secondsFromGMT: 20_700)), "2026-01-01T00:15:00Z", "Jan 1, 2026, 6:00 AM · 00:04"),
            (try XCTUnwrap(TimeZone(secondsFromGMT: -12_600)), "2026-01-01T00:15:00Z", "Dec 31, 2025, 8:45 PM · 00:04"),
            (try XCTUnwrap(TimeZone(secondsFromGMT: 50_400)), "2025-12-31T12:15:00Z", "Jan 1, 2026, 2:15 AM · 00:04"),
            (try XCTUnwrap(TimeZone(identifier: "Etc/GMT-14")), "2025-12-31T12:15:00Z", "Jan 1, 2026, 2:15 AM · 00:04"),
            (try XCTUnwrap(TimeZone(identifier: "Etc/GMT+12")), "2026-01-01T00:15:00Z", "Dec 31, 2025, 12:15 PM · 00:04"),
            (try XCTUnwrap(TimeZone(identifier: "EST5EDT")), "2026-01-01T00:15:00Z", "Dec 31, 2025, 7:15 PM · 00:04"),
            (try XCTUnwrap(TimeZone(identifier: "EST5EDT")), "2026-07-01T00:15:00Z", "Jun 30, 2026, 8:15 PM · 00:04")
        ]
        let globalZone = TimeZone.current.identifier
        let globalLocale = Locale.current.identifier
        for (zone, timestamp, expected) in cases {
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: timestamp))
            let value = ExportCopy.subtitle(meetingTime: .instant(date), durationMs: 4_000, speakers: 1,
                                            locale: Locale(identifier: "en_US"), timeZone: zone)
            XCTAssertEqual(plainSpaces(value), expected, zone.identifier)
        }
        XCTAssertEqual(TimeZone.current.identifier, globalZone)
        XCTAssertEqual(Locale.current.identifier, globalLocale)
    }

    func testExportPreservesUnzonedLabelVerbatimAndNeverFabricatesAnUnknownDate() throws {
        let local = "2026-01-01T00:15:00"
        for zone in [try XCTUnwrap(TimeZone(secondsFromGMT: 50_400)),
                     try XCTUnwrap(TimeZone(identifier: "EST5EDT"))] {
            let locale = Locale(identifier: "en_US")
            XCTAssertEqual(ExportCopy.subtitle(meetingTime: .local(local), durationMs: 65_000, speakers: 2,
                                                locale: locale, timeZone: zone),
                           "2026-01-01T00:15:00 · 01:05 · 2 speakers")
            XCTAssertEqual(ExportCopy.subtitle(meetingTime: .unknown, durationMs: 65_000, speakers: 2,
                                                locale: locale, timeZone: zone), "01:05 · 2 speakers")
        }
    }

    private func transcribedNote() -> Note {
        var note = Note(title: "Meeting", audioFilename: "audio.caf")
        note.duration = 5; note.status = .ready
        note.transcript = [TranscriptSegment(text: "Hello everyone", start: 1, end: 2, speakerID: "S1")]
        return note
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
