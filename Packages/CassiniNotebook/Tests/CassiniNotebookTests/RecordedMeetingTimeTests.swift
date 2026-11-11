import Foundation
import Testing
import CassiniCore
@testable import CassiniNotebook

struct RecordedMeetingTimeTests {
    private let start = Date(timeIntervalSince1970: 1_794_212_100)

    @Test func recordingExportReimportUsesPositionZeroRatherThanSealTime() throws {
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let opus = folder.appendingPathComponent("source.opus")
        try Data(PortableFixtures.silence()).write(to: opus)
        var note = Note(title: "English planning meeting", createdAt: start.addingTimeInterval(540))
        note.meetingTime = .instant(start)
        note.transcript = [TranscriptSegment(text: "Hello", start: 0, end: 0.5)]
        let exported = folder.appendingPathComponent("exported.opus")
        try PortableTranscript.export(note: note, opus: opus, destination: exported, unassignedLabel: "Unknown speaker")
        let portable = try #require(PortableTranscript.read(from: exported))
        #expect(portable.meetingTime == .instant(start))
        #expect(portable.createdAt != start)
        let imported = ImportedNote.make(id: UUID(), displayName: nil, fallbackTitle: "Import", sha256: "hash",
            importedAt: start.addingTimeInterval(540), audio: ImportedAudio(filename: "audio.opus", duration: 1), document: portable)
        #expect(imported.meetingTime == .instant(start))
        #expect(imported.sortDate == start)
        let texts = ExportTexts(subtitle: { date, _, _ in date.ISO8601Format() }, emptyText: "No words", unassignedLabel: "Unknown speaker")
        let text = String(decoding: try TranscriptExports.data(imported, format: .text, texts: texts), as: UTF8.self)
        #expect(text.contains(start.ISO8601Format()))
        let encoded = try JSONEncoder().encode(imported)
        #expect(try JSONDecoder().decode(Note.self, from: encoded).meetingTime == .instant(start))
    }

    @Test func nineMinuteSealDelaySurvivesPortableExportAndReimport() throws {
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let audio = try PortableFixtures.silence()
        let transcript = Transcript([Word("a", 0, 20, "Hello")])
        let recorded = "2026-11-09T09:31:48Z"
        let sealed = "2026-11-09T09:40:48Z"
        var source = CassiniDocument.read(try CassiniDocument.create(audio, transcript: transcript,
            title: "English meeting", processing: JSONObject()))
        var manifest = try #require(source.manifest)
        var meeting = try manifest.object("meeting")
        meeting["recordedAtUtc"] = .string(recorded)
        meeting["createdAtUtc"] = .string(sealed)
        manifest["meeting"] = .object(meeting)
        source.manifest = manifest
        let original = folder.appendingPathComponent("document.opus")
        try Data(CassiniDocument.create(audio, transcript: transcript, title: "English meeting", processing: JSONObject(),
                                       existing: source)).write(to: original)
        let portable = try #require(PortableTranscript.read(from: original))
        #expect(portable.createdAt == MeetingTime.parse(sealed))
        let note = ImportedNote.make(id: UUID(), displayName: nil, fallbackTitle: "Import", sha256: "hash", importedAt: start,
            audio: ImportedAudio(filename: "document.opus", duration: 1), document: portable)
        let copy = folder.appendingPathComponent("copy.opus")
        try PortableTranscript.export(note: note, opus: original, destination: copy, unassignedLabel: "Unknown speaker")
        let reimported = try #require(PortableTranscript.read(from: copy))
        #expect(reimported.createdAt == MeetingTime.parse(sealed))
        #expect(reimported.meetingTime.instant == MeetingTime.parse(recorded))
    }

    @Test func catalogueReloadReadsTheOriginalDocumentNotTheDecodedPlaybackFile() throws {
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try NoteRepository(root: folder)
        let bytes = try CassiniDocument.create(PortableFixtures.silence(), transcript: Transcript([Word("a", 0, 20, "Hello")]),
            title: "English meeting", processing: JSONObject(), recordedAt: start)
        let portable = try #require(PortableTranscript(CassiniDocument.read(bytes)))
        var note = ImportedNote.make(id: UUID(), displayName: nil, fallbackTitle: "Import", sha256: "hash", importedAt: start.addingTimeInterval(540),
            audio: ImportedAudio(filename: "playback.caf", originalFilename: "document.opus", duration: 1), document: portable)
        // Simulate an older catalogue whose cached date was the seal stamp.
        note.meetingTime = .unknown
        try repository.save(note)
        try Data(bytes).write(to: repository.originalAudioURL(for: note))
        try Data("decoded playback".utf8).write(to: repository.audioURL(for: note))
        #expect(try repository.load().notes.first?.meetingTime == .instant(start))
        #expect(try Data(contentsOf: repository.originalAudioURL(for: note)) == Data(bytes))
    }

