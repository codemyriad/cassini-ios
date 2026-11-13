import CassiniCore
import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

struct DraftColourPersistenceTests {
    private func render(_ draft: DraftState) -> NoteTranscript {
        NoteTranscripts.draft(draft.words, tentativeFromMs: nil, labels: draft.labels,
                              automatic: draft.automatic, suggestions: draft.suggestions,
                              colourIndices: draft.colourIndices, provenance: draft.provenance)
    }

    @Test func exhaustedForeignDraftSlotContinuesAcrossBatchesAndFreshStoreReloads() throws {
        let maximum = 9_007_199_254_740_991
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString).appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = DraftNamesStore(root: root) { _ in folder }
        store.mutate(id) { _ in DraftNames(colourIndices: ["old": maximum]) }
        let old = DraftWord(speaker: "old", startMs: 0, endMs: 100, text: "First")
        let a = DraftWord(speaker: "a", startMs: 200, endMs: 300, text: "Second")
        let b = DraftWord(speaker: "b", startMs: 400, endMs: 500, text: "Third")
        store.observe(.windowDone(doneMs: 300, totalMs: 1000, words: [old, a]), noteID: id)
        let fresh = DraftNamesStore(root: root) { _ in folder }
        #expect(fresh.current(id).colourIndices == ["old": maximum, "a": 0])
        fresh.observe(.draft(words: [old, a, b], tentativeFromMs: 500), noteID: id)
        let final = DraftNamesStore(root: root) { _ in folder }.current(id)
        #expect(final.colourIndices == ["old": maximum, "a": 0, "b": 1])
        #expect(Set(final.colourIndices.values).count == final.colourIndices.count)
        #expect(final.colourIndices.values.allSatisfy { (0...maximum).contains($0) })
        #expect(try JSONDecoder().decode(DraftNames.self, from: final.encoded()) == final)
    }

    @Test func wordEventsReserveSlotsBeforeMergeAndReloadWithoutRecolouringOtherSpeakers() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID()
        let folder = root.appendingPathComponent(id.uuidString).appendingPathComponent("work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = DraftNamesStore(root: root) { _ in folder }
        let words = [DraftWord(speaker: "a", startMs: 0, endMs: 200, text: "First"),
                     DraftWord(speaker: "b", startMs: 300, endMs: 500, text: "Second"),
                     DraftWord(speaker: "c", startMs: 600, endMs: 800, text: "Third")]
        store.observe(.windowDone(doneMs: 800, totalMs: 1000, words: words), noteID: id)
        store.mutate(id) { $0.rename("a", "Alice").rename("b", "Speaker 2").rename("c", "Chris") }
        let original = DraftView.build(.init(words: words, tentativeFromMs: .max), names: store.current(id), voiceNames: [:])
        #expect(render(original).speakerTints == ["a": .blue, "b": .magenta, "c": .cyan])
        try store.mutate(id) { try $0.merge("a", into: "b") }
        let restarted = DraftNamesStore(root: root) { _ in folder }
        let names = restarted.current(id)
        #expect(names.colourIndices == ["a": 0, "b": 1, "c": 2])
        #expect(names.explicitNames.contains("b"))
        let merged = DraftView.build(.init(words: words, tentativeFromMs: .max), names: names, voiceNames: [:])
        #expect(render(merged).speakerTints == ["b": .magenta, "c": .cyan])
        #expect(merged.provenance["b"] == .user)
        let earlierNewWord = DraftWord(speaker: "d", startMs: 100, endMs: 150, text: "New")
        restarted.observe(.draft(words: words + [earlierNewWord], tentativeFromMs: 0), noteID: id)
        #expect(restarted.current(id).colourIndices == ["a": 0, "b": 1, "c": 2, "d": 3])
        #expect(restarted.current(id).forgettingEveryone(generation: 1).colourIndices == restarted.current(id).colourIndices)
        let legacy = DraftNames(labels: ["b": "Speaker 2"])
        let legacyView = DraftView.build(.init(words: words, tentativeFromMs: .max), names: legacy, voiceNames: [:])
        #expect(render(legacyView).speakerTints["b"] == .stone)
    }

    @MainActor @Test func theActualSealingProducerKeepsMergedDraftSlotsThroughNoteReloadAndPortableExport() async throws {
        let h = VoicesHarness()
        defer { h.tearDown() }
        await h.start()
        var note = Note(title: "Merged draft")
        note.transcript = [.init(text: "First", start: 0, end: 0.2, speakerID: "a"),
                           .init(text: "Second", start: 0.3, end: 0.5, speakerID: "b"),
                           .init(text: "Third", start: 0.6, end: 0.8, speakerID: "c")]
        try await h.library.insert(note)
        let noteStore = try #require(h.library.noteStore)
        let store = DraftNamesStore(notes: noteStore)
        let raw = note.transcript.flatMap(\.draftWords)
        store.observe(.windowDone(doneMs: 800, totalMs: 1000, words: raw), noteID: note.id)
        try store.mutate(note.id) { try $0.rename("b", "Speaker 2").rename("c", "Chris").merge("a", into: "b") }
        let names = DraftNamesStore(notes: noteStore).current(note.id)
        let merged = DraftView.build(.init(words: raw, tentativeFromMs: .max), names: names, voiceNames: [:])
        let attributed = TranscriptSegment.segments(of: merged.words.map { Word($0.speaker, $0.startMs, $0.endMs, $0.text) })
        let turns = attributed.map { SpeakerTurn(speakerID: $0.speakerID!, start: $0.start, end: $0.end) }
        try await h.voices.applySpeakerAnalysis(.init(turns: turns, prints: [], transcript: attributed, names: names),
                                               to: note.id, generation: h.settings.voicesGeneration)
        let sealed = try #require(h.library.note(note.id))
        #expect(sealed.speaker("b")?.colourIndex == 1 && sealed.speaker("b")?.provenance == .user)
        #expect(sealed.speaker("c")?.colourIndex == 2)
        let reloaded = try JSONDecoder().decode(Note.self, from: JSONEncoder().encode(sealed))
        #expect(NoteTranscripts.sealed(reloaded).speakerTints == ["b": .magenta, "c": .cyan])
        let audio = h.root.appendingPathComponent("audio.opus"), output = h.root.appendingPathComponent("export.opus")
        let head = Array("OpusHead".utf8) + [1, 1, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 0]
        let tags = CassiniDocument.tagsPacket([])
        let stream = OggOpus.Stream(head: head, tags: tags, audio: Array(repeating: [0xF8, 0xFF, 0xFE], count: 50), finalGranule: 48_000, validFraming: true)
        try Data(OggOpus.mux(stream, tags: tags)).write(to: audio)
        try PortableTranscript.export(note: reloaded, opus: audio, destination: output, unassignedLabel: "Unknown speaker")
        let imported = try #require(PortableTranscript.read(from: output))
        #expect(imported.speakers.map(\.colourIndex) == [1, 2])
        #expect(imported.speakers.first?.provenance == .user)
    }
}
