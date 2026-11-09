import Testing

/// Test-only fixture generation. Silence is a union of integer sample ranges, so each voiced
/// sample draws exactly the same next JavaRandom value as the original per-sample definition.
enum SpeechWindowNoiseFixture {
    static func make(seconds: Int, rate: Int, quiet: [ClosedRange<Int64>]) -> [Float] {
        let count = seconds * rate
        guard count > 0 else { return [] }
        let sampleRate = Int64(rate)
        let lastMs = Int64(count - 1) * 1000 / sampleRate
        func firstSample(atOrAfter ms: Int64) -> Int {
            // ceil(ms * rate / 1000), using only nonnegative clamped millisecond bounds.
            Int((ms * sampleRate + 999) / 1000)
        }
        let intervals = quiet.compactMap { range -> Range<Int>? in
            let lower = max(0, range.lowerBound), upper = min(lastMs, range.upperBound)
            guard lower <= upper else { return nil }
            // floor(i*1000/rate) <= upper iff i < ceil((upper+1)*rate/1000).
            return min(count, firstSample(atOrAfter: lower))..<min(count, firstSample(atOrAfter: upper + 1))
        }.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Int>] = []
        for interval in intervals {
            if let previous = merged.last, interval.lowerBound <= previous.upperBound {
                merged[merged.count - 1] = previous.lowerBound..<max(previous.upperBound, interval.upperBound)
            } else {
                merged.append(interval)
            }
        }
        var samples = [Float](repeating: 0, count: count)
        var random = JavaRandom(seed: 7)
        var cursor = 0
        func fillVoiced(through end: Int) {
            for index in cursor..<end { samples[index] = (random.nextFloat() - 0.5) * 0.4 }
        }
        for silence in merged {
            fillVoiced(through: silence.lowerBound)
            cursor = silence.upperBound
        }
        fillVoiced(through: count)
        return samples
    }
}

@Suite struct SpeechWindowNoiseFixtureTests {
    /// The former generator is the independent definition of these fixtures. Compare Float bits,
    /// including exact zero, so arithmetic changes or a shifted RNG stream cannot silently pass.
    private func original(seconds: Int, rate: Int, quiet: [ClosedRange<Int64>]) -> [Float] {
        var random = JavaRandom(seed: 7)
        return (0..<(seconds * rate)).map { index in
            let ms = Int64(index) * 1000 / Int64(rate)
            return quiet.contains { $0.contains(ms) } ? 0 : (random.nextFloat() - 0.5) * 0.4
        }
    }

    @Test(arguments: [16_000, 48_000])
    func integerIntervalsPreserveEveryFixtureSample(_ rate: Int) {
        let cases: [[ClosedRange<Int64>]] = [
            [], [100...100], [0...0], [999...1000],
            [-200 ... -1], [1000...2000], [-100...10, 990...2000],
            [10...50, 20...70, 70...90], [100...100, 101...101],
            [Int64.min...Int64.max], [Int64.min ... -1, 1000...Int64.max],
            [900...950, 10...20, 15...30]
        ]
        for quiet in cases {
            let expected = original(seconds: 1, rate: rate, quiet: quiet)
            let actual = SpeechWindowNoiseFixture.make(seconds: 1, rate: rate, quiet: quiet)
            #expect(actual.map(\.bitPattern) == expected.map(\.bitPattern), "rate=\(rate), quiet=\(quiet)")
        }
    }

    @Test func emptyFixtureStaysEmpty() {
        #expect(SpeechWindowNoiseFixture.make(seconds: 0, rate: 16_000, quiet: [Int64.min...Int64.max]).isEmpty)
    }
}
