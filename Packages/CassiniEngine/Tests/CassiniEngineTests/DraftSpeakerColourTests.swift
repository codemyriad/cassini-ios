import Foundation
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

@MainActor struct DraftSpeakerColourTests {
    @Test func namingAndMergeUseFirstSpeechSlotsInsteadOfDisplayOrdinals() async throws {
        let note = Note(title: "Planning notes", audioFilename: "audio.m4a")
        let fake = FakeNoteScreen(note: note)
        fake.runningDraft = DraftState(words: [
            DraftWord(speaker: "late", startMs: 10_000, endMs: 10_500, text: "Later"),
            DraftWord(speaker: "early", startMs: 0, endMs: 500, text: "First")
        ], tentativeFromMs: .max, namingOpen: true)
        let model = NoteScreenModel(noteID: note.id, ports: fake.ports)
        var input = try #require(await model.draftInput("late"))
        #expect(input.ordinal == 0)
        #expect(input.colourIndex == 1)
        #expect(input.mergeTargets.first { $0.speakerID == "early" }?.colourIndex == 0)
        #expect(input.provenance == .unnamed)
        #expect(input.speakerTints["late"] == .stone)
        // A naming result carries explicit provenance as well as its label.
        input.label = "Alex"
        input.provenance = .user
        #expect(input.speakerTints["late"] == .magenta)
        #expect(fake.runningDraft?.words.map(\.speaker) == ["late", "early"], "Presentation order is untouched")
    }
}
