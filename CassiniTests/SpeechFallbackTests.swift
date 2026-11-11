import XCTest
import CassiniEngine
import CassiniInference
import CassiniNotebook
@testable import Cassini

/// Which job the app hands to Whistle after its recognizer could not get memory or load (`SpeechFallback`).
final class SpeechFallbackTests: XCTestCase {
    private struct Probe: Transcribing {
        let recognizer: SpeechRecognizer
        var failure: JobFailure?
        func unavailability(locale: Locale) async -> JobFailure? { failure }
        func assetStatus(locale: Locale) async -> ModelPartStatus { .ready }
        func speechLanguages() async -> [SpeechLanguage] { [] }
        func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {}
        func transcribe(_ request: TranscriptionRequest, events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
            throw TranscriptionError.failed(.model)
        }
    }

    private func job(_ recognizer: String?) -> Job {
        Job(noteID: UUID(), seq: 1, kind: .transcribe, state: .running, language: "en-US", enqueuedAt: Date(), recognizer: recognizer)
    }

    private func routed(legacy: SpeechRecognizer = .parakeet, whistle: JobFailure? = nil, withWhistle: Bool = true,
                        selected: SpeechRecognizer = .parakeet) -> RoutedTranscriber {
        let first = Probe(recognizer: legacy)
        var candidates: [any Transcribing] = [Probe(recognizer: .appleSpeech), Probe(recognizer: .parakeet)]
        if withWhistle { candidates.append(Probe(recognizer: .whistle, failure: whistle)) }
        return RoutedTranscriber(legacy: first, candidates: candidates) { selected }
    }

    func testAParakeetJobGoesToWhistleWhenWhistleCanRun() async {
        let whistle = await SpeechFallback.recognizer(for: job("parakeet"), transcriber: routed())
        XCTAssertEqual(whistle, "whistle")
        let legacy = await SpeechFallback.recognizer(for: job(nil), transcriber: routed())
        XCTAssertEqual(legacy, "whistle", "a job from before jobs named their recognizer is Parakeet's on this device")
    }

    func testNothingTakesOverWhenWhistleCannotRunOrTheJobIsNotParakeets() async {
        for failure in [JobFailure.memory, .model] {
            let none = await SpeechFallback.recognizer(for: job("parakeet"), transcriber: routed(whistle: failure))
            XCTAssertNil(none, "Whistle refuses with \(failure)")
        }
        let absent = await SpeechFallback.recognizer(for: job("parakeet"), transcriber: routed(withWhistle: false))
        XCTAssertNil(absent)
        for recognizer in ["whistle", "appleSpeech", "future-engine"] {
            let none = await SpeechFallback.recognizer(for: job(recognizer), transcriber: routed())
            XCTAssertNil(none, recognizer)
        }
        let appleLegacy = await SpeechFallback.recognizer(for: job(nil), transcriber: routed(legacy: .appleSpeech))
        XCTAssertNil(appleLegacy, "a job without a recognizer on a device whose first one is Apple's")
    }
}
