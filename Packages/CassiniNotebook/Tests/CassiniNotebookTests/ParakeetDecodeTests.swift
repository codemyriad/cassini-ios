import CassiniCore
import Testing
@testable import CassiniNotebook

/// `ParakeetDecode.transcribe` (Android's `Parakeet.transcribeWithDecoder`) over `DecodeSessionTests`' fake recognizer,
/// which hears word `wN` as a burst of value N + 1 in second N, and a fake detector that finds each burst.
@Suite struct ParakeetDecodeTests {
    let rate = 16_000

    /// `seconds` of audio with a word in each second listed in `spoken`.
    func recording(_ seconds: Int, _ spoken: [Int]) -> PcmAudio {
        var samples = [Float](repeating: 0, count: seconds * rate)
        for n in spoken {
            let start = n * rate + rate / 4
            for i in start..<(start + rate * 3 / 10) { samples[i] = Float(n + 1) }
        }
        return PcmAudio(samples, sampleRate: rate)
    }

    /// Sherpa's detector, reduced: a segment for each run of non-zero samples, closed by a silent window.
    final class Detector: SpeechFeed.Stream {
        private var fed: [Float] = []
        private var segments: [SpeechFeed.Segment] = []
        private var open: Int?
        var resets = 0
        func reset() { fed = []; segments = []; open = nil; resets += 1 }
        func acceptWaveform(_ window: [Float]) {
            let start = fed.count
            fed += window
            let speech = window.contains { $0 != 0 }
            if speech, open == nil { open = start }
            if !speech, let first = open { segments.append(.init(first, Array(fed[first..<start]))); open = nil }
        }
        func empty() -> Bool { segments.isEmpty }
        func front() -> SpeechFeed.Segment { segments[0] }
        func pop() { segments.removeFirst() }
        func flush() { if let first = open { segments.append(.init(first, Array(fed[first...]))); open = nil } }
    }

    @Test func speechCuttingDecodesEachDetectedSpanAndGatesTheWords() throws {
        let audio = recording(12, [1, 4, 9])
        let decoder = DecodeSessionTests.FakeDecoder(rate)
        let detector = Detector()
        let transcript = try ParakeetDecode.transcribe(audio, decoder: decoder, detector: detector, cutting: .speech)
        #expect(transcript.words.map(\.text) == ["w1", "w4", "w9"])
        #expect(decoder.calls.count == 3, "one decode per span")
        #expect(decoder.calls.allSatisfy { $0.tailPad == rate / 2 }, "the 0.5 s synthetic tail of WHOLE_SPANS")
        #expect(detector.resets == 1)
        #expect(transcript.words[1].startMs == 4_250)
    }

    @Test func quietCuttingDecodesTheWholeStretchAsOneSpan() throws {
        let audio = recording(20, [2, 15])
        let decoder = DecodeSessionTests.FakeDecoder(rate)
        let transcript = try ParakeetDecode.transcribe(audio, decoder: decoder, detector: nil, cutting: .quiet)
        #expect(transcript.words.map(\.text) == ["w2", "w15"])
        #expect(decoder.calls.count == 1)
        #expect(decoder.calls[0].start == 0 && decoder.calls[0].length == audio.samples.count)
    }

    // ports: Parakeet#WHOLE_MAX_MS
    @Test func aWholeDecodeLongerThanAMinuteIsRefused() throws {
        let decoder = DecodeSessionTests.FakeDecoder(rate)
        #expect(throws: JobFailure.long) {
            try ParakeetDecode.transcribe(PcmAudio([Float](repeating: 0, count: 61 * rate), sampleRate: rate),
                                          decoder: decoder, detector: nil, cutting: .whole)
        }
        #expect(decoder.calls.isEmpty)
        let short = try ParakeetDecode.transcribe(recording(5, [3]), decoder: decoder, detector: nil, cutting: .whole)
        #expect(short.words.map(\.text) == ["w3"])
    }

    @Test func progressIsReportedAtMostOnceASecondAndAtTheEnd() throws {
        let audio = recording(12, [1, 4, 9])
        var clock: UInt64 = 0
        var reports: [ParakeetDecode.Progress] = []
        _ = try ParakeetDecode.transcribe(audio, decoder: DecodeSessionTests.FakeDecoder(rate), detector: Detector(),
                                          cutting: .speech, nanoTime: { clock += 400_000_000; return clock }) {
            reports.append($0)
        }
        // The first report at 0, then one a second of the fake clock, then the gated words at the end.
        #expect(reports.first?.doneMs == 0)
        #expect(reports.map(\.doneMs) == reports.map(\.doneMs).sorted())
        #expect(reports.last?.doneMs == 12_000 && reports.last?.words.map(\.text) == ["w1", "w4", "w9"])
        #expect(reports.count < 2 + 3 * 2, "throttled")
    }

    @Test func aDecoderErrorEndsTheDecode() {
        struct Broken: WordDecoder {
            func decode(_ audio: PcmAudio, start: Int, length: Int, headPad: Int, tailPad: Int) throws -> [DecodedWord] {
                throw JobFailure.timings
            }
        }
        #expect(throws: JobFailure.timings) {
            try ParakeetDecode.transcribe(recording(5, [1]), decoder: Broken(), detector: nil, cutting: .quiet)
        }
    }
}
