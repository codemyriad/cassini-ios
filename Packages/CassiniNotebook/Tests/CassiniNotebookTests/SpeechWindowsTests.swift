import Testing
import CassiniNotebook

@Suite struct SpeechWindowsTests {
    private let rates = [16_000, 48_000]

    // ports: SpeechWindowsTest#fixedWindowsHaveTheDocumentedShape
    @Test func fixedWindowsHaveTheDocumentedShape() {
        for sr in rates {
            let total = 75 * sr, window = 15 * sr, overlap = sr / 2, stride = window - overlap
            let want = (0..<5).map { Span($0 * stride, $0 * stride + window) } + [Span(5 * stride, total)]
            let bounds = SpeechWindows.fixed(total: total, sampleRate: sr)
            #expect(bounds == want)
            for i in 0..<(bounds.count - 1) {
                #expect(bounds[i].length == window)
                #expect(SpeechWindows.overlap(bounds[i], bounds[i + 1]) == overlap)
            }
            #expect(SpeechWindows.fixed(total: 8 * sr, sampleRate: sr) == [Span(0, 8 * sr)])
            #expect(SpeechWindows.fixed(total: 0, sampleRate: sr) == [])
        }
    }

    // ports: SpeechWindowsTest#fixedWindowsLeaveNoGaps
    @Test func fixedWindowsLeaveNoGaps() {
        for sr in rates {
            for total in [1, sr, 14 * sr + 7, 15 * sr, 30 * sr, 75 * sr, 200 * sr] {
                let bounds = SpeechWindows.fixed(total: total, sampleRate: sr)
                #expect(bounds.first?.start == 0)
                #expect(bounds.last?.end == total)
                for (a, b) in zip(bounds, bounds.dropFirst()) { #expect(b.start <= a.end, "\(sr) \(total)") }
            }
        }
    }

    // ports: SpeechWindowsTest#ceilMsCoversEveryPaddedSample
    @Test func ceilMsCoversEverySample() {
        #expect(SpeechWindows.ceilMs(0, sampleRate: 16_000) == 0)
        #expect(SpeechWindows.ceilMs(511, sampleRate: 16_000) == 32)
        #expect(SpeechWindows.ceilMs(8_000, sampleRate: 16_000) == 500)
        #expect(SpeechWindows.ceilMs(511, sampleRate: 48_000) == 11)
        #expect(SpeechWindows.ceilMs(24_000, sampleRate: 48_000) == 500)
        #expect(SpeechWindows.ceilMs(511, sampleRate: 0) == 0)
        #expect(SpeechWindows.floorMs(511, sampleRate: 16_000) == 31)
    }

    // ports: SpeechWindowsTest#contextClipsToRealSamples
    @Test func contextClipsToRealSamples() {
        for sr in rates {
            let k = sr / 16_000
            #expect(SpeechWindows.context(start: 0, end: 16_000 * k, total: 40_000 * k, sampleRate: sr, contextMs: 500)
                    == Span(0, 24_000 * k))
            #expect(SpeechWindows.context(start: 24_000 * k, end: 40_000 * k, total: 40_000 * k, sampleRate: sr, contextMs: 500)
                    == Span(16_000 * k, 40_000 * k))
            #expect(SpeechWindows.context(start: 5 * sr, end: 6 * sr, total: 10 * sr, sampleRate: sr, contextMs: 30)
                    == Span(5 * sr - 30 * sr / 1000, 6 * sr + 30 * sr / 1000))
        }
    }

    @Test func blocksCoverTheRestOfTheFileBackToBack() {
        for sr in rates {
            let blocks = SpeechWindows.blocks(from: 3 * sr + 5, total: 10 * sr + 7, sampleRate: sr)
            #expect(blocks.first?.start == 3 * sr + 5)
            #expect(blocks.last?.end == 10 * sr + 7)
            for (a, b) in zip(blocks, blocks.dropFirst()) { #expect(a.end == b.start) }
            #expect(blocks.dropLast().allSatisfy { $0.length == sr })
            #expect(SpeechWindows.blocks(from: 20 * sr, total: 10 * sr, sampleRate: sr) == [])
        }
    }

    @Test func aResumedRunStartsOneSecondBeforeTheCheckpoint() {
        #expect(SpeechWindows.resumeStartMs(doneMs: 54_000) == 53_000)
        #expect(SpeechWindows.resumeStartMs(doneMs: 400) == 0)
        #expect(SpeechWindows.frame(atMs: 53_000, sampleRate: 44_100) == 2_337_300)
        #expect(SpeechWindows.frame(atMs: 1, sampleRate: 44_100) == 45)
    }

    @Test func checkpointsAreDueEvery30SecondsOfAudioButNotMoreOftenThanEvery10Seconds() {
        #expect(!SpeechWindows.checkpointDue(doneMs: 29_999, savedMs: 0, nowMs: 100_000, savedAt: nil))
        #expect(SpeechWindows.checkpointDue(doneMs: 30_000, savedMs: 0, nowMs: 100, savedAt: nil))
        #expect(!SpeechWindows.checkpointDue(doneMs: 70_000, savedMs: 30_000, nowMs: 9_000, savedAt: 0))
        #expect(SpeechWindows.checkpointDue(doneMs: 70_000, savedMs: 30_000, nowMs: 10_000, savedAt: 0))
    }
}
