import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

extension TranscriptionJobTests {
    /// Real job/WordsDecode events feed the same progress and Library mapping the app uses. The transcriber stays
    /// held during checking: no timer, manual tick, or job completion can disguise a lost verification boundary.
    @MainActor @Test(.timeLimit(.minutes(1))) func speechModelVerificationStaysVisibleUntilTheHeldCheckFinishes() async throws {
        let gate = ModelCheckGate()
        let (events, output) = AsyncStream<ModelCheckInput>.makeStream()
        let engine = CheckingTranscriber(gate: gate, reachedCheck: { output.yield(.checkingReached) })
        let h = try await Harness(duration: 10,
            settings: JobSettings(allowSpeechDownload: true, identifySpeakers: false,
                                  allowSpeakerDownload: false, voicesGeneration: 0), engine: engine)
        defer { try? FileManager.default.removeItem(at: h.root) }
        let progress = JobProgress(uptimeMs: { 0 })
        progress.begin(h.noteID, finalizationMs: nil)
        defer { progress.end() }
        let run = Task {
            let result = await h.run(observe: { output.yield(.event($0)) })
            output.finish()
            return result
        }
        var iterator = events.makeAsyncIterator()
        var sawUnknown = false, sawCompleteTransfer = false, sawChecking = false
        // The transcriber's independent boundary also arrives when verification was lost by WordsDecode.
        // That makes the negative control fail on assertions instead of waiting forever for the missing event.
        while let input = await iterator.next() {
            if case .checkingReached = input { break }
            guard case .event(let event) = input else { continue }
            progress.apply(event)
            guard case .downloading(let download) = event else { continue }
            if download?.verifying == true { sawChecking = true }
            if download?.totalBytes == 0 {
                sawUnknown = true
                #expect(progress.modelDownload != nil, "unknown transfer still has model preparation state")
            }
            if download?.percent == 100 { sawCompleteTransfer = true }
        }
        #expect(sawUnknown && sawCompleteTransfer && sawChecking)
        #expect(progress.modelDownload?.part == .speech)
        #expect(progress.modelDownload?.verifying == true)
        #expect(progress.modelDownload?.totalBytes == 0, "checking has no invented percentage")
        let state = ProcessingState(running: RunningJob(noteID: h.noteID, title: "English sample"))
        let banner = LibraryMapping.progress(state, phase: progress.phase)
        #expect(banner?.line == .checking(percent: nil))
        #expect(banner?.fraction == nil)
        #expect(await gate.isReleased == false)
        #expect(progress.modelDownload != nil, "the held verifier must not look like an ended model download")

        await gate.release()
        while let input = await iterator.next() {
            if case .event(let event) = input { progress.apply(event) }
        }
        let result = await run.value
        #expect(result.outcome == .done)
        #expect(progress.modelDownload == nil, "actual decoding clears model preparation without ending JobProgress")
        #expect(progress.noteID == h.noteID)
    }
}

private enum ModelCheckInput: Sendable {
    case event(JobEvent)
    case checkingReached
}

private actor ModelCheckGate {
    private(set) var isReleased = false
    private var waiter: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !isReleased else { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        isReleased = true
        waiter?.resume()
        waiter = nil
    }
}

private struct CheckingTranscriber: Transcribing {
    let gate: ModelCheckGate
    let reachedCheck: @Sendable () -> Void
    var recognizer: SpeechRecognizer { .parakeet }
    func assetStatus(locale: Locale) async -> ModelPartStatus { .ready }
    func speechLanguages() async -> [SpeechLanguage] { [] }
    func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {}

    func transcribe(_ request: TranscriptionRequest,
                    events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        events(.preparingModel(.downloading(nil)))
        events(.preparingModel(.downloading(1)))
        events(.preparingModel(.checking))
        reachedCheck()
        await gate.wait()
        return try await FakeTranscriber(.returns([TranscriptSegment(text: "Hello everyone.", start: 0, end: 1)], total: 10),
                                        recognizer: .parakeet).transcribe(request, events: events)
    }
}
