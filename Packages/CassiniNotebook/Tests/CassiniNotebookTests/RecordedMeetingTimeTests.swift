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
        else { #expect(portable.meetingTime.instant == MeetingTime.parse("2026-11-09T09:31:48Z")) }
    }
}
