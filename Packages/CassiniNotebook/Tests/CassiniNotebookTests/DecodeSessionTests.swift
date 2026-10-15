import CassiniCore
import Testing
@testable import CassiniNotebook

/// Android's DecodeSessionTest: the window and retry algorithm of 0.1.0 `Parakeet.Session` over a fake recognizer. The
/// fake hears a word wherever the audio holds a burst of non-zero samples: word `wN` is a burst of value N + 1, 300 ms
/// long, a quarter second into second N. Its times are relative to the decoded input, head padding included, as the
/// real decoder's are.
@Suite struct DecodeSessionTests {
    let rate = 16_000

    struct Call { let start: Int, length: Int, headPad: Int, tailPad: Int }

    final class FakeDecoder: WordDecoder {
        let rate: Int
        let refuse: (Call) -> Bool
        var calls: [Call] = []
        init(_ rate: Int, refuse: @escaping (Call) -> Bool = { _ in false }) { self.rate = rate; self.refuse = refuse }

        func decode(_ audio: PcmAudio, start: Int, length: Int, headPad: Int, tailPad: Int) throws -> [DecodedWord] {
            let call = Call(start: start, length: length, headPad: headPad, tailPad: tailPad)
            calls.append(call)
            if refuse(call) { return [] }
            var words: [DecodedWord] = []
            var p = start
            while p < start + length {
                let value = audio.samples[p]
                if value == 0 { p += 1; continue }
                let first = p
                while p < start + length && audio.samples[p] == value { p += 1 }
                let startMs = Int64(headPad + first - start) * 1000 / Int64(rate)
                let endMs = Int64(headPad + p - start) * 1000 / Int64(rate)
                words.append(DecodedWord(Word("spk_1", startMs, endMs, "w\(Int(value) - 1)"), capMs: endMs))
            }
            return words
        }
    }

    /// `seconds` of audio with a word in each second listed in `spoken`.
    func recording(_ seconds: Int, _ spoken: [Int]? = nil) -> PcmAudio {
        var samples = [Float](repeating: 0, count: seconds * rate)
        for n in spoken ?? Array(0..<seconds) {
            let from = n * rate + rate / 4
            for i in from..<(from + rate * 3 / 10) { samples[i] = Float(n + 1) }
        }
        return PcmAudio(samples, sampleRate: rate)
    }

    func texts(_ words: [DecodedWord]) -> [String] { words.map(\.word.text) }

    // ports: DecodeSessionTest#wholeDecodesTheRecordingOnce
    @Test func wholeDecodesTheRecordingOnce() throws {
        let audio = recording(12)
        let decoder = FakeDecoder(rate)
        let words = try DecodeSession(decoder: decoder, audio: audio, policy: .wholeSpans).whole()
        #expect(decoder.calls.count == 1)
        let call = try #require(decoder.calls.first)
        #expect([call.start, call.length, call.headPad, call.tailPad] == [0, audio.samples.count, 0, 0])
        #expect(words.map(\.text) == (0..<12).map { "w\($0)" })
        #expect(words.map(\.startMs) == (0..<12).map { Int64($0) * 1000 + 250 })
    }

    // ports: DecodeSessionTest#fixedWindowsKeepEachWordOnceOnTheRecordingClock
    @Test func fixedWindowsKeepEachWordOnceOnTheRecordingClock() throws {
        let audio = recording(40)
        let decoder = FakeDecoder(rate)
        let session = DecodeSession(decoder: decoder, audio: audio, policy: .wholeSpans)
        var reached: [Int] = []
        try session.fixed { reached.append($0) }
        #expect(decoder.calls.count == SpeechWindows.fixed(audio.samples.count, sampleRate: rate).count)
        #expect(texts(session.words) == (0..<40).map { "w\($0)" })
        #expect(session.words.map(\.word.startMs) == (0..<40).map { Int64($0) * 1000 + 250 })
        #expect(reached.sorted() == reached)
        #expect(reached.last == audio.samples.count)
    }

