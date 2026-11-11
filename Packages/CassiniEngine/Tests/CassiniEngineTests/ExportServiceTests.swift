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
        let words = [Word("S1", 0, 300, "So,"), Word("S1", 400, 700, "the"), Word("S1", 800, 1100, "delivery"),
                     Word("S1", 1200, 1500, "slips?"), Word("S2", 1800, 2100, "Yes,"), Word("S2", 2200, 2500, "a"),
                     Word("S2", 2600, 2900, "Thursday.")]
        let expected = ExportTranscript(title: "Delivery: Thursday?", durationMs: 9_250, words: words,
                                        labels: ["S1": "Giulia", "S2": "Speaker 2"])
        let cases: [(TranscriptFormat, String)] = [
            (.text, TextExport.write(expected, subtitle: "8 Oct 2026, 15:10", emptyText: "No words")),
            (.subtitles, SrtWriter.write(expected)),
            (.webVTT, VttWriter.write(expected))
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
        #expect(try String(contentsOf: url, encoding: .utf8) == "1\n00:00:00,000 --> 00:00:01,000\nPrima\n")
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
