import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

/// Real job/checkpoint/version/provenance pipeline, with an event-driven fake of the bounded recognizer.
struct WhistleJobTestTranscriber: Transcribing {
    var language: String? = "en"
    var mixed = false
    var pause: StopSignal?
    var pauseBeforeWords = false
    var recognizer: SpeechRecognizer { .whistle }
    func assetStatus(locale: Locale) async -> ModelPartStatus { .ready }
    func speechLanguages() async -> [SpeechLanguage] { [] }
    func runLanguage(requested: String) async -> String? { nil }
    func modelName(locale: Locale) async -> String? { SpeechRecognizer.whistle.checkpointModel(language: "") }
    func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {}
    func transcribe(_ request: TranscriptionRequest, events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        let script = TranscriptionJobTests.ScriptedTranscriber.seventySeconds
        events(.progress(done: 0, total: 70))
        if pauseBeforeWords, let pause {
            events(.whistleBatch(.init(checkpoint: .init(sourceFrame: 16_000, processedSamples: 16_000,
                                                        doneSamples: 0, state: Data([1])), segments: [], languages: [])))
            pause.stop(.pause(.user))
            throw CancellationError()
        }
        let first = (request.whistleResume?.processedSamples ?? 0) / 80_000
        for (index, segment) in script.enumerated().dropFirst(first) {
            try Task.checkCancellation()
            let reported = mixed ? (index < 7 ? "en" : "es") : language
            let position = (index + 1) * 80_000
            let checkpoint = WhistleCheckpoint(sourceFrame: Int64(position), processedSamples: position,
                                               doneSamples: position, state: Data([1]))
            events(.whistleBatch(.init(checkpoint: checkpoint, segments: [segment],
                                       languages: reported.map { [$0] } ?? [])))
            if index == 6, let pause {
                pause.stop(.pause(.user))
                throw CancellationError()
            }
        }
        return TranscriptionResult(segments: script)
    }
}

@Suite struct WhistleJobTests {
    @Test func pauseResumePersistsDetectedLanguageAndFoldsLaterLanguagesWithoutDuplicateWords() async throws {
        let h = try await TranscriptionJobTests.Harness(settings: JobSettings(allowSpeechDownload: false,
            identifySpeakers: false, allowSpeakerDownload: false))
        defer { try? FileManager.default.removeItem(at: h.root) }
        let stop = StopSignal()
        let first = await h.run(stop: stop, using: WhistleJobTestTranscriber(pause: stop))
        #expect(first.outcome == .paused(.user))
        let checkpoint = try #require(try h.files.load(h.noteID))
        #expect(checkpoint.model == SpeechRecognizer.whistle.checkpointModel(language: ""))
        #expect(checkpoint.reportedLanguage == "en")
        #expect(checkpoint.doneMs == 35_000)
        #expect(checkpoint.whistle?.sourceFrame == 560_000)
        #expect(h.checkpoints.saved.map(\.doneMs) == (1...7).map { Int64($0) * 5_000 })
        #expect(await h.run(using: WhistleJobTestTranscriber(mixed: true)).outcome == .done)
        let note = try #require(await h.note())
        #expect(note.language == "mul")
        #expect(note.versions?.last?.language == "mul")
        let provenance = try #require(h.provenance(of: note))
        #expect(provenance.engine == "Whistle")
        #expect(provenance.model == SpeechRecognizer.whistle.checkpointModel(language: ""))
        #expect(provenance.language == "mul")
        #expect(provenance.resumedFromMs == checkpoint.doneMs)
        let words = note.transcript.flatMap(\.draftWords)
        #expect(words.count == 70)
        let expected = TranscriptionJobTests.ScriptedTranscriber.seventySeconds.flatMap(\.draftWords)
        #expect(words.map(\.text) == expected.map(\.text))
        #expect(words.map(\.startMs) == expected.map(\.startMs))
        #expect(words.map(\.endMs) == expected.map(\.endMs))
    }
    @Test func pauseBeforeTheFirstWordsKeepsSourceProgress() async throws {
        let h = try await TranscriptionJobTests.Harness(settings: JobSettings(allowSpeechDownload: false,
            identifySpeakers: false, allowSpeakerDownload: false))
        defer { try? FileManager.default.removeItem(at: h.root) }
        let stop = StopSignal()
        let first = await h.run(stop: stop, using: WhistleJobTestTranscriber(pause: stop, pauseBeforeWords: true))
        #expect(first.outcome == .paused(.user))
        let checkpoint = try #require(try h.files.load(h.noteID))
        #expect(checkpoint.doneMs == 0)
        #expect(checkpoint.segments.isEmpty)
        #expect(checkpoint.whistle?.sourceFrame == 16_000)
        #expect(await h.run(using: WhistleJobTestTranscriber()).outcome == .done)
        let note = try #require(await h.note())
        #expect(note.transcript.flatMap(\.draftWords).count == 70)
    }

}
