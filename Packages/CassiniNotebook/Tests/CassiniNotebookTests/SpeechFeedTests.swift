import Testing
@testable import CassiniNotebook

/// Android's SpeechFeedTest, one to one. iOS reads recordings at 16 kHz, so the 48 kHz scan case passes its 16 kHz copy
/// (all zeros, as Android's resampler gives for zeros) instead of resampling here.
@Suite struct SpeechFeedTests {
    /// Records the calls the feed loop makes and releases queued segments once enough windows are in.
    final class FakeStream: SpeechFeed.Stream {
        let release: [Int: [SpeechFeed.Segment]]
        var calls: [String] = []
        var windows: [[Float]] = []
        private var queue: [SpeechFeed.Segment] = []
        init(_ release: [Int: [SpeechFeed.Segment]] = [:]) { self.release = release }
        func reset() { calls.append("reset") }
        func acceptWaveform(_ window: [Float]) {
            calls.append("accept")
            windows.append(window)
            if let segments = release[windows.count] { queue += segments }
        }
        func empty() -> Bool { calls.append("empty"); return queue.isEmpty }
        func front() -> SpeechFeed.Segment { queue[0] }
        func pop() { queue.removeFirst() }
        func flush() { calls.append("flush") }
    }

    // ports: SpeechFeedTest#feedsExactWindowsAndZeroPadsOnlyTheLast
    @Test func feedsExactWindowsAndZeroPadsOnlyTheLast() throws {
        let samples = (0..<(16000 * 12 + 300)).map { Float($0 % 977 + 1) }
        let stream = FakeStream()
        try SpeechFeed.feed(stream, samples) { _ in Issue.record("no segments queued") }
        #expect(stream.windows.allSatisfy { $0.count == 512 })
        #expect(stream.windows.count == (samples.count + 511) / 512)
        let fed = stream.windows.flatMap { $0 }
        #expect(Array(fed.prefix(samples.count)) == samples)
        #expect(fed.dropFirst(samples.count).allSatisfy { $0 == 0 })
        #expect(fed.count - samples.count == 512 - 300)
    }

    // ports: SpeechFeedTest#feedReturnsTheZeroPaddingOfTheLastWindow
    @Test func feedReturnsTheZeroPaddingOfTheLastWindow() throws {
        #expect(try SpeechFeed.feed(FakeStream(), [Float](repeating: 0, count: 16000 * 12 + 300)) { _ in } == 512 - 300)
        #expect(try SpeechFeed.feed(FakeStream(), [0]) { _ in } == 511)
        #expect(try SpeechFeed.feed(FakeStream(), [Float](repeating: 0, count: 1024)) { _ in } == 0)
        #expect(try SpeechFeed.feed(FakeStream(), []) { _ in } == 0)
    }

    /// gocassini stt_chunk_test.go TestSamplesToCeilMSMatchesActualVADTailPadding.
    // ports: SpeechFeedTest#samplesToCeilMsMatchesTheVadTailPadding
    @Test func samplesToCeilMsMatchesTheVadTailPadding() {
        #expect(SpeechWindows.ceilMs(0, sampleRate: 16000) == 0)
        #expect(SpeechWindows.ceilMs(511, sampleRate: 16000) == 32)
        #expect(SpeechWindows.ceilMs(8000, sampleRate: 16000) == 500)
        #expect(SpeechWindows.ceilMs(-1, sampleRate: 16000) == 0)
        #expect(SpeechWindows.ceilMs(100, sampleRate: 0) == 0)
        #expect(SpeechWindows.ceilMs(Int(Int32.max), sampleRate: 16_000_000) == 134_218)
    }

