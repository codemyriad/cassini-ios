import XCTest
import CassiniNotebook
import CassiniEngine
import CassiniEngineTesting
@testable import Cassini

/// A speaker analysis through the app's queue racing Forget everyone. The rest of `VoicesStore` is tested over its own
/// files in CassiniEngine (`VoicesStoreTests`, `VoicesStoreRulesTests`).
@MainActor final class VoicesStoreTests: XCTestCase {
    /// An analysis that began before Forget everyone keeps no voiceprints, even though it finishes after it.
    func testASpeakerAnalysisThatStartedBeforeForgetEveryoneKeepsNoVoiceprints() async throws {
        let late = SpeakerAnalysis(turns: [.init(speakerID: "late", start: 0, end: 12)],
                                   prints: [.init(speakerID: "late", model: "test", vector: [1, 0], speechSeconds: 12)])
        let analyzer = FakeAnalyzer(analysis: late, suspends: true)
        let test = TestGraph(analyzer: analyzer); defer { test.tearDown() }
        var note = Note(title: "Conversation", audioFilename: "audio.caf")
        note.status = .ready
        note.transcript = [.init(text: "Hello", start: 0, end: 12)]
        try NoteRepository(root: test.root).save(note)
        try Data().write(to: test.root.appendingPathComponent(note.id.uuidString).appendingPathComponent("audio.caf"))
        await test.graph.start()
        let graph = test.graph
        graph.settings.recordSpeakerConsent()

        let outcome = await graph.processing.transcribe(note.id, kind: .speakersOnly)
        XCTAssertEqual(outcome, .queued(changed: true))
        await waitUntil { analyzer.analyzeCount == 1 }
        _ = await graph.voices.forgetEveryone()
        analyzer.resume()
        await graph.processing.coordinator?.awaitIdle()
        await graph.library.settle()

        XCTAssertEqual(graph.library.note(note.id)?.speakers?.count, 1, "the speakers are still told apart")
        let prints = try await graph.voices.store?.prints(noteID: note.id)
        XCTAssertEqual(prints, [])
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() && clock.now < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out")
    }
}
