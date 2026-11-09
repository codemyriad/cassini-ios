import Testing
@testable import CassiniNotebook

/// Android's SpeechWindowsTest, one to one, at 16 and 48 kHz.
@Suite struct SpeechWindowsTests {
    let rates = [16_000, 48_000]
    typealias S = SampleSpan

    // ports: SpeechWindowsTest#defaultsMatchTheDesktopStockPolicy
    @Test func defaultsMatchTheDesktopStockPolicy() {
        let p = DecodePolicy()
        #expect(DecodePolicy(windowMs: 10_000, overlapMs: 500, graceMs: 500, minTerminalMs: 5_000, tailPaddingMs: 500,
                             headPaddingMs: 0, contextMs: 0, preserveSpan: false, syntheticPadding: true) == p)
        let ref = DecodePolicy.parakeetV3Reference
        #expect(ref.preserveSpan && !ref.syntheticPadding)
        #expect([ref.contextMs, ref.tailPaddingMs, ref.headPaddingMs] == [30, 0, 0])
        #expect(SpeechWindows.maxSafeSamples(16_000) == 880_000)
        #expect(SpeechWindows.maxSafeSamples(48_000) == 2_640_000)
    }

    // ports: SpeechWindowsTest#fixedWindowsHaveTheDocumentedShape
    @Test func fixedWindowsHaveTheDocumentedShape() {
        for sr in rates {
            let total = 75 * sr
            let window = 15 * sr
            let overlap = sr / 2
            let stride = window - overlap
            let want = (0..<5).map { S($0 * stride, $0 * stride + window) } + [S(5 * stride, total)]
            let bounds = SpeechWindows.fixed(total, sampleRate: sr)
            #expect(bounds == want)
            for i in 0..<(bounds.count - 1) {
                #expect(bounds[i].length == window)
                #expect(SpeechWindows.overlap(bounds[i], bounds[i + 1]) == overlap)
            }
            #expect(SpeechWindows.fixed(8 * sr, sampleRate: sr) == [S(0, 8 * sr)])
            #expect(SpeechWindows.fixed(0, sampleRate: sr) == [])
        }
    }

    // ports: SpeechWindowsTest#fixedWindowsLeaveNoGaps
    @Test func fixedWindowsLeaveNoGaps() {
        for sr in rates {
            for total in [1, sr, 14 * sr + 7, 15 * sr, 30 * sr, 75 * sr, 200 * sr] {
                let bounds = SpeechWindows.fixed(total, sampleRate: sr)
                #expect(bounds.first?.start == 0)
                #expect(bounds.last?.end == total)
                for (a, b) in zip(bounds, bounds.dropFirst()) { #expect(b.start <= a.end, "\(sr) \(total) \(bounds)") }
            }
        }
    }

    // ports: SpeechWindowsTest#ceilMsCoversEveryPaddedSample
    @Test func ceilMsCoversEveryPaddedSample() {
        #expect(SpeechWindows.ceilMs(0, sampleRate: 16_000) == 0)
        #expect(SpeechWindows.ceilMs(511, sampleRate: 16_000) == 32)
        #expect(SpeechWindows.ceilMs(8_000, sampleRate: 16_000) == 500)
        #expect(SpeechWindows.ceilMs(511, sampleRate: 48_000) == 11)
        #expect(SpeechWindows.ceilMs(24_000, sampleRate: 48_000) == 500)
        #expect(SpeechWindows.ceilMs(511, sampleRate: 0) == 0)
    }

    // ports: SpeechWindowsTest#tailPaddingPadsEveryVADSpanAndShortNonVADDecodes
    @Test func tailPaddingPadsEveryVADSpanAndShortNonVADDecodes() {
        for sr in rates {
            for seconds in [1, 9, 10, 15, 25, 55] { #expect(SpeechWindows.tailPadSamples(seconds * sr, sampleRate: sr, vadSegment: true) == sr / 2) }
            #expect(SpeechWindows.tailPadSamples(9 * sr, sampleRate: sr, vadSegment: false) == sr / 2)
            #expect(SpeechWindows.tailPadSamples(10 * sr - 1, sampleRate: sr, vadSegment: false) == sr / 2)
            #expect(SpeechWindows.tailPadSamples(10 * sr, sampleRate: sr, vadSegment: false) == 0)
            #expect(SpeechWindows.tailPadSamples(15 * sr, sampleRate: sr, vadSegment: false) == 0)
            #expect(SpeechWindows.tailPadSamples(0, sampleRate: sr, vadSegment: true) == 0)
            #expect(SpeechWindows.tailPadSamples(sr, sampleRate: 0, vadSegment: true) == 0)
        }
    }

    // ports: SpeechWindowsTest#longVADSpanUsesOverlappingWindows
    @Test func longVADSpanUsesOverlappingWindows() {
        for sr in rates {
            let total = 25 * sr + 700
            #expect(SpeechWindows.split(total, sampleRate: sr) == [S(0, 10 * sr), S(9 * sr + sr / 2, 19 * sr + sr / 2), S(19 * sr, total)])
            #expect(SpeechWindows.split(10 * sr, sampleRate: sr) == [S(0, 10 * sr)])
            #expect(SpeechWindows.split(10 * sr + 1, sampleRate: sr) == [S(0, 10 * sr + 1)])
            #expect(SpeechWindows.split(10 * sr + sr / 2, sampleRate: sr) == [S(0, 10 * sr + sr / 2)])
        }
    }

    // ports: SpeechWindowsTest#shortTerminalWindowIsRebalanced
    @Test func shortTerminalWindowIsRebalanced() {
        for sr in rates {
            let tiny = 19 * sr + sr / 2 + 1
            #expect(SpeechWindows.split(tiny, sampleRate: sr) ==
                    [S(0, 10 * sr), S(9 * sr + sr / 2, 15 * sr + 1), S(14 * sr + sr / 2 + 1, tiny)])
        }
    }

    // ports: SpeechWindowsTest#sampledTotalsStayBoundedWithExactOverlap
    @Test func sampledTotalsStayBoundedWithExactOverlap() {
        for sr in rates {
            for total in [10 * sr + sr / 2 + 1, 11 * sr, 19 * sr + sr / 2 + 1, 20 * sr, 25 * sr + 123, 55 * sr - 1] {
                let bounds = SpeechWindows.split(total, sampleRate: sr)
                #expect(bounds.count >= 2, "\(sr) \(total)")
                #expect(bounds.first?.start == 0)
                #expect(bounds.last?.end == total)
                for span in bounds { #expect((5 * sr...10 * sr).contains(span.length), "\(sr) \(total) \(bounds)") }
                for (a, b) in zip(bounds, bounds.dropFirst()) { #expect(a.end - b.start == sr / 2, "\(sr) \(total)") }
            }
        }
    }

    // ports: SpeechWindowsTest#benchmarkPoliciesCoverTheSourceWithoutGaps
    @Test func benchmarkPoliciesCoverTheSourceWithoutGaps() {
        for sr in [8_000, 16_000, 48_000] {
            for seconds in [5, 10, 15, 25] {
                for overlapMs in [0, 250, 500, 1000] {
                    let policy = DecodePolicy(windowMs: seconds * 1000, overlapMs: overlapMs, graceMs: 500, minTerminalMs: min(5, seconds / 2) * 1000)
                    for total in [1, seconds * sr + sr / 2 + 1, 30 * sr + 1, 55 * sr] {
                        let bounds = SpeechWindows.split(total, sampleRate: sr, policy: policy)
                        #expect(!bounds.isEmpty && bounds.first?.start == 0 && bounds.last?.end == total)
                        for span in bounds {
                            #expect(span.start >= 0 && span.end <= total && span.length > 0 && span.length <= seconds * sr + sr / 2, "\(bounds)")
                        }
                        for (a, b) in zip(bounds, bounds.dropFirst()) { #expect(a.end - b.start == overlapMs * sr / 1000, "\(bounds)") }
                    }
                }
            }
        }
    }

    // ports: SpeechWindowsTest#preservedSpanStaysWhole
    @Test func preservedSpanStaysWhole() {
        for sr in [8_000, 16_000, 48_000] {
            let whole = DecodePolicy(preserveSpan: true)
            for total in [1, 14 * sr + 1, 25 * sr + 60 * sr / 1000] {
                #expect(SpeechWindows.split(total, sampleRate: sr, policy: whole) == [S(0, total)])
            }
            #expect(SpeechWindows.split(14 * sr, sampleRate: sr).count >= 2)
            #expect(SpeechWindows.split(0, sampleRate: sr, policy: whole) == [])
            #expect(SpeechWindows.split(24 * sr, sampleRate: sr, policy: .parakeetV3Reference).count == 1)
        }
    }

    // ports: SpeechWindowsTest#contextClipsToRealSamples
    @Test func contextClipsToRealSamples() {
        for sr in rates {
            let k = sr / 16_000
            #expect(SpeechWindows.context(start: 0, end: 16_000 * k, total: 40_000 * k, sampleRate: sr, contextMs: 500) == S(0, 24_000 * k))
            #expect(SpeechWindows.context(start: 24_000 * k, end: 40_000 * k, total: 40_000 * k, sampleRate: sr, contextMs: 500) == S(16_000 * k, 40_000 * k))
            #expect(SpeechWindows.context(start: 5 * sr, end: 6 * sr, total: 10 * sr, sampleRate: sr, contextMs: 30) ==
                    S(5 * sr - 30 * sr / 1000, 6 * sr + 30 * sr / 1000))
        }
    }

    // ports: SpeechWindowsTest#vadDecodesCarryOverlapAndPolicyPadding
    @Test func vadDecodesCarryOverlapAndPolicyPadding() {
        for sr in rates {
            let total = 25 * sr + 700
            let windows = SpeechWindows.windows(total, sampleRate: sr, vadSegment: true)
            #expect(windows.map(\.span) == SpeechWindows.split(total, sampleRate: sr))
            #expect(windows.map(\.overlap) == [0, sr / 2, sr / 2])
            for window in windows { #expect(window.chunks == [DecodeChunk(window.span, 0, sr / 2)]) }
            #expect(SpeechWindows.windows(4 * sr, sampleRate: sr, vadSegment: true) ==
                    [DecodeWindow(S(0, 4 * sr), 0, [DecodeChunk(S(0, 4 * sr), 0, sr / 2)])])
            #expect(SpeechWindows.windows(0, sampleRate: sr, vadSegment: true) == [])
        }
    }

    // ports: SpeechWindowsTest#emergencySplitCutsAt55SecondsWithoutOverlap
    @Test func emergencySplitCutsAt55SecondsWithoutOverlap() throws {
        for sr in rates {
            let safe = 55 * sr
            func single(_ windows: [DecodeWindow]) throws -> DecodeWindow {
                #expect(windows.count == 1)
                return try #require(windows.first)
            }
            let dense = try single(SpeechWindows.windows(120 * sr, sampleRate: sr, vadSegment: false))
            #expect(dense.chunks == [DecodeChunk(S(0, safe), 0, 0), DecodeChunk(S(safe, 2 * safe), 0, 0), DecodeChunk(S(2 * safe, 120 * sr), 0, 0)])
            #expect(try single(SpeechWindows.windows(60 * sr, sampleRate: sr, vadSegment: false)).chunks.last == DecodeChunk(S(safe, 60 * sr), 0, sr / 2))
            let reference = try single(SpeechWindows.windows(120 * sr, sampleRate: sr, vadSegment: true, policy: .parakeetV3Reference))
            #expect(reference.chunks.map(\.span) == [S(0, safe), S(safe, 2 * safe), S(2 * safe, 120 * sr)])
            #expect(reference.chunks.allSatisfy { $0.headPad == 0 && $0.tailPad == 0 })
        }
    }

    // ports: SpeechWindowsTest#referencePolicySkipsChunksWithoutTwoFeatureFrames
    @Test func referencePolicySkipsChunksWithoutTwoFeatureFrames() {
        for sr in rates {
            let ref = DecodePolicy.parakeetV3Reference
            let frames = 20 * sr / 1000
            func single(_ total: Int, _ vad: Bool, _ policy: DecodePolicy = DecodePolicy()) -> [DecodeChunk] {
                let windows = SpeechWindows.windows(total, sampleRate: sr, vadSegment: vad, policy: policy)
                #expect(windows.count == 1)
                return windows.first?.chunks ?? []
            }
            #expect(single(frames - 1, true, ref) == [])
            #expect(single(frames, true, ref) == [DecodeChunk(S(0, frames), 0, 0)])
            #expect(Array(single(55 * sr + frames, false, ref).dropFirst()) == [DecodeChunk(S(55 * sr, 55 * sr + frames), 0, 0)])
            #expect(single(55 * sr + frames - 1, false, ref).count == 1)
            #expect(single(1, true) == [DecodeChunk(S(0, 1), 0, sr / 2)])
        }
    }

    /// Steady noise with `quiet` stretches of silence, given in milliseconds.
    private func noisy(_ seconds: Int, _ rate: Int, _ quiet: ClosedRange<Int64>...) -> [Float] {
        SpeechWindowNoiseFixture.make(seconds: seconds, rate: rate, quiet: quiet)
    }

    // ports: SpeechWindowsTest#aSpanOfOrdinaryLengthStaysWhole
    @Test func aSpanOfOrdinaryLengthStaysWhole() {
        for rate in [16_000, 48_000] {
            let samples = noisy(28, rate)
            #expect(SpeechWindows.quietPieces(samples, S(0, samples.count), sampleRate: rate) == [S(0, samples.count)])
            #expect(SpeechWindows.quietPieces(samples, S(rate, 20 * rate), sampleRate: rate) == [S(rate, 20 * rate)])
        }
    }

    // ports: SpeechWindowsTest#aLongSpanIsCutWhereItIsQuiet
    @Test func aLongSpanIsCutWhereItIsQuiet() {
        for rate in [16_000, 48_000] {
            // Pauses at 22.0 s and, 23.4 s after the first cut, at 45.5 s. The pause at 10 s is too early to be used.
            let samples = noisy(70, rate, 10_000...10_200, 22_000...22_100, 45_500...45_600)
            let pieces = SpeechWindows.quietPieces(samples, S(0, samples.count), sampleRate: rate)
            #expect(pieces.count == 3)
            guard pieces.count == 3 else { return }
            #expect(pieces.first?.start == 0)
            #expect(pieces.last?.end == samples.count)
            #expect(zip(pieces, pieces.dropFirst()).allSatisfy { $0.end == $1.start }, "Pieces cover the span back to back")
            let first = Int64(pieces[0].end) * 1000 / Int64(rate)
            let second = Int64(pieces[1].end) * 1000 / Int64(rate)
            #expect((22_000...22_100).contains(first), "First cut inside the pause: \(first)")
            #expect((45_500...45_600).contains(second), "Second cut inside the pause: \(second)")
            #expect(pieces.dropLast().allSatisfy { (20 * rate...25 * rate).contains($0.length) })
            #expect(pieces[2].length <= 28 * rate)
        }
    }

    // ports: SpeechWindowsTest#aSpanWithNoPauseIsStillCutBeforeADecodeRunsLong
    @Test func aSpanWithNoPauseIsStillCutBeforeADecodeRunsLong() {
        let rate = 16_000
        let samples = [Float](repeating: 0.2, count: 180 * rate)
        let pieces = SpeechWindows.quietPieces(samples, S(3 * rate, samples.count), sampleRate: rate)
        #expect(pieces.count >= 7)
        #expect(pieces.first?.start == 3 * rate)
        #expect(pieces.last?.end == samples.count)
        #expect(zip(pieces, pieces.dropFirst()).allSatisfy { $0.end == $1.start })
        #expect(pieces.allSatisfy { $0.length <= 28 * rate && $0.length > 3 * rate })
    }
}

/// `java.util.Random`, so the noise of Android's fixtures is the same here.
struct JavaRandom {
    private var seed: UInt64
    init(seed: Int64) { self.seed = (UInt64(bitPattern: seed) ^ 0x5DEECE66D) & ((1 << 48) - 1) }
    mutating func next(_ bits: Int) -> Int32 {
        seed = (seed &* 0x5DEECE66D &+ 0xB) & ((1 << 48) - 1)
        return Int32(truncatingIfNeeded: Int64(seed >> (48 - UInt64(bits))))
    }
    mutating func nextFloat() -> Float { Float(next(24)) / Float(1 << 24) }
}
