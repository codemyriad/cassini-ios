import XCTest
import CassiniEngine
import CassiniEngineTesting
import CassiniInference
import CassiniNotebook
@testable import Cassini

private struct DownloadProbe: Transcribing {
    let recognizer: SpeechRecognizer
    let began: @Sendable () -> Void
    var assetInstallBytes: Int64 {
        recognizer == .parakeet ? ModelPlan([.init(.speech, ModelPart.speech.models)]).requiredFreeBytes : 123_456_789
    }
    func assetStatus(locale: Locale) async -> ModelPartStatus { .notDownloaded }
    func speechLanguages() async -> [SpeechLanguage] { [] }
    func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws { progress(.downloading(1)) }
    func transcribe(_ request: TranscriptionRequest, events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        guard request.allowDownload else { throw TranscriptionError.needsConsent }
        began()
        let segment = TranscriptSegment(text: "Hello.", start: 0, end: 1)
        events(.finalized(segment)); events(.progress(done: 2, total: 2))
        return TranscriptionResult(segments: [segment])
    }
}

@MainActor final class PinnedSpeechDownloadTests: XCTestCase {
    func testPendingJobsAskForTheirPinnedSpeechAndCanStartAfterConsent() async throws {
        for state in [JobState.needsConsent, .paused] {
            for identity in [nil, "appleSpeech", "parakeet"] as [String?] {
                let began = expectation(description: "pinned \(identity ?? "legacy") began")
                let recognizer: SpeechRecognizer = identity == "parakeet" ? .parakeet : .appleSpeech
                let probe = DownloadProbe(recognizer: recognizer, began: { began.fulfill() })
                let whistle = FakeTranscriber(.fails(.failed(.unknown)), status: .ready, recognizer: .whistle)
                let router = RoutedTranscriber(legacy: probe, preferred: whistle)
                let test = TestGraph(transcriber: router, analyzer: FakeAnalyzer(), downloadTranscriber: whistle)
                defer { test.tearDown() }
                test.graph.settings.speechLanguage = "en-US"
                test.graph.settings.identifySpeakers = false
                var note = Note(title: "English meeting", audioFilename: "audio.caf"); note.duration = 2
                try NoteRepository(root: test.root).save(note)
                try Data().write(to: test.root.appendingPathComponent(note.id.uuidString).appendingPathComponent("audio.caf"))
                try JobRepository(root: test.root).save([Job(noteID: note.id, seq: 1, kind: .transcribe,
                    state: state, pauseReason: state == .paused ? .user : nil, language: "en-US", enqueuedAt: test.clock.now, recognizer: identity)])
                await test.graph.start()
                let ports = try XCTUnwrap(test.graph.processing.modelDownload)
                let model = ModelDownloadModel(noteID: note.id, ports: ports)
                var effects: [ModelDownloadModel.Effect] = []
                model.onEffect = { effects.append($0) }
                await model.load()
                XCTAssertEqual(model.plan?.missing, [.speech], "Whistle readiness must not hide a pending backend's consent")
                XCTAssertTrue(effects.isEmpty, "The sheet must stay open instead of a stale-close loop")
                XCTAssertEqual(model.speechLanguage, recognizer == .appleSpeech ? "en-US" : nil)
                if recognizer == .appleSpeech { XCTAssertEqual(model.plan?.requiredFreeBytes, probe.assetInstallBytes) }
                await model.download()
                XCTAssertTrue(test.graph.settings.downloadsAllowed)
                await fulfillment(of: [began], timeout: 15)
                await test.graph.processing.coordinator?.awaitIdle()
            }
        }
    }
}
