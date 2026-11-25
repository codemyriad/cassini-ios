import Foundation
import Testing
import CassiniCore
@testable import CassiniNotebook

struct SetMeetingDateTests {
    private let utc = TimeZone(secondsFromGMT: 0)!
    private let cet = TimeZone(secondsFromGMT: 3600)!
    private let est = TimeZone(secondsFromGMT: -5 * 3600)!

    private func gregorian(_ zone: TimeZone) -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone
        return cal
    }

    @Test func prefillUsesKnownInstantWithoutHint() throws {
        let recorded = try #require(CassiniDocument.parseInstant("2026-11-20T10:15:00Z"))
        let now = try #require(CassiniDocument.parseInstant("2026-11-25T12:00:00Z"))
        var note = Note(title: "Sync", createdAt: now)
        note.meetingTime = .instant(recorded)
        note.sourceModifiedAt = now.addingTimeInterval(-3600)
        note.duration = 1800

        let prefill = SetMeetingDatePrefill.of(note: note, now: now, calendar: gregorian(utc))
        #expect(prefill.date == recorded)
        #expect(!prefill.showsSavedFileHint)
    }

    @Test func prefillUsesLocalWallClockWithoutHint() throws {
        let now = try #require(CassiniDocument.parseInstant("2026-11-25T12:00:00Z"))
        var note = Note(title: "Local", createdAt: now)
        note.meetingTime = .local("2026-11-09T09:31:48")
        note.sourceModifiedAt = now

        let cal = gregorian(cet)
        let prefill = SetMeetingDatePrefill.of(note: note, now: now, calendar: cal)
        let expected = try #require(cal.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 9, minute: 31, second: 48)))
        #expect(prefill.date == expected)
        #expect(!prefill.showsSavedFileHint)
    }

    @Test func prefillUsesGregorianForLocalWallClockOnBuddhistCalendar() throws {
        let now = try #require(CassiniDocument.parseInstant("2026-11-25T12:00:00Z"))
        var note = Note(title: "Bangkok local", createdAt: now)
        note.meetingTime = .local("2026-11-09T09:31:48")

        let bangkok = try #require(TimeZone(secondsFromGMT: 7 * 3600))
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = bangkok

        let prefill = SetMeetingDatePrefill.of(note: note, now: now, calendar: buddhist)
        let expected = try #require(CassiniDocument.parseInstant("2026-11-09T02:31:48Z"))
        #expect(prefill.date == expected)
        #expect(!prefill.showsSavedFileHint)

        SetMeetingDate.apply(date: prefill.date, timeZone: bangkok, to: &note)
        #expect(note.meetingTime == .instant(expected))
        #expect(note.userStartedAt == "2026-11-09T09:31:48+07:00")
    }

    @Test func prefillUsesSavedFileTimeMinusDurationWithHint() throws {
        let saved = try #require(CassiniDocument.parseInstant("2026-11-23T14:12:00Z"))
        let now = try #require(CassiniDocument.parseInstant("2026-11-25T12:00:00Z"))
        var note = Note(title: "Incontro ORA", createdAt: now)
        note.meetingTime = .unknown
        note.sourceModifiedAt = saved
        note.duration = 36 * 60 // 36 minutes

        let prefill = SetMeetingDatePrefill.of(note: note, now: now, calendar: gregorian(cet))
        let expected = try #require(CassiniDocument.parseInstant("2026-11-23T13:36:00Z"))
        #expect(prefill.date == expected)
        #expect(prefill.showsSavedFileHint)
    }

    @Test func prefillFallsBackToCurrentTimeWithoutHint() throws {
        let now = try #require(CassiniDocument.parseInstant("2026-11-25T12:00:00Z"))
        var note = Note(title: "No mtime", createdAt: now)
        note.meetingTime = .unknown
        note.sourceModifiedAt = nil

        let prefill = SetMeetingDatePrefill.of(note: note, now: now, calendar: gregorian(utc))
        #expect(prefill.date == now)
        #expect(!prefill.showsSavedFileHint)
    }

    @Test func startedAtFormattingAndValidationMatchSchema() throws {
        let instant = try #require(CassiniDocument.parseInstant("2026-11-23T13:36:00.789Z"))
        let cetFormatted = SetMeetingDate.formatStartedAt(instant, timeZone: cet)
        #expect(cetFormatted == "2026-11-23T14:36:00+01:00")
        #expect(CassiniDocument.isValidStartedAt(cetFormatted))
        #expect(CassiniDocument.localPart(of: cetFormatted) == "2026-11-23T14:36:00")

        let estFormatted = SetMeetingDate.formatStartedAt(instant, timeZone: est)
        #expect(estFormatted == "2026-11-23T08:36:00-05:00")
        #expect(CassiniDocument.isValidStartedAt(estFormatted))

        let utcFormatted = SetMeetingDate.formatStartedAt(instant, timeZone: utc)
        #expect(utcFormatted == "2026-11-23T13:36:00+00:00")
        #expect(CassiniDocument.isValidStartedAt(utcFormatted))

        // Schema rejections: -00:00, fractional seconds, out-of-range offsets, impossible dates
        #expect(!CassiniDocument.isValidStartedAt("2026-11-23T14:36:00-00:00"))
        #expect(!CassiniDocument.isValidStartedAt("2026-11-23T14:36:00.500+01:00"))
        #expect(!CassiniDocument.isValidStartedAt("2026-11-23T14:36:00+14:30"))
        #expect(!CassiniDocument.isValidStartedAt("2026-11-23T14:36:00-12:30"))
        #expect(!CassiniDocument.isValidStartedAt("2026-02-29T12:00:00Z"))
        #expect(CassiniDocument.isValidStartedAt("2026-11-23T14:36:00Z"))
        #expect(CassiniDocument.isValidStartedAt("2026-11-23T14:36:00+14:00"))
        #expect(CassiniDocument.isValidStartedAt("2026-11-23T14:36:00-12:00"))
    }

    @Test func userSetDateRoundTripsThroughOpusExportAndReimport() throws {
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let opus = folder.appendingPathComponent("source.opus")
        try Data(PortableFixtures.silence()).write(to: opus)

        let importedAt = try #require(CassiniDocument.parseInstant("2026-11-24T08:15:00Z"))
        var note = ImportedNote.make(
            id: UUID(), displayName: "recorder-clip.opus", fallbackTitle: "Import",
            sha256: "abc", importedAt: importedAt,
            audio: ImportedAudio(filename: "playback.caf", originalFilename: "source.opus", duration: 2172)
        )
        note.transcript = [TranscriptSegment(text: "Hello world", start: 0, end: 1)]
        #expect(note.meetingTime == .unknown)

        let chosen = try #require(CassiniDocument.parseInstant("2026-11-23T13:36:00Z"))
        SetMeetingDate.apply(date: chosen, timeZone: cet, to: &note)
        #expect(note.meetingTime == .instant(chosen))
        #expect(note.userStartedAt == "2026-11-23T14:36:00+01:00")
        #expect(note.createdAt == importedAt)
        #expect(note.audioFilename == "playback.caf")
        #expect(note.originalAudioFilename == "source.opus")

        let exported = folder.appendingPathComponent("exported.opus")
        try PortableTranscript.export(note: note, opus: opus, destination: exported, unassignedLabel: "Unknown speaker")
        let doc = CassiniDocument.readChecked(exported)
        #expect(doc.state == .ok)
        let meeting = try #require(doc.manifest?["meeting"]?.object)
        #expect(meeting["startedAt"]?.string == "2026-11-23T14:36:00+01:00")
        #expect(meeting["recordedAtLocal"]?.string == "2026-11-23T14:36:00")
        #expect(doc.comments.contains("DATE=2026-11-23T14:36:00+01:00"))

        let xMeeting = try #require(doc.manifest?["x"]?.object?["codemyriad.io"]?.object?["meeting"]?.object)
        #expect(xMeeting["startedAt"]?.string == "2026-11-23T14:36:00+01:00")
        #expect(xMeeting["startedAtSource"]?.string == "user")

        let portable = try #require(PortableTranscript.read(from: exported))
        #expect(portable.meetingTime == .instant(chosen))
        #expect(portable.userStartedAt == "2026-11-23T14:36:00+01:00")
    }

    @Test func legacyImportTimePrefixIgnoresSynthesizedDateUnlessUserSet() throws {
        let synthesized = "2026-11-24T09:15:00+01:00"
        let manifestWithImportTime = JSONObject([
            ("meeting", .object(JSONObject([
                ("createdAtUtc", .string("2026-11-24T08:15:00Z")),
                ("startedAt", .string(synthesized)),
                ("recordedAtLocal", .string("2026-11-24T09:15:00")),
            ]))),
            ("x", .object(JSONObject([
                ("codemyriad.io", .object(JSONObject([
                    ("namePrefixSource", .string("import-time")),
                    ("meeting", .object(JSONObject())),
                ]))),
            ]))),
        ])
        let legacyDoc = CassiniDocument(state: .ok, manifest: manifestWithImportTime, comments: ["DATE=\(synthesized)"])
        #expect(MeetingTime.read(legacyDoc) == .unknown)
        #expect(MeetingTime.readUserStartedAt(legacyDoc) == nil)

        // Now add user-set startedAt + startedAtSource: "user": it wins over import-time.
        let userSet = "2026-11-23T14:36:00+01:00"
        let manifestWithUserSet = JSONObject([
            ("meeting", .object(JSONObject([
                ("createdAtUtc", .string("2026-11-24T08:15:00Z")),
                ("startedAt", .string(userSet)),
                ("recordedAtLocal", .string("2026-11-23T14:36:00")),
            ]))),
            ("x", .object(JSONObject([
                ("codemyriad.io", .object(JSONObject([
                    ("namePrefixSource", .string("import-time")),
                    ("meeting", .object(JSONObject([
                        ("startedAt", .string(userSet)),
                        ("startedAtSource", .string("user")),
                    ]))),
                ]))),
            ]))),
        ])
        let userDoc = CassiniDocument(state: .ok, manifest: manifestWithUserSet, comments: ["DATE=\(userSet)"])
        let expected = try #require(CassiniDocument.parseInstant(userSet))
        #expect(MeetingTime.read(userDoc) == .instant(expected))
        #expect(MeetingTime.readUserStartedAt(userDoc) == userSet)
    }

    @Test func changingDateOnImportedDocumentMarksArchiveDirty() throws {
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let originalDate = try #require(CassiniDocument.parseInstant("2026-11-20T10:00:00Z"))
        let bytes = try CassiniDocument.create(
            PortableFixtures.silence(),
            transcript: Transcript([Word("a", 0, 500, "Hello")], language: "en"),
            title: "Imported meeting",
            processing: JSONObject(),
            recordedAt: originalDate
        )
        let portable = try #require(PortableTranscript(CassiniDocument.read(bytes)))
        var note = ImportedNote.make(
            id: UUID(), displayName: nil, fallbackTitle: "Import", sha256: "hash",
            importedAt: originalDate, audio: ImportedAudio(filename: "playback.caf", originalFilename: "document.opus", duration: 1),
            document: portable
        )
        #expect(ArchiveContents.matchesImportedDocument(note, portable))

        let newDate = try #require(CassiniDocument.parseInstant("2026-11-22T15:30:00Z"))
        SetMeetingDate.apply(date: newDate, timeZone: cet, to: &note)
        #expect(!ArchiveContents.matchesImportedDocument(note, portable))

        // Re-exporting updates the portable document to the new date.
        let srcURL = folder.appendingPathComponent("src.opus")
        let dstURL = folder.appendingPathComponent("dst.opus")
        try Data(bytes).write(to: srcURL)
        try PortableTranscript.export(note: note, opus: srcURL, destination: dstURL, unassignedLabel: "Unknown speaker")
        let updated = try #require(PortableTranscript.read(from: dstURL))
        #expect(updated.meetingTime == .instant(newDate))
        #expect(updated.userStartedAt == "2026-11-22T16:30:00+01:00")
    }

    @Test func noteOverlayAndMenuActionAllowSetDateTimeEvenWhenReadOnly() {
        var state = NoteScreenState()
        let note = Note(title: "Test")
        #expect(state.menu(.setDateTime, note: note, job: nil, readOnly: .jobPending) == .setDateTime)
        #expect(NoteSheet(opening: .setDateTime, in: note) == .setDateTime)
        #expect(NoteOverlay.setDateTime.restorable(over: note, readOnly: .jobPending) == .setDateTime)
    }

    @Test func noteCodableRoundTripsUserStartedAtAndSourceModifiedAt() throws {
        let modified = try #require(CassiniDocument.parseInstant("2026-11-23T14:12:00Z"))
        let chosen = try #require(CassiniDocument.parseInstant("2026-11-23T13:36:00Z"))
        var note = Note(title: "Gadget clip", createdAt: modified)
        note.sourceModifiedAt = modified
        SetMeetingDate.apply(date: chosen, timeZone: cet, to: &note)

        let data = try JSONEncoder().encode(note)
        let decoded = try JSONDecoder().decode(Note.self, from: data)
        #expect(decoded.meetingTime == .instant(chosen))
        #expect(decoded.userStartedAt == "2026-11-23T14:36:00+01:00")
        #expect(decoded.sourceModifiedAt == modified)
    }

    @Test func userSetDateInvalidatesPreservesOriginalForPlainAudioAndVerifiedDocuments() throws {
        let chosen = try #require(CassiniDocument.parseInstant("2026-11-23T13:36:00Z"))

        var audioOnly = Note(title: "Audio only")
        #expect(ArchiveContents.preservesOriginal(audioOnly))
        SetMeetingDate.apply(date: chosen, timeZone: cet, to: &audioOnly)
        #expect(!ArchiveContents.preservesOriginal(audioOnly))

        var verifiedEmpty = Note(title: "Empty verified", audioFilename: "empty.opus")
        verifiedEmpty.document = DocumentInfo(state: .ok)
        verifiedEmpty.origin = .importedDocument
        #expect(ArchiveContents.preservesOriginal(verifiedEmpty))
        SetMeetingDate.apply(date: chosen, timeZone: cet, to: &verifiedEmpty)
        #expect(!ArchiveContents.preservesOriginal(verifiedEmpty))

        // Non-OK documents and unplayable audio still preserve original bytes.
        var unknownDoc = Note(title: "Newer format", audioFilename: "future.opus")
        unknownDoc.document = DocumentInfo(state: .unknownFormat)
        SetMeetingDate.apply(date: chosen, timeZone: cet, to: &unknownDoc)
        #expect(ArchiveContents.preservesOriginal(unknownDoc))

        var invalidDoc = Note(title: "Invalid", audioFilename: "broken.opus")
        invalidDoc.document = DocumentInfo(state: .invalidMetadata)
        SetMeetingDate.apply(date: chosen, timeZone: cet, to: &invalidDoc)
        #expect(ArchiveContents.preservesOriginal(invalidDoc))
    }
}
