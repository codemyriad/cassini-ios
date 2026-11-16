import Testing
import CassiniNotebook

struct WaveformAnimationTests {
    @Test(arguments: [60.0, 120.0]) func phaseAdvancesEveryDisplayFrame(_ hz: Double) {
        var bars = WaveformBars()
        bars.add(0.8, atMs: 7_000)
        let motion = WaveformAnimation(bars: bars, at: 10)
        let first = motion.frame(at: 10 + 1 / hz)
        let second = motion.frame(at: 10 + 2 / hz)
        #expect(abs(first.offset - 8 / hz) < 0.00001)
        #expect(abs(second.offset - 16 / hz) < 0.00001)
        #expect(second.offset > first.offset)
        #expect(bars.levels.last == 0.8, "Presentation never mutates captured peaks")
    }

    @Test func heightsAreFractionalAndRetargetFromTheCurrentHeight() {
        var bars = WaveformBars()
        bars.add(0, atMs: 0)
        var motion = WaveformAnimation(bars: bars, at: 0)
        bars.add(0.8, atMs: 25)
        motion.update(bars, at: 0.025)
        let halfway = motion.frame(at: 0.05)
        #expect(abs(halfway.level(at: 55) - 0.4) < 0.00001)
        #expect(abs(halfway.height(at: 55, in: 96) - 36.8) < 0.0001)
        bars.add(1, atMs: 50)
        motion.update(bars, at: 0.05)
        #expect(abs(motion.frame(at: 0.05).level(at: 55) - 0.4) < 0.00001)
        #expect(abs(motion.frame(at: 0.075).level(at: 55) - 0.7) < 0.00001)
        #expect(motion.frame(at: 0.1).level(at: 55) == 1)
    }

    @Test func bucketCrossingPreservesTheSamePeaksAndHorizontalPosition() {
        var bars = WaveformBars()
        bars.add(0.8, atMs: 100)
        var motion = WaveformAnimation(bars: bars, at: 0.1)
        let before = motion.frame(at: 0.125)
        bars.add(0.2, atMs: 125)
        motion.update(bars, at: 0.125)
        let after = motion.frame(at: 0.125)
        #expect(abs((55 - before.offset) - (54 - after.offset)) < 0.00001)
        #expect(after.level(at: 54) == before.level(at: 55))
        #expect(after.level(at: 55) == 0)
        #expect(abs(motion.frame(at: 0.175).level(at: 55) - 0.2) < 0.00001)
    }

    @Test func pausesReduceMotionAndInactiveScenesHaveNoClock() {
        for paused in [false, true] {
            for reduced in [false, true] {
                for active in [false, true] {
                    #expect(WaveformAnimation.animates(isPaused: paused, reduceMotion: reduced, isActive: active)
                            == (!paused && !reduced && active))
                }
            }
        }
        var bars = WaveformBars()
        bars.add(0.6, atMs: 7_075)
        let frame = WaveformAnimation.still(bars)
        #expect(frame.offset == 0)
        #expect(frame.level(at: 55) == 0.6)
        // Resuming creates a fresh presentation anchor: time spent paused never advances captured history.
        let resumed = WaveformAnimation(bars: bars, at: 500)
        #expect(abs(resumed.frame(at: 500).offset - 0.6) < 0.00001)
        #expect(abs(resumed.frame(at: 500.025).offset - 0.8) < 0.00001)
    }

    @Test func gapsResetAndBadLevelsStayBounded() {
        var bars = WaveformBars()
        bars.add(.nan, atMs: -1)
        bars.add(.infinity, atMs: 25)
        #expect(bars.levels.allSatisfy { $0 == 0 })
        bars.add(2, atMs: 100)
        var motion = WaveformAnimation(bars: bars, at: 0)
        #expect(motion.frame(at: 100).offset == motion.frame(at: 200).offset)
        bars.add(-2, atMs: 20_000)
        motion.update(bars, at: 20)
        #expect((0..<56).allSatisfy { motion.frame(at: 20.1).level(at: $0) == 0 })
        motion.update(WaveformBars(), at: 30)
        #expect(motion.frame(at: 30).offset == 0)
        #expect(motion.frame(at: 30).height(at: 55, in: 96) == 4)
        #expect(motion.frame(at: 30).level(at: -1) == 0)
        #expect(motion.frame(at: 30).level(at: 56) == 0)
    }

    @Test func delayedSamplesNeverReverseTheScroll() {
        var bars = WaveformBars()
        bars.add(0.5, atMs: 100)
        var motion = WaveformAnimation(bars: bars, at: 0)
        let before = motion.frame(at: 0.125).offset
        bars.add(0.6, atMs: 110)
        motion.update(bars, at: 0.125)
        #expect(motion.frame(at: 0.125).offset == before)
        #expect(motion.frame(at: 0.15).offset >= before)
        #expect(motion.frame(at: 0.175).offset >= before)
    }

    @Test func sampleCadenceDoesNotDefineBucketTime() {
        var slow = WaveformBars(), fast = WaveformBars()
        for ms in stride(from: 0, through: 7_000, by: 100) { slow.add(0.5, atMs: Int64(ms)) }
        for ms in stride(from: 0, through: 7_000, by: 25) { fast.add(0.5, atMs: Int64(ms)) }
        #expect(fast == slow)
        #expect(fast.levels.count == 56)
        fast.add(0.1, atMs: 100)
        #expect(fast.elapsedMs == 7_000, "A late sample cannot rewind the presentation clock")
    }
}
