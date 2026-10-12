import CassiniCore
import Foundation
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
        var note = Note(title: "Consegna: giovedì?", audioFilename: "audio.m4a")
        note.duration = 9.25; note.status = .ready
        note.speakers = [NoteSpeaker(id: "S1", name: "Giulia"), NoteSpeaker(id: "S2", name: "Speaker 2")]
        note.transcript = [
            TranscriptSegment(text: "Allora, la consegna slitta?", start: 0, end: 1.5, speakerID: "S1", words: [
                .init(text: "Allora,", start: 0, end: 0.3), .init(text: "la", start: 0.4, end: 0.7),
                .init(text: "consegna", start: 0.8, end: 1.1), .init(text: "slitta?", start: 1.2, end: 1.5)]),
            TranscriptSegment(text: "Sì, a giovedì.", start: 1.8, end: 2.9, speakerID: "S2", words: [
                .init(text: "Sì,", start: 1.8, end: 2.1), .init(text: "a", start: 2.2, end: 2.5), .init(text: "giovedì.", start: 2.6, end: 2.9)])
        ]
        return note
    }

    // ports: DocumentRepositoryTest#exportsEqualTheExpectedBytes
    @Test func exportsEqualTheExpectedBytes() async throws {
        defer { try? FileManager.default.removeItem(at: base) }
        let note = transcribedNote()
        try await notes.save(note)
        let words = [Word("S1", 0, 300, "Allora,"), Word("S1", 400, 700, "la"), Word("S1", 800, 1100, "consegna"),
                     Word("S1", 1200, 1500, "slitta?"), Word("S2", 1800, 2100, "Sì,"), Word("S2", 2200, 2500, "a"),
                     Word("S2", 2600, 2900, "giovedì.")]
        let expected = ExportTranscript(title: "Consegna: giovedì?", durationMs: 9_250, words: words,
                                        labels: ["S1": "Giulia", "S2": "Speaker 2"])
        let cases: [(TranscriptFormat, String)] = [
            (.text, TextExport.write(expected, subtitle: "8 Oct 2026, 15:10", emptyText: "No words")),
            (.subtitles, SrtWriter.write(expected)),
            (.webVTT, VttWriter.write(expected))
        ]
        for (format, text) in cases {
            let url = try await service.exportTranscript(note.id, format: format, texts: texts)
            #expect(url.lastPathComponent == "Consegna_ giovedì_.\(format.fileExtension)")
            #expect(try Data(contentsOf: url) == Data(text.utf8), "\(format)")
            service.discard(url)
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

        await #expect(throws: ExportError.notAvailable(.afterTranscription)) {
            try await service.exportTranscript(note.id, format: .text, texts: texts)
        }
        service.discard(audio)
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
        let older = TranscriptVersion(name: "Before", segments: [TranscriptSegment(text: "Prima", start: 0, end: 1, speakerID: "S1")],
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
        service.discard(first)
        service.discard(first)
        #expect(!FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: second.path), "an export still being made keeps its folder")
        service.discardFolder(second)
        #expect(!FileManager.default.fileExists(atPath: service.folder.path))
    }
}
