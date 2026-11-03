import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
@testable import Cassini

/// Notification taps open their note, also on a cold start, and Resume goes on transcribing.
@MainActor @Suite struct DeepLinkHandlingTests {
    private func seed(_ test: TestGraph, title: String = "Plain") throws -> Note {
        var note = Note(title: title, audioFilename: "audio.caf")
        note.duration = 2
        let repository = try NoteRepository(root: test.root)
        try repository.save(note)
        try Data().write(to: repository.audioURL(for: note))
        return note
    }

    /// Up to 30 s by the clock (E1): 500 sleeps of 10 ms ran out after 5 s, or less, on a busy host. The test checks
    /// the outcome itself.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(30)
        while !condition() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aNotificationTapOpensTheNoteOnAColdStart() async throws {
        let test = TestGraph()
        defer { test.tearDown() }
        let note = try seed(test)
        let responder = NotificationResponder()
        // The tap arrives before the app has a handler, and before the launch work has read the notes.
        responder.receive(.note(note.id))
        responder.handler = { test.graph.handle($0) }
        await test.graph.start()
        await waitUntil { test.graph.router.path == [.note(note.id)] }
        #expect(test.graph.router.path == [.note(note.id)])
    }

    @Test func aNoteLinkPopsToTheNoteOrPushesItAndClosesRecording() async throws {
        let test = TestGraph()
        defer { test.tearDown() }
        let first = try seed(test, title: "First"), second = try seed(test, title: "Second")
        await test.graph.start()
        let router = test.graph.router
        router.path = [.note(first.id), .settings]
        router.presentRecording()
        await DeepLinkHandler(router: router, library: test.graph.library, processing: test.graph.processing,
                              recording: test.graph.recording, ready: {}).handle(.note(first.id))
        #expect(router.path == [.note(first.id)])
        #expect(router.fullScreen == nil)
        await DeepLinkHandler(router: router, library: test.graph.library, processing: test.graph.processing,
                              recording: test.graph.recording, ready: {}).handle(.note(second.id))
        #expect(router.path == [.note(first.id), .note(second.id)])
        await DeepLinkHandler(router: router, library: test.graph.library, processing: test.graph.processing,
                              recording: test.graph.recording, ready: {}).handle(.note(UUID()))
        #expect(router.path == [.note(first.id), .note(second.id)], "a note that is gone opens nothing")
    }

    @Test func resumeFromTheNotificationGoesOnFromTheSavedProgressWithTheJobsKind() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.frozen(done: 1.5, total: 2)))
        defer { test.tearDown() }
        let note = try seed(test)
        let graph = test.graph
        graph.settings.recordConsent()
        graph.settings.identifySpeakers = false
        let language = graph.settings.speechLanguage
        // iOS took the background time back from a Transcribe again after its first second.
        let audio = test.root.appendingPathComponent(note.id.uuidString).appendingPathComponent("audio.caf")
        let checkpoints = CheckpointFiles(noteDirectory: { [root = test.root] in root.appendingPathComponent($0.uuidString) })
        try checkpoints.save(CheckpointState(source: "audio.caf", signature: CheckpointState.signature(of: audio), model: CheckpointState.appleModel(language: language),
                                             segments: [TranscriptSegment(text: "Hello", start: 0, end: 0.8,
                                                                          words: [.init(text: "Hello", start: 0, end: 0.8)])],
                                             doneMs: 1_000, totalMs: 2_000, elapsedMs: 1_000), for: note.id)
        try JobRepository(root: test.root).save([
            Job(noteID: note.id, seq: 1, kind: .transcribeAgain, state: .paused, pauseReason: .system, doneMs: 1_000,
                totalMs: 2_000, language: language, enqueuedAt: test.clock.now),
        ])
        await graph.start()
        #expect(graph.processing.state.jobs[note.id]?.state == .paused)

        await DeepLinkHandler(router: graph.router, library: graph.library, processing: graph.processing,
                              recording: graph.recording, ready: {}).handle(.note(note.id, resume: true))
        #expect(graph.router.path == [.note(note.id)])
        await waitUntil { draft(graph.processing.progress.phase(for: note.id)) == ["Hello"] }
        #expect(draft(graph.processing.progress.phase(for: note.id)) == ["Hello"], "it goes on from the saved words")
        #expect(graph.processing.state.jobs[note.id]?.kind == .transcribeAgain, "Resume keeps the job's kind")
        graph.processing.stopAll()
        await graph.processing.coordinator?.awaitIdle()
    }

    @Test func resumeOfANoteThatIsNoLongerPausedOnlyOpensIt() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.returns([TranscriptSegment(text: "Hello.", start: 0, end: 1)], total: 2)))
        defer { test.tearDown() }
        let note = try seed(test)
        test.graph.settings.recordConsent()
        test.graph.settings.identifySpeakers = false
        await test.graph.start()
        // An old "Transcription paused" notification: its job was resumed from the screen and finished since.
        await DeepLinkHandler(router: test.graph.router, library: test.graph.library, processing: test.graph.processing,
                              recording: test.graph.recording, ready: {}).handle(.note(note.id, resume: true))
        #expect(test.graph.router.path == [.note(note.id)])
        await settle(test.graph)
        #expect(test.graph.processing.state.jobs[note.id] == nil, "Resume queues nothing for a note with no paused job")
        #expect(test.graph.library.note(note.id)?.transcript.isEmpty == true)
    }

    @Test func theLiveActivityLinkOpensTheRecording() {
        #expect(DeepLinks.parse(url: RecordingLink.url) == .recording)
    }

    /// Lets work that should not happen show itself before a check that it did not (E1: states, not 50 ms): the
    /// main actor's queued tasks run to their first wait, then the queue drains.
    private func settle(_ graph: AppGraph) async {
        for _ in 0..<10 { await Task.yield() }
        await graph.processing.coordinator?.awaitIdle()
    }

    private func draft(_ phase: JobPhase?) -> [String]? {
        guard case .transcribing(_, let draft) = phase else { return nil }
        return draft.words.map(\.text)
    }

    @Test func theFirstTranscribeFromTheScreenAsksToNotifyOnce() async throws {
        let test = TestGraph()
        defer { test.tearDown() }
        let note = try seed(test)
        test.graph.settings.recordConsent()
        await test.graph.start()
        await test.graph.processing.transcribe(note.id, origin: .automatic)
        #expect(test.notifier.requestCount == 0, "an automatic start asks nothing")
        await test.graph.processing.transcribe(note.id)
        await waitUntil { test.notifier.requestCount == 1 }
        await test.graph.processing.transcribe(note.id)
        await settle(test.graph)
        #expect(test.notifier.requestCount == 1)
        #expect(test.graph.settings.notificationsAsked)
    }
}
