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
        var names = DraftNames(labels: ["a": "Alex"], live: ["b": .init(voices[0].id, 0.8, .suggested)],
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

    // ports: TranscribingLifecycleTest#stoppingAndResumingPreserveTheLiveSheetAndHeldAwayDraft (draft retention side)
    @Test func checkpointDraftPersistsThroughStopPauseQueueAndPreTranscriptionPhases() async {
        let note = Note(title: "Resume draft")
        let fake = FakeNoteScreen(note: note)
        fake.job = Job(noteID: note.id, seq: 1, kind: .transcribe, state: .running, doneMs: 11_000, totalMs: 20_000,
                       enqueuedAt: .distantPast)
        fake.runningDraft = DraftState(words: words, tentativeFromMs: .max, namingOpen: true)
        let model = NoteScreenModel(noteID: note.id, ports: fake.ports)
        #expect(model.shownDraft?.words.map(\.text) == ["Later", "First"])

        // Transition to Paused: even before async loadSavedDraft completes, retained checkpoint words bridge the frame.
        fake.runningDraft = nil
        fake.draftNamingOpen = false
        fake.draft = words
        fake.job = Job(noteID: note.id, seq: 1, kind: .transcribe, state: .paused, doneMs: 11_000, totalMs: 20_000,
                       enqueuedAt: .distantPast)
        #expect(model.shownDraft?.words.map(\.text) == ["Later", "First"])
        #expect(model.shownDraft?.namingOpen == false)
        await model.loadSavedDraft()
        #expect(model.shownDraft?.words.map(\.text) == ["Later", "First"])

        // Queued and pre-inference Running phases keep the checkpoint draft visible.
        for state: JobState in [.queued, .running] {
            fake.job = Job(noteID: note.id, seq: 1, kind: .transcribe, state: state, doneMs: 11_000, totalMs: 20_000,
                           enqueuedAt: .distantPast)
            await model.loadSavedDraft()
            #expect(model.shownDraft?.words.map(\.text) == ["Later", "First"])
        }

        // Finishing clears the draft immediately.
        fake.job = nil
        #expect(model.shownDraft == nil)
    }

    @Test func runningJobWithLiveDraftDoesNotReloadSavedDraftAcrossCheckpoints() async {
        let note = Note(title: "Live checkpoints")
        let fake = FakeNoteScreen(note: note)
        fake.draft = words
        fake.job = Job(noteID: note.id, seq: 1, kind: .transcribe, state: .paused, doneMs: 5_000, totalMs: 60_000,
                       enqueuedAt: .distantPast)
        let model = NoteScreenModel(noteID: note.id, ports: fake.ports)
        let pausedKey = model.savedDraftKey
        await model.loadSavedDraft()
        #expect(fake.calls == ["savedDraft"])
        #expect(model.savedDraft == words)

        fake.runningDraft = DraftState(words: words, tentativeFromMs: .max, namingOpen: true)
        fake.job = Job(noteID: note.id, seq: 1, kind: .transcribe, state: .running, doneMs: 5_000,
                       totalMs: 60_000, enqueuedAt: .distantPast)
        let runningKey = model.savedDraftKey
        #expect(runningKey != pausedKey)
        let callsBeforeRunning = fake.calls.count

        for step in 1...10 {
            fake.job = Job(noteID: note.id, seq: 1, kind: .transcribe, state: .running,
                           doneMs: Int64(step) * 5_000, totalMs: 60_000, enqueuedAt: .distantPast)
            #expect(model.savedDraftKey == runningKey)
            await model.loadSavedDraft()
            #expect(model.savedDraft == words)
        }
        #expect(fake.calls[callsBeforeRunning...].filter { $0 == "savedDraft" }.isEmpty)

        // Pausing at a new checkpoint changes savedDraftKey and reloads once runningDraft clears.
        fake.runningDraft = nil
        fake.job = Job(noteID: note.id, seq: 1, kind: .transcribe, state: .paused, doneMs: 50_000,
                       totalMs: 60_000, enqueuedAt: .distantPast)
        #expect(model.savedDraftKey != runningKey)
        #expect(model.savedDraftKey != pausedKey)
    }

    @Test func jobProgressRetainsLastLiveProgressAndDraftWhileStopping() throws {
        let id = UUID()
        let progress = JobProgress(uptimeMs: { 2_000 })
        progress.begin(id, finalizationMs: nil)
        progress.apply(.started(JobStart(totalMs: 60_000, speakers: true, prints: true)), receivedAt: 0)
        progress.apply(.windowDone(doneMs: 30_000, totalMs: 60_000, words: words), receivedAt: 1_000)
        progress.refresh()
        guard case .transcribing(let running, let draft)? = progress.phase(for: id) else {
            Issue.record("Expected live transcribing phase, got \(String(describing: progress.phase(for: id)))")
            return
        }
        progress.apply(.stopping, receivedAt: 2_500)
        #expect(progress.phase(for: id) == .stopping(StoppingProgress(progress: running, draft: draft)))
        progress.refresh()
        #expect(progress.phase(for: id) == .stopping(StoppingProgress(progress: running, draft: draft)))
    }

    private func received(_ expected: DraftNames, by model: NoteScreenModel) async throws {
        for await value in ObservedValues({ model.draftNames }) {
            try Task.checkCancellation()
            if value == expected { return }
        }
        throw CancellationError()
    }
}
