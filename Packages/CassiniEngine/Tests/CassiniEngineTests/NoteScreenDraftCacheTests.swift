import Foundation
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

@MainActor @Suite(.timeLimit(.minutes(1))) struct NoteScreenDraftCacheTests {
    private var words: [DraftWord] {
        [.init(speaker: "a", startMs: 10_000, endMs: 11_000, text: "Later"),
         .init(speaker: "b", startMs: 0, endMs: 1_000, text: "First")]
    }

    @Test func shownDraftReusesItsMappingAndInvalidatesEveryObservedInput() async throws {
        let note = Note(title: "Draft cache")
        let fake = FakeNoteScreen(note: note)
        fake.runningDraft = DraftState(words: words, tentativeFromMs: .max, namingOpen: true)
        var voices = [SavedVoice(name: "Blair", samples: [])]
        var names = DraftNames(labels: ["a": "Alex"], live: ["b": .init(voice: voices[0].id, score: 0.8, state: .suggested)],
                               colourIndices: ["a": 8, "b": 3])
        let (changes, sink) = AsyncStream<DraftNames>.makeStream()
        var ports = fake.ports
        ports.savedVoices = { voices }
        ports.draftNames = { _ in changes }
        let model = NoteScreenModel(noteID: note.id, ports: ports)
        model.appeared(start: nil)
        defer { model.disappeared(); sink.finish() }
        sink.yield(names)
        try await received(names, by: model)
        #expect(model.shownDraft?.suggestions.first?.name == "Blair")
        #expect(model.shownDraftBuilds == 1)
        for _ in 0..<20 { _ = model.shownDraft }
        #expect(model.shownDraftBuilds == 1, "body reads reuse the actual mapped draft")

        names = names.rename("a", "Ada")
        sink.yield(names)
        try await received(names, by: model)
        #expect(model.shownDraft?.labels["a"] == "Ada")
        #expect(model.shownDraftBuilds == 2)
        voices[0].name = "Blair renamed"
        #expect(model.shownDraft?.suggestions.first?.name == "Blair renamed")
        #expect(model.shownDraftBuilds == 3)
        fake.runningDraft?.namingOpen = false
        #expect(model.shownDraft?.suggestions.isEmpty == true)
        #expect(model.shownDraftBuilds == 4)
        fake.runningDraft?.words[0].text = "Edited"
        #expect(model.shownDraft?.words[0].text == "Edited")
        #expect(model.shownDraftBuilds == 5)

        let restored = fake.runningDraft
        fake.runningDraft = nil
        #expect(model.shownDraft == nil)
        fake.runningDraft = restored
        _ = model.shownDraft
        #expect(model.shownDraftBuilds == 6, "no-draft clears the retained mapping")
    }

    @Test func savedLegacyDraftFallbackIsCachedAndLanguageAndOpenStateInvalidateIt() async {
        let note = Note(title: "Legacy draft")
        let fake = FakeNoteScreen(note: note)
        fake.job = Job(noteID: note.id, seq: 1, kind: .transcribe, state: .paused, enqueuedAt: .distantPast)
        fake.draft = words
        let model = NoteScreenModel(noteID: note.id, ports: fake.ports)
        await model.loadSavedDraft()
        let first = model.shownDraft
        #expect(first?.colourIndices == ["a": 1, "b": 0])
        for _ in 0..<20 { #expect(model.shownDraft == first) }
        #expect(model.shownDraftBuilds == 1)
        fake.draftNamingOpen = false
        #expect(model.shownDraft?.namingOpen == false)
        #expect(model.shownDraftBuilds == 2)
        let alternate = DefaultLabels.appLanguage == "fr" ? "it" : "fr"
        _ = model.shownDraft(language: alternate)
        #expect(model.shownDraftBuilds == 3)
        _ = model.shownDraft(language: alternate)
        #expect(model.shownDraftBuilds == 3)
        _ = model.shownDraft
        #expect(model.shownDraftBuilds == 4)
    }

    private func received(_ expected: DraftNames, by model: NoteScreenModel) async throws {
        for await value in ObservedValues({ model.draftNames }) {
            try Task.checkCancellation()
            if value == expected { return }
        }
        throw CancellationError()
    }
}