    @Test(arguments: [NoteOrigin.recorded, .recovered])
    func ownRecordingKeepsKnownStartAcrossReloadAndLegacyFileReexport(_ origin: NoteOrigin) throws {
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let repository = try NoteRepository(root: folder)
        let bytes = try PortableFixtures.document([Word("a", 0, 20, "Hello")], title: "English meeting", language: "en")
        let source = CassiniDocument.read(bytes)
        #expect(source.manifest?["meeting"]?.object?["recordedAtUtc"] == nil)
        var note = Note(title: "English meeting", createdAt: start.addingTimeInterval(540), audioFilename: "playback.caf")
        note.origin = origin
        note.originalAudioFilename = "document.opus"
        note.meetingTime = .instant(start)
        note.transcript = [TranscriptSegment(text: "Hello", start: 0, end: 0.02)]
        try repository.save(note)
        let original = repository.originalAudioURL(for: note)
        try Data(bytes).write(to: original)
        try Data("decoded playback".utf8).write(to: repository.audioURL(for: note))
        let reloaded = try #require(repository.load().notes.first)
        #expect(reloaded.meetingTime == .instant(start))
        let output = folder.appendingPathComponent("exported.opus")
        try PortableTranscript.export(note: reloaded, opus: original, destination: output, unassignedLabel: "Unknown speaker")
        let exported = CassiniDocument.readChecked(output)
        #expect(exported.state == .ok)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let expected = formatter.string(from: start)
        #expect(exported.manifest?["meeting"]?.object?["recordedAtUtc"]?.string == expected)
        #expect(exported.comments.contains("CASSINI_RECORDED_AT_UTC=" + expected))
        #expect(exported.comments.contains("DATE=" + expected))
        #expect(MeetingTime.read(exported) == .instant(start))
        #expect(exported.manifest?["meeting"]?.object?["id"] == source.manifest?["meeting"]?.object?["id"])
        #expect(try Data(contentsOf: original) == Data(bytes))
        #expect(try OggOpus.read(Array(Data(contentsOf: output))).audio == OggOpus.read(bytes).audio)
    }

    @Test func legacyRecordedOriginPreservesItsRecorderStartStamp() throws {
        let note = Note(title: "Old English recording", createdAt: start)
        let bytes = try JSONEncoder().encode(note)
        var json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        json.removeValue(forKey: "meetingTime")
        let loaded = try JSONDecoder().decode(Note.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(loaded.meetingTime == .instant(start))
        #expect(loaded.sortDate == start)
    }

    @Test func writtenLocalDayNeverMovesAcrossViewerZones() throws {
        let label = MeetingTime.local("2026-11-09T00:15:00")
        for zone in ["Pacific/Honolulu", "Pacific/Kiritimati"] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(identifier: zone))
            #expect(label.instant == nil)
            #expect(label.day(in: calendar) == CalendarDay(year: 2026, month: 11, day: 9))
            let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 9)))
            let end = try #require(calendar.date(byAdding: .day, value: 1, to: start))
            #expect(label.isWithin(DateInterval(start: start, end: end), calendar: calendar))
            #expect(!MeetingTime.local("2026-11-08T23:59:59").isWithin(DateInterval(start: start, end: end), calendar: calendar))
            #expect(!MeetingTime.local("2026-11-10T00:00:00").isWithin(DateInterval(start: start, end: end), calendar: calendar))
        }
        #expect(MeetingTime.local("2026-02-29T12:00:00").day(in: Calendar(identifier: .gregorian)) == nil)
        #expect(MeetingTime.local("2028-02-29T12:00:00").day(in: Calendar(identifier: .gregorian)) == CalendarDay(year: 2028, month: 2, day: 29))
    }

    @Test func dateFallbackComparesInstantsAndKeepsZoneLessLabelAsWritten() {
        let m = JSONObject([("meeting", .object(JSONObject([("createdAtUtc", .string("2026-11-09T09:40:48Z")),
            ("recordedAtLocal", .string("2026-11-09T09:31:48"))])))])
        var doc = CassiniDocument(state: .ok, manifest: m, comments: ["DATE=2026-11-09T10:40:48+01:00"])
        #expect(MeetingTime.read(doc) == .local("2026-11-09T09:31:48"))
        doc.comments = ["date=2026-11-09T10:31:48+01:00"]
        #expect(MeetingTime.read(doc).instant == MeetingTime.parse("2026-11-09T09:31:48Z"))
        doc.comments = ["DATE=2026-11-09T09:31:48"]
        #expect(MeetingTime.read(doc) == .local("2026-11-09T09:31:48"))
        doc.manifest?["meeting"] = .object(JSONObject([("createdAtUtc", .string("2026-11-09T09:40:48Z"))]))
        #expect(MeetingTime.read(doc) == .unknown)
    }

    @Test func unknownImportedDatesDoNotBecomeImportOrSealDatesInText() throws {
        let bytes = try PortableFixtures.document([Word("a", 0, 20, "Hello")], title: "English note")
        let portable = try #require(PortableTranscript(CassiniDocument.read(bytes)))
        #expect(portable.meetingTime == .unknown)
        let note = ImportedNote.make(id: UUID(), displayName: nil, fallbackTitle: "Import", sha256: "hash", importedAt: start,
            audio: ImportedAudio(filename: "audio.opus", duration: 1), document: portable)
        let texts = ExportTexts(subtitle: { _, _, _ in "FALSE DATE" }, emptyText: "No words", unassignedLabel: "Unknown speaker")
        let text = String(decoding: try TranscriptExports.data(note, format: .text, texts: texts), as: UTF8.self)
        #expect(!text.contains("FALSE DATE"))
        #expect(note.meetingTime == .unknown)
    }

    @Test(.enabled(if: Conformance.available, Comment(rawValue: Conformance.missing)),
          arguments: ["027-recorded-at-utc", "028-date-is-created-at", "029-date-with-offset"])
    func publishedMeetingStartVectors(_ id: String) throws {
        let url = Conformance.vector(id)
        let portable = try #require(PortableTranscript.read(from: url))
        #expect(portable.state == .ok)
        if id.hasPrefix("028") { #expect(portable.meetingTime == .local("2026-11-09T09:31:48")) }
        else {
            let expected = id.hasPrefix("027") ? "2026-11-09T09:31:48.250Z" : "2026-11-09T09:31:48Z"
            #expect(portable.meetingTime.instant == MeetingTime.parse(expected))
        }
    }
}