    // ports: SpeechFeedTest#scanReportsTheTailPaddingOfTheSixteenKilohertzCopy
    @Test func scanReportsTheTailPaddingOfTheSixteenKilohertzCopy() throws {
        // 480300 samples at 48 kHz: a 160100-sample copy, 156 zeros in its last window, ceil(9.75) = 10 ms.
        let audio = PcmAudio([Float](repeating: 0, count: 480300), sampleRate: 48000)
        let stream = FakeStream([313: [SpeechFeed.Segment(159744, [Float](repeating: 0, count: 512))]])
        var spans: [SampleSpan] = []
        let paddedTailMs = try SpeechFeed.scan(stream, audio, copy16k: [Float](repeating: 0, count: 160100)) { spans.append($0) }
        #expect(paddedTailMs == 10)
        #expect(stream.windows.count * 512 - 160100 == 156)
        // The span still stops at the recording's end; the padding travels separately.
        #expect(spans == [SampleSpan(479232, 480300)])
        // The desktop clamp keeps a word starting by audioEndMs + paddedTailMs as a zero-length end word.
        let audioEndMs = audio.durationMs
        #expect(audioEndMs == 10006)
        #expect(10011 <= audioEndMs + paddedTailMs)
        #expect(!(10017 <= audioEndMs + paddedTailMs))
        // A copy ending on a window boundary has no padding: only words at audioEndMs itself survive.
        #expect(try SpeechFeed.scan(FakeStream(), PcmAudio([Float](repeating: 0, count: 512 * 3 * 3), sampleRate: 48000),
                                    copy16k: [Float](repeating: 0, count: 512 * 3)) { _ in } == 0)
    }

    // ports: SpeechFeedTest#resetsOnceDrainsEveryFiveSecondsThenFlushesAndDrains
    @Test func resetsOnceDrainsEveryFiveSecondsThenFlushesAndDrains() throws {
        let samples = [Float](repeating: 0, count: 16000 * 12 + 300)
        let stream = FakeStream()
        try SpeechFeed.feed(stream, samples) { _ in }
        // 157 windows are the first to reach 80000 fed samples; the count restarts after each drain.
        let expected = ["reset"] + Array(repeating: "accept", count: 157) + ["empty"] + Array(repeating: "accept", count: 157) + ["empty"] +
            Array(repeating: "accept", count: stream.windows.count - 314) + ["flush", "empty"]
        #expect(stream.calls == expected)
    }

    // ports: SpeechFeedTest#deliversSegmentsInOrderAtTheNextDrainAndSkipsEmptyOnes
    @Test func deliversSegmentsInOrderAtTheNextDrainAndSkipsEmptyOnes() throws {
        let first = SpeechFeed.Segment(1000, [Float](repeating: 0, count: 4000))
        let second = SpeechFeed.Segment(30000, [Float](repeating: 0, count: 8000))
        let last = SpeechFeed.Segment(150000, [Float](repeating: 0, count: 2000))
        let stream = FakeStream([10: [first, SpeechFeed.Segment(9000, [])], 200: [second], 320: [last]])
        var seen: [[Int]] = []
        try SpeechFeed.feed(stream, [Float](repeating: 0, count: 16000 * 12)) { seen.append([$0.startSample, stream.windows.count]) }
        // Drains follow windows 157 and 314; the last segment comes from the drain after flush.
        #expect(seen == [[1000, 157], [30000, 314], [150000, 375]])
    }

    /// Android interrupts the thread; iOS cancels the task.
    // ports: SpeechFeedTest#cancellationStopsAtTheNextDrain
    @Test func cancellationStopsAtTheNextDrain() async {
        let error = await Task { () -> (any Error)? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                try SpeechFeed.feed(FakeStream(), [Float](repeating: 0, count: 16000 * 6)) { _ in }
                return nil
            } catch {
                return error
            }
        }.value
        #expect(error is CancellationError)
    }

    // ports: SpeechFeedTest#spansMapBackToTheRecordingRate
    @Test func spansMapBackToTheRecordingRate() {
        #expect(SpeechFeed.recordingSpan(start: 16000, length: 8000, rate: 48000, recordingLength: 480000) == SampleSpan(48000, 72000))
        #expect(SpeechFeed.recordingSpan(start: 16000, length: 8000, rate: 16000, recordingLength: 480000) == SampleSpan(16000, 24000))
        #expect(SpeechFeed.recordingSpan(start: 16000, length: 8000, rate: 8000, recordingLength: 480000) == SampleSpan(8000, 12000))
        // 44.1 kHz: start rounds down (2.76 -> 2), end rounds up (5.51 -> 6).
        #expect(SpeechFeed.recordingSpan(start: 1, length: 1, rate: 44100, recordingLength: 1000) == SampleSpan(2, 6))
        // The zero-padded final window never reaches past the recording.
        #expect(SpeechFeed.recordingSpan(start: 15872, length: 512, rate: 48000, recordingLength: 48000) == SampleSpan(47616, 48000))
        #expect(SpeechFeed.recordingSpan(start: 16000, length: 512, rate: 48000, recordingLength: 48000) == nil)
        // A long recording at 96 kHz does not overflow.
        #expect(SpeechFeed.recordingSpan(start: 333_333_332, length: 1, rate: 96000, recordingLength: 2_000_000_000) ==
                SampleSpan(1_999_999_992, 1_999_999_998))
    }
}
