import XCTest
import CassiniNotebook
import CassiniEngine
import CassiniEngineTesting
@testable import Cassini

/// The proposal of docs/ios18.md over the app's composition: on the iOS 18 facts, coming back to the screen resumes a
/// transcription the end of the background time paused, from its checkpoint; on the iOS 26 facts it waits for Resume.
@MainActor final class ActivationResumeTests: XCTestCase {

    func testOnIOS18ComingBackResumesTheSystemPauseFromItsCheckpoint() async throws {
        let test = TestGraph(transcriber: Runs(), platform: .iOS18)
        defer { test.tearDown() }
        let (note, saved) = try await pausedBySystem(test)

        await test.graph.becameActive().value
        XCTAssertNil(test.graph.settings.queueHold)
        await test.graph.processing.coordinator?.awaitIdle()
        await waitUntil { test.graph.library.note(note.id)?.status == .ready }
        let done = try XCTUnwrap(test.graph.library.note(note.id))
        XCTAssertEqual(done.transcript.flatMap(\.words).map(\.text), ["Hello", "there"])
        XCTAssertEqual(ProvenanceFiles(notes: try XCTUnwrap(test.graph.library.noteStore)).provenance(for: done)?.resumedFromMs,
                       saved, "from its checkpoint")
        XCTAssertTrue(test.graph.processing.state.jobs.isEmpty)
    }

    func testOnIOS26ComingBackLeavesTheSystemPauseForResume() async throws {
        let test = TestGraph(transcriber: Runs(), platform: .iOS26)
        defer { test.tearDown() }
        let (note, _) = try await pausedBySystem(test)

        await test.graph.becameActive().value
        XCTAssertEqual(test.graph.settings.queueHold, .system)
        XCTAssertEqual(test.graph.processing.state.jobs[note.id]?.state, .paused)
        XCTAssertEqual(test.graph.processing.state.jobs[note.id]?.pauseReason, .system)
        XCTAssertNil(test.graph.processing.state.running)
    }

    func testOnIOS18ThePersonsStopStaysStopped() async throws {
        let test = TestGraph(transcriber: Runs(), platform: .iOS18)
        defer { test.tearDown() }
        let note = try await seedNote(test)
        await test.graph.processing.transcribe(note.id)
        await waitUntil { test.graph.processing.state.running != nil }
        test.graph.processing.stopAll()
        await test.graph.processing.coordinator?.awaitIdle()
        XCTAssertEqual(test.graph.settings.queueHold, .user)

        await test.graph.becameActive().value
        XCTAssertEqual(test.graph.settings.queueHold, .user)
        XCTAssertEqual(test.graph.processing.state.jobs[note.id]?.pauseReason, .user)
        XCTAssertNil(test.graph.processing.state.running)
    }

    /// A note whose job ran until the background time ended: paused by the system with its words so far as its
    /// checkpoint. Returns the checkpoint's `doneMs`.
    private func pausedBySystem(_ test: TestGraph) async throws -> (Note, Int64) {
        let note = try await seedNote(test)
        await test.graph.processing.transcribe(note.id)
        await waitUntil {
            if case .transcribing(_, let draft)? = test.graph.processing.progress.phase(for: note.id) {
                return draft.words.map(\.text) == ["Hello"]
            }
            return false
        }
        test.background.expireAll()
        await test.graph.processing.coordinator?.awaitIdle()
        XCTAssertEqual(test.graph.settings.queueHold, .system)
        XCTAssertEqual(test.graph.processing.state.jobs[note.id]?.pauseReason, .system)
        let checkpoints = CheckpointFiles(notes: try XCTUnwrap(test.graph.library.noteStore))
        let saved = try XCTUnwrap(try checkpoints.load(note.id))
        XCTAssertGreaterThan(saved.doneMs, 0)
        return (note, saved.doneMs)
    }

    private func seedNote(_ test: TestGraph) async throws -> Note {
        let repository = try NoteRepository(root: test.root)
        var note = Note(title: "Plain", audioFilename: "audio.caf")
        note.duration = 2
        try repository.save(note)
        try Data().write(to: test.root.appendingPathComponent(note.id.uuidString).appendingPathComponent("audio.caf"))
        await test.graph.start()
        test.graph.settings.recordConsent()
        test.graph.settings.identifySpeakers = false
        return note
    }

    /// The first run finds "Hello" and runs on until it is stopped; the next one finds every word.
    private final class Runs: Transcribing, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let first = FakeTranscriber(.frozen(done: 1, total: 2, draft: [TranscriptSegment(
            text: "Hello", start: 0, end: 0.8, words: [.init(text: "Hello", start: 0, end: 0.8)])]))
        private let next = FakeTranscriber(.returns([
            TranscriptSegment(text: "Hello", start: 0, end: 0.8, words: [.init(text: "Hello", start: 0, end: 0.8)]),
            TranscriptSegment(text: "there", start: 1.2, end: 1.5, words: [.init(text: "there", start: 1.2, end: 1.5)])], total: 2))

        func transcribe(_ request: TranscriptionRequest,
                        events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
            let index = lock.withLock { count += 1; return count }
            return try await (index == 1 ? first : next).transcribe(request, events: events)
        }
        func assetStatus(locale: Locale) async -> ModelPartStatus { .ready }
        func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {}
        func speechLanguages() async -> [SpeechLanguage] { [] }
        func modelName(locale: Locale) async -> String? { await first.modelName(locale: locale) }
    }

    private func waitUntil(timeout: Duration = .seconds(30), _ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out")
    }
}
