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

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
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

    @Test func resumeFromTheNotificationTranscribesAgain() async throws {
        let test = TestGraph(transcriber: FakeTranscriber(.returns([TranscriptSegment(text: "Hello.", start: 0, end: 1)], total: 2)))
        defer { test.tearDown() }
        let note = try seed(test)
        test.graph.settings.downloadsAllowed = true
        test.graph.settings.identifySpeakers = false
        await test.graph.start()
        await DeepLinkHandler(router: test.graph.router, library: test.graph.library, processing: test.graph.processing,
                              recording: test.graph.recording, ready: {}).handle(.note(note.id, resume: true))
        #expect(test.graph.router.path == [.note(note.id)])
        await test.graph.processing.coordinator?.awaitIdle()
        await waitUntil { test.graph.library.note(note.id)?.transcript.isEmpty == false }
        #expect(test.graph.library.note(note.id)?.transcript.map(\.text) == ["Hello."])
    }

    @Test func theFirstTranscribeFromTheScreenAsksToNotifyOnce() async throws {
        let test = TestGraph()
        defer { test.tearDown() }
        let note = try seed(test)
        test.graph.settings.downloadsAllowed = true
        await test.graph.start()
        await test.graph.processing.transcribe(note.id, origin: .automatic)
        #expect(test.notifier.requestCount == 0, "an automatic start asks nothing")
        await test.graph.processing.transcribe(note.id)
        await waitUntil { test.notifier.requestCount == 1 }
        await test.graph.processing.transcribe(note.id)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(test.notifier.requestCount == 1)
        #expect(test.graph.settings.notificationsAsked)
    }
}
