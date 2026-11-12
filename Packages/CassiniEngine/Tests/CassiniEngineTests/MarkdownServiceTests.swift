import CassiniCore
import Foundation
import Testing
@testable import CassiniEngine
@testable import CassiniNotebook

/// The real export service reads portable personal notes, not local bookmarks or unrelated private data.
struct MarkdownServiceTests {
    private let root: URL
    private let notes: NoteStore
    private let service: ExportService
    private let texts: ExportTexts

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-markdown-\(UUID().uuidString)")
        notes = try NoteStore(root: root.appendingPathComponent("Notes"))
        service = ExportService(notes: notes, folder: root.appendingPathComponent("Exports"))
        let copy = MarkdownCopy(speakersLine: "Speakers: {names}", transcriptHeading: "Transcript",
            notesHeading: "Notes", overLine: "(over {names})", speakerList: { names in
                names.count < 2 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + names.last!
            })
        texts = ExportTexts(subtitle: { _, _, _ in "Unused TXT subtitle" }, emptyText: "No words",
            unassignedLabel: "Unknown speaker", markdown: MarkdownOptions(copy: copy,
                dateLine: { _, _ in "Tuesday 27 October 2026, 09:00" }, untitled: "Untitled meeting",
                unnamedSpeaker: { "Speaker \($0)" }))
    }

    @Test func importedPersonalNotesExcludeBookmarksAndOtherNamespacesAndKeepSourceBytes() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let privateData = #"{"gocassini.com":{"notes":[{"atMs":2000,"text":"Later *decision*","future":true},{"atMs":0,"text":"First point"},{"atMs":0,"text":"Second point"},{"atMs":1.5,"text":"Invalid fraction"},{"atMs":-1,"text":"Invalid negative"},{"atMs":true,"text":"Invalid boolean"},{"atMs":3,"text":42}]},"example.com":{"notes":[{"atMs":0,"text":"Foreign note"}]},"codemyriad.io":{"notes":[{"atMs":0,"text":"Other namespace"}]}}"#
        let source = Data(try ImportFixtures.documentWithPrivateData(privateData, title: "Imported planning"))
        let portable = try #require(PortableTranscript(CassiniDocument.read(Array(source))))
        var note = ImportedNote.make(id: UUID(), displayName: "source.opus", fallbackTitle: "Imported meeting",
            sha256: "unused-test-digest", importedAt: Date(timeIntervalSince1970: 1_793_088_000),
            audio: ImportedAudio(filename: "playback.caf", originalFilename: "source.opus", duration: ImportFixtures.duration),
            document: portable)
        note.bookmarks = [Bookmark(time: 1, label: "Local bookmark must stay private")]
        try await notes.save(note)
        let original = notes.originalAudioURL(for: note)
        try source.write(to: original)
        // Reading the decoded playback file would fail: metadata belongs to the original portable document.
        try Data("English playback placeholder".utf8).write(to: notes.audioURL(for: note))
        let noteJSON = notes.directory(for: note.id).appendingPathComponent("note.json")
        let storedJSON = try Data(contentsOf: noteJSON)

        let output = try await service.exportTranscript(note.id, format: .markdown, texts: texts)
        let markdown = try String(contentsOf: output, encoding: .utf8)
        #expect(output.lastPathComponent == "Imported planning.md")
        #expect(markdown.contains("second version"), "Export the selected imported variant")
        #expect(!markdown.contains("first version"))
        #expect(markdown.hasSuffix("## Notes\n\n- 00:00:00 First point\n- 00:00:00 Second point\n- 00:00:02 Later \\*decision\\*\n"))
        for excluded in ["Foreign note", "Other namespace", "Local bookmark", "Invalid fraction", "Invalid negative", "Invalid boolean"] {
            #expect(!markdown.contains(excluded), "\(excluded)")
        }
        #expect(try Data(contentsOf: original) == source, "Export never rewrites imported audio/manifest/private fields")
        #expect(try Data(contentsOf: noteJSON) == storedJSON)
        let stored = await notes.note(note.id)
        #expect(stored == note)
        await service.discard(output).value
        #expect(!FileManager.default.fileExists(atPath: output.path))
        #expect(try Data(contentsOf: original) == source)
    }

    @Test func requestedVersionKeepsItsSpeakerLabelsAndAudioBoundedTimingFlag() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var note = Note(title: "Current meeting")
        note.duration = 6; note.status = .ready
        note.transcript = [TranscriptSegment(text: "Wait.", start: 0, end: 5, speakerID: "ada"),
                           TranscriptSegment(text: "Yes", start: 2, end: 2.4, speakerID: "ben"),
                           TranscriptSegment(text: "now", start: 5, end: 5.2, speakerID: "ada")]
        note.speakers = [NoteSpeaker(id: "ada", name: "Current Ada"), NoteSpeaker(id: "ben", name: "Current Ben")]
        let bounded = note.transcript.map { segment in
            var copy = segment
            copy.wordEndsBoundedByAudio = true
            return copy
        }
        let earlier = TranscriptVersion(kind: .previous, segments: bounded,
            speakers: [NoteSpeaker(id: "ada", name: "Earlier Ada"), NoteSpeaker(id: "ben", name: "Earlier Ben")])
        note.versions = [earlier]
        try await notes.save(note)

        let current = try await service.exportTranscript(note.id, format: .markdown, texts: texts)
        let requested = try await service.exportTranscript(note.id, format: .markdown, version: earlier.id, texts: texts)
        let currentText = try String(contentsOf: current, encoding: .utf8)
        let requestedText = try String(contentsOf: requested, encoding: .utf8)
        #expect(currentText.hasPrefix("# Current meeting\n"))
        #expect(requestedText.hasPrefix("# Current meeting\n"), "Title is the note's, not a stale variant title")
        #expect(currentText.contains("Speakers: Current Ada, Current Ben\n"))
        #expect(!currentText.contains("(over "), "Legacy inflated punctuation is repaired")
        #expect(requestedText.contains("Speakers: Earlier Ada, Earlier Ben\n"))
        #expect(requestedText.contains("(over Earlier Ben)"), "The requested variant's authoritative ends bypass repair")
        #expect(requestedText.contains("(over Earlier Ada)"))
        #expect(!requestedText.contains("Current Ada"))
        #expect(current != requested, "Each export gets its own folder")
        let stored = await notes.note(note.id)
        #expect(stored == note, "Export does not select or change a version")
    }

    @Test func importedUnassignedLabelAndRenameWinOverEnglishFallback() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = Data(try CassiniDocument.create(ImportFixtures.opus(),
            transcript: Transcript([Word("unassigned", 0, 400, "Hello")], language: "it"),
            title: "Stored label", processing: JSONObject(), speakerLabels: ["unassigned": "Voce sconosciuta"]))
        var note = try await importForMarkdown(source)
        let earlier = TranscriptVersion(kind: .previous, segments: note.transcript, speakers: note.speakers ?? [])
        note.versions = (note.versions ?? []) + [earlier]
        for label in ["Voce sconosciuta", "Mira"] {
            if label == "Mira" { note.renameSpeaker("unassigned", name: label) }
            try await notes.save(note)
            let stored = try Data(contentsOf: notes.directory(for: note.id).appendingPathComponent("note.json"))
            let output = try await service.exportTranscript(note.id, format: .markdown, texts: texts)
            let text = try String(contentsOf: output, encoding: .utf8)
            #expect(text.contains("Speakers: \(label)\n"))
            #expect(text.contains("**\(label)** · 00:00:00\nHello\n"))
            #expect(!text.contains("Unknown speaker"))
            #expect(try Data(contentsOf: notes.originalAudioURL(for: note)) == source)
            #expect(try Data(contentsOf: notes.directory(for: note.id).appendingPathComponent("note.json")) == stored)
            #expect(await notes.note(note.id) == note)
            await service.discard(output).value
        }
        let output = try await service.exportTranscript(note.id, format: .markdown, version: earlier.id, texts: texts)
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.contains("Speakers: Voce sconosciuta\n"), "The requested version keeps its own stored label")
        #expect(!text.contains("Mira"))
    }

    @Test func storedTranscriptAndPersonalNotesExportWithOpaqueSourceWordPayloads() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try ImportFixtures.documentWithPrivateData()
        let note = try await importForMarkdown(Data(source))
        let original = CassiniDocument.read(source)
        let comments = original.comments.map { comment in
            let name = comment.prefix { $0 != "=" }
            return name.hasPrefix("CASSINI_TX_") && name.hasSuffix("_PAYLOAD_000") ? "\(name)=not-base64url!" : comment
        }
        let opaque = Data(try OggOpus.mux(OggOpus.read(source), tags: CassiniDocument.tagsPacket(comments)))
        let file = notes.originalAudioURL(for: note)
        try opaque.write(to: file)
        let metadata = CassiniDocument.readMetadataChecked(file)
        #expect(metadata.manifest == original.manifest)
        #expect(metadata.variants.allSatisfy { $0.body == nil && $0.transcript == nil && $0.error == nil })
        let output = try await service.exportTranscript(note.id, format: .markdown, texts: texts)
        let text = try String(contentsOf: output, encoding: .utf8)
        #expect(text.contains("second version"), "Words come from the stored selected transcript, not the source payload")
        #expect(text.contains("Budget next week"), "Only the manifest supplies portable personal notes")
        #expect(await notes.note(note.id) == note, "Header-only export does not change stored trust")
        #expect(try Data(contentsOf: file) == opaque)
    }

    private func importForMarkdown(_ source: Data) async throws -> Note {
        let portable = try #require(PortableTranscript(CassiniDocument.read(Array(source))))
        let note = ImportedNote.make(id: UUID(), displayName: "source.opus", fallbackTitle: "Imported meeting",
            sha256: "unused-test-digest", importedAt: Date(timeIntervalSince1970: 1_793_088_000),
            audio: ImportedAudio(filename: "playback.caf", originalFilename: "source.opus", duration: ImportFixtures.duration),
            document: portable)
        try await notes.save(note)
        try source.write(to: notes.originalAudioURL(for: note))
        return note
    }

    @Test func markdownUsesS5FilenameAndDisplayFallbackWithoutChangingOtherFormats() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var note = Note(title: " A/B\\C ")
        note.status = .ready; note.duration = 4
        note.transcript = [TranscriptSegment(text: "First", start: 0, end: 1, speakerID: "raw-id"),
                           TranscriptSegment(text: "Second", start: 1, end: 2, speakerID: "missing"),
                           TranscriptSegment(text: "Third", start: 2, end: 3, speakerID: "stored")]
        note.speakers = [NoteSpeaker(id: "raw-id", name: "raw-id"), NoteSpeaker(id: "stored", name: "Voce 7")]
        try await notes.save(note)
        let markdown = try await service.exportTranscript(note.id, format: .markdown, texts: texts)
        let text = try String(contentsOf: markdown, encoding: .utf8)
        #expect(markdown.lastPathComponent == "A-B-C.md")
        #expect(text.contains("Speakers: Speaker 1, Speaker 2, Voce 7\n"), "Missing labels resolve as displayed; stored labels stay verbatim")
        let plain = try await service.exportTranscript(note.id, format: .text, texts: texts)
        #expect(plain.lastPathComponent == "A_B_C.txt", "Existing format filename rules stay unchanged")

        var untitled = note
        untitled.id = UUID(); untitled.title = "  "
        try await notes.save(untitled)
        let fallback = try await service.exportTranscript(untitled.id, format: .markdown, texts: texts)
        #expect(fallback.lastPathComponent == "Untitled meeting.md")
        var emoji = note
        emoji.id = UUID(); emoji.title = String(repeating: "😀", count: 121)
        try await notes.save(emoji)
        let limited = try await service.exportTranscript(emoji.id, format: .markdown, texts: texts)
        #expect(limited.lastPathComponent == String(repeating: "😀", count: 57) + ".md")
    }
}
