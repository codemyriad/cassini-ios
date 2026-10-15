import CassiniCore
import Testing
@testable import CassiniNotebook

/// Android's IncrementalTranscriptTest, one to one. The restore case round-trips the typed state; the checkpoint.json
/// codec of `recognition.chunks` comes with CheckpointState version 2.
@Suite struct IncrementalTranscriptTests {
    let rate = Limits.asrRate

    final class Calls<T> { var values: [T] = [] }

    /// A word per second, encoded in the audio itself so placement and borrowed-buffer handling are checked
    /// independently of the window's reported offset.
    func perSecond(_ speaker: String, _ calls: Calls<Int64>) -> (PcmAudio, Int64) throws -> Transcript {
        let rate = self.rate
        return { audio, start in
            calls.values.append(start)
            return Transcript((0..<(audio.samples.count / rate)).map { second in
                Word(speaker, Int64(second) * 1000, Int64(second) * 1000 + 600, "word\(Int(audio.samples[second * rate]))")
            })
        }
    }

    // ports: IncrementalTranscriptTest#publishesBeforeEndAndReconcilesOverlapsOnRecordingClock
    @Test func publishesBeforeEndAndReconcilesOverlapsOnRecordingClock() throws {
        let calls = Calls<Int64>()
        let pipeline = try IncrementalTranscript(recognize: perSecond("spk_1", calls))
        var borrowed = [Float](repeating: 0, count: rate)
        var reports: [(Int64, [Word])] = []
        for second in 0..<70 {
            for i in borrowed.indices { borrowed[i] = Float(second) }
            try pipeline.accept(borrowed, count: borrowed.count) { done, words in reports.append((done, words)) }
            if second == 26 { #expect(reports.isEmpty) }
            if second == 27 {
                #expect(reports.count == 1)
                #expect(reports.first?.0 == 28_000)
                #expect(reports.first?.1.count == 28)
            }
        }
        for i in borrowed.indices { borrowed[i] = -1 }
        let result = try pipeline.finish()
        #expect(calls.values == [0, 26_000, 52_000])
        #expect(result.words.map(\.text) == (0..<70).map { "word\($0)" })
        #expect(result.words.map(\.startMs) == (0..<70).map { Int64($0) * 1000 })
        // Later merges must not mutate lists already delivered to the UI.
        #expect(reports.first?.1.count == 28)
    }

    // ports: IncrementalTranscriptTest#exactWindowDoesNotRecognizeTheRetainedOverlapAgain
    @Test func exactWindowDoesNotRecognizeTheRetainedOverlapAgain() throws {
        let calls = Calls<Int>()
        let pipeline = try IncrementalTranscript { _, _ in calls.values.append(1); return Transcript([]) }
        try pipeline.accept([Float](repeating: 0, count: 28 * rate), count: 28 * rate)
        _ = try pipeline.finish()
        #expect(calls.values.count == 1)
    }

    // ports: IncrementalTranscriptTest#shortAndEmptyInputsFlushOnlyRealAudio
    @Test func shortAndEmptyInputsFlushOnlyRealAudio() throws {
        for count in [0, 17, rate * 3 + 11] {
            let sizes = Calls<Int>()
            let pipeline = try IncrementalTranscript { audio, _ in sizes.values.append(audio.samples.count); return Transcript([]) }
            try pipeline.accept([Float](repeating: 0, count: count), count: count)
            _ = try pipeline.finish()
            #expect(sizes.values == (count == 0 ? [] : [count]))
        }
    }

    /// Android interrupts the thread; iOS cancels the task.
    // ports: IncrementalTranscriptTest#cancellationStopsBeforeRecognition
    @Test func cancellationStopsBeforeRecognition() async {
        let rate = self.rate
        let (error, calls) = await Task { () -> ((any Error)?, Int) in
            let calls = Calls<Int>()
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                let pipeline = try IncrementalTranscript { _, _ in calls.values.append(1); return Transcript([]) }
                try pipeline.accept([Float](repeating: 0, count: 28 * rate), count: 28 * rate)
                return (nil, calls.values.count)
            } catch {
                return (error, calls.values.count)
            }
        }.value
        #expect(error is CancellationError, "Cancelled audio must not start inference")
        #expect(calls == 0)
    }

    // ports: IncrementalTranscriptTest#restoredBorrowedBufferTailContinuesWithoutRepeatingCompletedWindows
    @Test func restoredBorrowedBufferTailContinuesWithoutRepeatingCompletedWindows() throws {
        let calls = Calls<Int64>()
        let recognize = perSecond("voice", calls)
        let audio = (0..<(70 * rate)).map { Float($0 / rate) }
        let original = try IncrementalTranscript(recognize: recognize)
        let split = 28 * rate + 177
        try original.accept(Array(audio[0..<split]), count: split)
        let saved = original.checkpoint()
        #expect(original.doneMs == 28000)
        let restored = try IncrementalTranscript(restored: saved, recognize: recognize)
        #expect(restored.positionSamples == Int64(split))
        try restored.accept(Array(audio[split...]), count: audio.count - split)
        let result = try restored.finish()
        #expect(calls.values == [0, 26000, 52000])
        #expect(result.words.map(\.text) == (0..<70).map { "word\($0)" })
    }
}
