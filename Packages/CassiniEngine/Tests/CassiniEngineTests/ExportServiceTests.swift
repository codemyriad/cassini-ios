import CassiniCore
import Foundation
import CassiniEngineTesting
import Testing
@testable import CassiniEngine
@testable import CassiniNotebook

struct ExportServiceTests {
    private let base: URL
    private let notes: NoteStore
    private let service: ExportService
    private let texts = ExportTexts(subtitle: { _, _, _ in "8 Oct 2026, 15:10" }, emptyText: "No words", unassignedLabel: "Unknown speaker")

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-export-\(UUID().uuidString)", isDirectory: true)
        notes = try NoteStore(root: base.appendingPathComponent("Notes", isDirectory: true))
        service = ExportService(notes: notes, folder: base.appendingPathComponent("tmp/Exports", isDirectory: true))
    }

    private func transcribedNote() -> Note {
        var note = Note(title: "Delivery: Thursday?", audioFilename: "audio.m4a")
        note.duration = 9.25; note.status = .ready
        note.speakers = [NoteSpeaker(id: "S1", name: "Giulia"), NoteSpeaker(id: "S2", name: "Speaker 2")]
        note.transcript = [
            TranscriptSegment(text: "So, is the delivery late?", start: 0, end: 1.5, speakerID: "S1", words: [
                .init(text: "So,", start: 0, end: 0.3), .init(text: "the", start: 0.4, end: 0.7),
                .init(text: "delivery", start: 0.8, end: 1.1), .init(text: "slips?", start: 1.2, end: 1.5)]),
            TranscriptSegment(text: "Yes, on Thursday.", start: 1.8, end: 2.9, speakerID: "S2", words: [
                .init(text: "Yes,", start: 1.8, end: 2.1), .init(text: "a", start: 2.2, end: 2.5), .init(text: "Thursday.", start: 2.6, end: 2.9)])
        ]
        return note
    }

    @Test(arguments: [NoteStatus.audioOnly, .queued, .transcribing, .failed])
    func singleAudioOnlyCassiniFileHasAnEmptyTimedTranscript(status: NoteStatus) async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var note = Note(title: "First run"); note.status = status
        let source = base.appendingPathComponent("source.m4a")
        try Data(ImportFixtures.m4a).write(to: source)
        let output = try await PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance(), unassignedLabel: "Unknown speaker")
            .export(ExportSheetState.portableSnapshot(note), original: source, playable: source, into: base, filename: "audio-only")
        let document = CassiniDocument.read(output)
        #expect(document.state == .ok)
        let transcript = try #require(document.selected()?.transcript)
        #expect(transcript.words.isEmpty)
    }

    @Test(arguments: [NoteStatus.queued, .transcribing, .failed])
    func archiveKeepsStoredTranscriptWhileAnotherTranscriptionIsQueuedOrFailed(status: NoteStatus) async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var note = transcribedNote(); note.status = status
        if status == .failed { note.failure = .audio }
        let source = base.appendingPathComponent("source.m4a"), original = Data(ImportFixtures.m4a)
        try original.write(to: source)
        let portable = PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance(), unassignedLabel: "Unknown speaker")
        let output = try await BulkExportService(folder: base.appendingPathComponent("exports")) { snapshot, work in
            try await portable.archiveSnapshot(snapshot, original: source, playable: source, into: work)
        }.export([note])
        let zip = try ZIPArchive(url: output)
        let entry = try #require(zip.entries.first)
        #expect(entry.name.hasSuffix(".opus"))
        var bytes = Data(); try zip.read(entry, remainingBytes: 1_000_000) { bytes.append($0) }
        let document = CassiniDocument.read(Array(bytes))
        #expect(document.state == .ok)
        #expect(document.selected()?.transcript?.words == PortableTranscript.words(of: note))
        #expect(try Data(contentsOf: source) == original)
    }

    @Test(arguments: [NoteStatus.queued, .transcribing, .failed], [false, true])
    func singleCassiniKeepsFinishedEditsAndVersions(status: NoteStatus, imported: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent(imported ? "source.opus" : "source.m4a")
        var note = transcribedNote()
        if imported {
            try Data(ImportFixtures.document("Imported finished words", title: note.title)).write(to: source)
            let document = try #require(PortableTranscript(CassiniDocument.read(source)))
            note.document = document.info; note.origin = .importedDocument
            note.transcript = document.segments; note.versions = document.versions
            note.selectedVersionID = document.selectedVersionID; note.speakers = document.speakers
        } else {
            try Data(ImportFixtures.m4a).write(to: source)
            note.saveCurrentVersion(.transcription)
        }
        let originalWords = imported ? "Imported finished words" : PortableTranscript.words(of: note).map(\.text).joined(separator: " ")
        note.transcript = [.init(text: "Hand edited finished words", start: 0, end: 2, speakerID: "S1")]
        note.saveCurrentVersion(.editedTranscript)
        note.status = status
        #expect(!ExportSheetState(note: note, jobPending: true).audioOnly)
        #expect(ExportSheetState.portableSnapshot(note) == note)
        let output = try await PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance(), unassignedLabel: "Unknown speaker")
            .export(ExportSheetState.portableSnapshot(note), original: source, playable: source, into: base, filename: "finished")
        let document = CassiniDocument.read(output)
        #expect(document.state == .ok)
        #expect(document.selected()?.transcript?.words == PortableTranscript.words(of: note))
        #expect(Set(document.variants.compactMap { $0.transcript?.words.map(\.text).joined(separator: " ") }) == [originalWords, "Hand edited finished words"])
        try await notes.save(note)
        let text = try await service.exportTranscript(note.id, format: .text, texts: texts)
        #expect(try String(contentsOf: text, encoding: .utf8).contains("Hand edited finished words"))
    }

    @Test(arguments: [NoteStatus.ready, .queued, .transcribing, .failed])
    func noSpeechCompletionStillExportsAnEmptyTranscript(status: NoteStatus) async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        var note = Note(title: "No speech")
        note.status = status
        if status != .ready { note.versions = [.init(kind: .transcription, segments: [], speakers: [])] }
        try await notes.save(note)
        let source = notes.originalAudioURL(for: note)
        try Data(ImportFixtures.m4a).write(to: source)
        #expect(!ExportSheetState(note: note, jobPending: true).audioOnly)
        _ = try await service.exportTranscript(note.id, format: .text, texts: texts)
        let portable = PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance(), unassignedLabel: "Unknown speaker")
        let single = try await portable.export(note, original: source, playable: source, into: base, filename: "single")
        let archive = try await portable.archiveSnapshot(note, original: source, playable: source, into: base)
        for output in [single, archive] {
            let document = CassiniDocument.read(output)
            #expect(document.state == .ok)
            #expect(document.selected()?.transcript?.words.isEmpty == true)
        }
    }

    @Test(arguments: [DocumentState.invalidMetadata, .unreadable])
    func archivePreservesTheNonOKOriginalWithoutResigningLocalWords(state: DocumentState) async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let bytes = try ImportFixtures.document("Old words", title: "Old title")
        let comments = CassiniDocument.read(bytes).comments.map { $0.hasPrefix("CASSINI_PROFILE=") ? "CASSINI_PROFILE=other" : $0 }
        let broken = Data(try OggOpus.mux(OggOpus.read(bytes), tags: CassiniDocument.tagsPacket(comments)))
        let original = base.appendingPathComponent("broken.opus")
        try broken.write(to: original)
        #expect(CassiniDocument.read(original).state == .invalidMetadata)
        var note = Note(title: "Edited local title", audioFilename: "broken.opus")
        note.document = DocumentInfo(state: state)
        note.origin = .importedDocument
        note.transcript = [.init(text: "Edited local words", start: 0, end: 1, speakerID: "a")]
        note.speakers = [.init(id: "a", name: "Edited speaker")]
        note.saveCurrentVersion(.editedTranscript)
        let output = try await PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance(), unassignedLabel: "Unknown speaker")
            .archiveSnapshot(note, original: original, playable: original, into: base)
        let document = CassiniDocument.read(output)
        #expect(try Data(contentsOf: output) == broken, "Local words cannot authenticate a non-OK original")
        #expect(document.state == .invalidMetadata)
        #expect(document.comments == CassiniDocument.read(original).comments)
        #expect(note.title == "Edited local title")
        #expect(note.transcript.map(\.text) == ["Edited local words"], "The on-device transcript stays available")
        #expect(note.speakers?.first?.name == "Edited speaker")
        #expect(note.versions?.first?.segments == note.transcript)
        #expect(try Data(contentsOf: original) == broken)
    }

    @Test func archiveCopiesRenamedZeroWordDocumentWithoutSealing() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let bytes = Data(try CassiniDocument.create(ImportFixtures.opus(packets: 100), transcript: Transcript([]),
                                                  title: "Original title", processing: JSONObject()))
        let original = base.appendingPathComponent("empty.opus")
        try bytes.write(to: original)
        #expect(CassiniDocument.read(original).state == .ok)
        var note = Note(title: "Renamed title", audioFilename: "empty.opus")
        note.document = DocumentInfo(state: .ok)
        note.origin = .importedDocument
        let output = try await PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance(), unassignedLabel: "Unknown speaker")
            .archiveSnapshot(note, original: original, playable: original, into: base)
        #expect(try Data(contentsOf: output) == bytes)
        #expect(try Data(contentsOf: original) == bytes)
    }

    @Test func archiveUsesLastLocalVersionAfterANoSpeechResult() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let original = base.appendingPathComponent("source.m4a")
        let bytes = Data(ImportFixtures.m4a)
        try bytes.write(to: original)
        var note = Note(title: "No speech on the latest pass", audioFilename: "source.m4a")
        note.versions = [TranscriptVersion(kind: .transcription, segments: [.init(text: "Earlier local", start: 0, end: 1)], speakers: []),
                         TranscriptVersion(kind: .editedTranscript, segments: [.init(text: "Latest local", start: 0, end: 1, speakerID: "a")],
                                           speakers: [.init(id: "a", name: "Ada")], language: "fr")]
        #expect(note.transcript.isEmpty && note.selectedVersionID == nil)
        let output = try await PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance(), unassignedLabel: "Unknown speaker")
            .archiveSnapshot(note, original: original, playable: original, into: base)
        let document = CassiniDocument.read(output)
        #expect(document.state == .ok)
        #expect(document.selected()?.transcript?.words.map(\.text) == ["Latest", "local"])
        #expect(document.selected()?.transcript?.language == "fr")
        #expect(document.speakerLabel("a") == "Ada")
        #expect(Set(document.variants.compactMap { $0.transcript?.words.map(\.text).joined(separator: " ") }) == ["Earlier local", "Latest local"])
        #expect(try Data(contentsOf: original) == bytes)
    }

    @Test func archiveCopiesRenamedImportedEmptyDefaultWithEarlierWords() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let first = try ImportFixtures.document("Earlier imported words", title: "Original")
        let bytes = Data(try CassiniDocument.create(first, transcript: Transcript([]), title: "Original", processing: JSONObject(), existing: CassiniDocument.read(first)))
        let original = base.appendingPathComponent("empty-default.opus")
        try bytes.write(to: original)
        let document = CassiniDocument.read(original)
        #expect(document.state == .ok && document.variants.count == 2)
        #expect(document.selected()?.transcript?.words.isEmpty == true)
        let imported = try #require(PortableTranscript(document))
        var note = Note(title: "Renamed imported document", audioFilename: "empty-default.opus")
        note.document = DocumentInfo(state: .ok); note.origin = .importedDocument
        note.versions = imported.versions; note.selectedVersionID = imported.selectedVersionID
        note.speakers = imported.speakers; note.language = imported.language
        #expect(imported.segments.isEmpty)
        #expect(note.versions?.contains { !$0.segments.isEmpty } == true)
        let output = try await PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance(), unassignedLabel: "Unknown speaker")
            .archiveSnapshot(note, original: original, playable: original, into: base)
        #expect(try Data(contentsOf: output) == bytes)
    }

    @Test func archiveSnapshotRoundTripsUserSetDateForAudioOnlyMeeting() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let source = base.appendingPathComponent("source.m4a")
        let original = Data(ImportFixtures.m4a)
        try original.write(to: source)

        let cet = try #require(TimeZone(secondsFromGMT: 3600))
        let chosen = try #require(CassiniDocument.parseInstant("2026-11-23T13:36:00Z"))
        var note = Note(title: "Audio only dated", audioFilename: "source.m4a")
        note.status = .audioOnly
        SetMeetingDate.apply(date: chosen, timeZone: cet, to: &note)

        let portable = PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance(), unassignedLabel: "Unknown speaker")
        let zipURL = try await BulkExportService(folder: base.appendingPathComponent("exports")) { snapshot, work in
            try await portable.archiveSnapshot(snapshot, original: source, playable: source, into: work)
        }.export([note])

        let zip = try ZIPArchive(url: zipURL)
        let entry = try #require(zip.entries.first)
        #expect(entry.name.hasSuffix(".opus"))
        var bytes = Data(); try zip.read(entry, remainingBytes: 1_000_000) { bytes.append($0) }
        #expect(bytes != original)
        let document = CassiniDocument.read(Array(bytes))
        #expect(document.state == .ok)
        let restored = try #require(PortableTranscript(document))
        #expect(restored.meetingTime == .instant(chosen))
        #expect(restored.userStartedAt == "2026-11-23T14:36:00+01:00")
    }

    @Test func archiveSnapshotRoundTripsUserSetDateForImportedEmptyTranscriptDocument() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let originalDate = try #require(CassiniDocument.parseInstant("2026-11-20T10:00:00Z"))
        let originalBytes = Data(try CassiniDocument.create(
            ImportFixtures.opus(packets: 100),
            transcript: Transcript([]),
            title: "Empty imported",
            processing: JSONObject(),
            recordedAt: originalDate
        ))
        let original = base.appendingPathComponent("empty.opus")
        try originalBytes.write(to: original)
        let imported = try #require(PortableTranscript(CassiniDocument.read(original)))
        #expect(imported.segments.isEmpty)

        var note = ImportedNote.make(
            id: UUID(), displayName: nil, fallbackTitle: "Import", sha256: "hash",
            importedAt: originalDate,
            audio: ImportedAudio(filename: "empty.opus", originalFilename: "empty.opus", duration: 1),
            document: imported
        )
        let cet = try #require(TimeZone(secondsFromGMT: 3600))
        let chosen = try #require(CassiniDocument.parseInstant("2026-11-23T13:36:00Z"))
        SetMeetingDate.apply(date: chosen, timeZone: cet, to: &note)

        let portable = PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance(), unassignedLabel: "Unknown speaker")
        let zipURL = try await BulkExportService(folder: base.appendingPathComponent("exports")) { snapshot, work in
            try await portable.archiveSnapshot(snapshot, original: original, playable: original, into: work)
        }.export([note])

        let zip = try ZIPArchive(url: zipURL)
        let entry = try #require(zip.entries.first)
        #expect(entry.name.hasSuffix(".opus"))
        var archivedBytes = Data(); try zip.read(entry, remainingBytes: 1_000_000) { archivedBytes.append($0) }
        #expect(archivedBytes != originalBytes)
        let document = CassiniDocument.read(Array(archivedBytes))
        #expect(document.state == .ok)
        let restored = try #require(PortableTranscript(document))
        #expect(restored.meetingTime == .instant(chosen))
        #expect(restored.userStartedAt == "2026-11-23T14:36:00+01:00")

        // A clean re-import of that dated empty document still deduplicates by copying original bytes.
        let datedURL = base.appendingPathComponent("dated.opus")
        try archivedBytes.write(to: datedURL)
        let cleanNote = ImportedNote.make(
            id: UUID(), displayName: nil, fallbackTitle: "Import", sha256: "hash2",
            importedAt: originalDate,
            audio: ImportedAudio(filename: "dated.opus", originalFilename: "dated.opus", duration: 1),
            document: restored
        )
        let dedupDir = base.appendingPathComponent("dedup", isDirectory: true)
        try FileManager.default.createDirectory(at: dedupDir, withIntermediateDirectories: true)
        let dedupOutput = try await portable.archiveSnapshot(cleanNote, original: datedURL, playable: datedURL, into: dedupDir)
        #expect(try Data(contentsOf: dedupOutput) == archivedBytes)
    }

    // ports: DocumentRepositoryTest#exportsEqualTheExpectedBytes
    @Test func exportsEqualTheExpectedBytes() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let note = transcribedNote()
        try await notes.save(note)
        try Data([7, 8, 9]).write(to: notes.originalAudioURL(for: note))
        let copy = try await service.copyAudio(note.id)
        #expect(copy.lastPathComponent == "Delivery_ Thursday_.m4a")
        #expect(try Data(contentsOf: copy) == Data([7, 8, 9]))
        await service.discard(copy).value
        let cases: [(TranscriptFormat, String)] = [
            (.text, "Giulia · 00:00:00\nSo, the delivery slips?\n\nSpeaker 2 · 00:00:01\nYes, a Thursday.\n"),
            (.subtitles, "1\n00:00:00,000 --> 00:00:01,500\nGiulia: So, the delivery slips?\n\n2\n00:00:01,800 --> 00:00:02,900\nSpeaker 2: Yes, a Thursday.\n"),
            (.webVTT, "WEBVTT\n\n00:00:00.000 --> 00:00:01.500\n<v Giulia>So, the delivery slips?</v>\n\n00:00:01.800 --> 00:00:02.900\n<v Speaker 2>Yes, a Thursday.</v>\n")
        ]
        for (format, text) in cases {
            let url = try await service.exportTranscript(note.id, format: format, texts: texts)
            #expect(url.lastPathComponent == "Delivery_ Thursday_.\(format.fileExtension)")
            #expect(try Data(contentsOf: url) == Data(text.utf8), "\(format)")
            await service.discard(url).value
            #expect(!FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
        }
        #expect(!FileManager.default.fileExists(atPath: service.folder.path), "tmp/Exports is cleaned")
    }

    // ports: DocumentRepositoryTest#aPlainNoteExportsItsAudioButNoTranscript
    @Test func aPlainNoteExportsItsAudioButNoTranscript() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let note = Note(title: "Solo audio", audioFilename: "source.mp3")
        try await notes.save(note)
        let audio = notes.originalAudioURL(for: note)
        try Data([1, 2, 3]).write(to: audio)
        let copy = try await service.copyAudio(note.id)
        #expect(copy.lastPathComponent == "Solo audio.mp3")
        #expect(try Data(contentsOf: copy) == Data([1, 2, 3]))
        #expect(copy != audio, "the note's own file is never shared in place")
        await service.discard(copy).value
        #expect(FileManager.default.fileExists(atPath: audio.path))

        await #expect(throws: ExportError.notAvailable(.afterTranscription)) {
            try await service.exportTranscript(note.id, format: .text, texts: texts)
        }
        await service.discard(audio).value
        #expect(try Data(contentsOf: audio) == Data([1, 2, 3]), "discard never touches a note's own files")
        #expect(!FileManager.default.fileExists(atPath: service.folder.path))
    }

    @Test func unreadableDocumentsAndMissingNotesOrVersionsExportNothing() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        var note = transcribedNote()
        note.document = DocumentInfo(state: .unknownFormat)
        try await notes.save(note)
        await #expect(throws: ExportError.notAvailable(.notReadable)) {
            try await service.exportTranscript(note.id, format: .subtitles, texts: texts)
        }
        await #expect(throws: ExportError.noNote) { try await service.exportTranscript(UUID(), format: .text, texts: texts) }
        let readable = transcribedNote()
        try await notes.save(readable)
        await #expect(throws: ExportError.noNote) {
            try await service.exportTranscript(readable.id, format: .text, version: UUID(), texts: texts)
        }
    }

    @Test func aVersionExportsItsOwnTranscript() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        var note = transcribedNote()
        let older = TranscriptVersion(kind: .previous, segments: [TranscriptSegment(text: "Prima", start: 0, end: 1, speakerID: "S1")],
                                      speakers: [NoteSpeaker(id: "S1", name: "Giulia")])
        note.versions = [older]
        try await notes.save(note)
        let url = try await service.exportTranscript(note.id, format: .subtitles, version: older.id, texts: texts)
        #expect(try String(contentsOf: url, encoding: .utf8) == "1\n00:00:00,000 --> 00:00:01,000\nGiulia: Prima\n")
    }

    @Test func theSweepKeepsEveryNoteAndClearsWaitingExports() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let note = transcribedNote()
        try await notes.save(note)
        let url = try await service.exportTranscript(note.id, format: .text, texts: texts)
        let report = await service.sweep(now: Date().addingTimeInterval(2 * 60 * 60))
        #expect(report.deleted.map(\.lastPathComponent) == ["Exports"])
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: notes.directory(for: note.id).path))
    }

    @Test func theSweepAfterLoadingRemovesAnOrphanFolderAndKeepsADamagedNote() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let files = FileManager.default
        let orphan = notes.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: orphan.appendingPathComponent("source.tmp"))
        let damaged = notes.root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: damaged, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: damaged.appendingPathComponent("note.json"))
        try Data("partial".utf8).write(to: damaged.appendingPathComponent("note.json.tmp"))
        let report = try await notes.load()
        #expect(report.unreadable.count == 2, "both folders load as unreadable")

        let swept = await service.sweep(now: Date().addingTimeInterval(2 * 60 * 60))

        #expect(!files.fileExists(atPath: orphan.path), "a folder with nothing but stale temporary files goes")
        #expect(files.fileExists(atPath: damaged.appendingPathComponent("note.json").path), "a damaged note stays")
        #expect(!files.fileExists(atPath: damaged.appendingPathComponent("note.json.tmp").path))
        #expect(swept.deleted.map(\.lastPathComponent).contains(orphan.lastPathComponent))
    }

    @Test func discardingAnExportKeepsAnotherExportsFolder() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let note = transcribedNote()
        try await notes.save(note)
        let first = try await service.exportTranscript(note.id, format: .text, texts: texts)
        let second = try service.newFolder()
        await service.discard(first).value
        await service.discard(first).value
        #expect(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: second.path), "an export still being made keeps its folder")
        await service.discardFolder(second).value
        #expect(!FileManager.default.fileExists(atPath: service.folder.path))
    }
}