    // ports: DecodeSessionTest#quietCuttingSplitsALongSpanAtQuietPointsWithContext
    @Test func quietCuttingSplitsALongSpanAtQuietPointsWithContext() throws {
        let audio = recording(70)
        let decoder = FakeDecoder(rate)
        let session = DecodeSession(decoder: decoder, audio: audio, policy: .wholeSpans)
        var reached: [Int] = []
        try session.speech(SampleSpan(0, audio.samples.count)) { reached.append($0) }
        let pieces = SpeechWindows.quietPieces(audio.samples, SampleSpan(0, audio.samples.count), sampleRate: rate)
        #expect(pieces.count > 1, "A 70 s span is cut")
        #expect(decoder.calls.count >= pieces.count)
        // Neighbouring pieces are decoded with recorded context past the cut.
        #expect(decoder.calls.dropFirst().contains { call in pieces.dropFirst().contains { call.start < $0.start } })
        #expect(texts(session.words) == (0..<70).map { "w\($0)" })
        #expect(reached.last == audio.samples.count)
    }

    // ports: DecodeSessionTest#speechSpansAreDecodedOneByOneInOrder
    @Test func speechSpansAreDecodedOneByOneInOrder() throws {
        let audio = recording(30, [1, 2, 3, 10, 11, 20])
        let decoder = FakeDecoder(rate)
        let session = DecodeSession(decoder: decoder, audio: audio, policy: .wholeSpans)
        let spans = [SampleSpan(rate, 4 * rate), SampleSpan(10 * rate, 12 * rate), SampleSpan(20 * rate, 21 * rate)]
        for span in spans { try session.speech(span) { _ in } }
        #expect(decoder.calls.map(\.start) == spans.map(\.start))
        #expect(decoder.calls.allSatisfy { $0.tailPad > 0 }, "A detected span gets synthetic tail silence")
        #expect(texts(session.words) == ["w1", "w2", "w3", "w10", "w11", "w20"])
        #expect(session.words.map(\.word.startMs) == [1250, 2250, 3250, 10250, 11250, 20250])
    }

    // ports: DecodeSessionTest#aSpanThatDecodesToNothingIsRetriedWithRecordedContext
    @Test func aSpanThatDecodesToNothingIsRetriedWithRecordedContext() throws {
        // A word at 4.25 s inside the detected span, and one at 3.25 s that only the retry's context reaches.
        let audio = recording(10, [3, 4])
        let span = SampleSpan(3 * rate + rate * 6 / 10, 5 * rate)
        let decoder = FakeDecoder(rate) { $0.start == span.start }
        let session = DecodeSession(decoder: decoder, audio: audio, policy: .wholeSpans)
        try session.speech(span) { _ in }
        #expect(decoder.calls.count == 2)
        let retry = try #require(decoder.calls.last)
        let context = SpeechWindows.samples(DecodeSession.retryContextMs, sampleRate: rate)
        #expect(retry.start == span.start - context)
        // Only words overlapping the detected speech are kept: w3 ends before the span starts.
        #expect(texts(session.words) == ["w4"])
        #expect(session.words.first?.word.startMs == 4250)
    }

    // ports: DecodeSessionTest#aSpanWithNoWordsAtAllStaysEmptyAfterOneRetry
    @Test func aSpanWithNoWordsAtAllStaysEmptyAfterOneRetry() throws {
        let audio = recording(10, [])
        let decoder = FakeDecoder(rate)
        let session = DecodeSession(decoder: decoder, audio: audio, policy: .wholeSpans)
        try session.speech(SampleSpan(2 * rate, 3 * rate)) { _ in }
        #expect(decoder.calls.count == 2)
        #expect(texts(session.words) == [])
    }

    // ports: DecodeSessionTest#withoutSpanPreservationThereIsNoRetry
    @Test func withoutSpanPreservationThereIsNoRetry() throws {
        let audio = recording(10, [])
        let decoder = FakeDecoder(rate)
        let session = DecodeSession(decoder: decoder, audio: audio, policy: DecodePolicy())
        try session.speech(SampleSpan(2 * rate, 3 * rate)) { _ in }
        #expect(decoder.calls.count == 1)
    }
}
