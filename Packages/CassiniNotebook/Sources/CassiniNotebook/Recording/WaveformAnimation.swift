import Foundation

/// Presentation only: the capture's 125 ms peak buckets remain unchanged. A display frame interpolates heights
/// and advances the bars by a fractional stride. All time is supplied by the caller (monotonic seconds in the app).
/// Arrays are prepared only on meter samples, never on display frames; work and memory stay bounded to 56 bars.
public struct WaveformAnimation: Sendable {
    public static let interpolationDuration = 0.05
    private static let barDuration = Double(WaveformBars.barMs) / 1_000
    private var bars: WaveformBars
    private var from: [Float]
    private var sampledAt: TimeInterval
    private var fromPosition: Double

    public init(bars: WaveformBars, at time: TimeInterval) {
        self.bars = bars
        from = bars.levels
        sampledAt = time
        fromPosition = Double(bars.elapsedMs) / 1_000
    }

    public static func animates(isPaused: Bool, reduceMotion: Bool, isActive: Bool = true) -> Bool {
        !isPaused && !reduceMotion && isActive
    }

    public mutating func update(_ next: WaveformBars, at time: TimeInterval) {
        guard next.elapsedMs >= bars.elapsedMs, next.elapsedMs - bars.elapsedMs < WaveformBars.barMs * Int64(WaveformBars.count) else {
            self = Self(bars: next, at: time)
            return
        }
        let old = frame(at: time)
        let shift = Int(min(Int64(WaveformBars.count), next.elapsedMs / WaveformBars.barMs - bars.elapsedMs / WaveformBars.barMs))
        // Align by captured bucket identity, not array slot: a bucket crossing must not blend unrelated peaks.
        from = (0..<WaveformBars.count).map { old.level(at: $0 + shift) }
        fromPosition = position(at: time)
        bars = next
        sampledAt = time
    }

    public func frame(at time: TimeInterval) -> Frame {
        Frame(from: from, to: bars.levels, fraction: fraction(at: time),
              offset: position(at: time) / Self.barDuration - Double(bars.elapsedMs / WaveformBars.barMs))
    }

    /// A static frame has no clock dependency. Reduce Motion still reflects new samples, without interpolation.
    public static func still(_ bars: WaveformBars) -> Frame {
        Frame(from: bars.levels, to: bars.levels, fraction: 1, offset: 0)
    }

    private func age(at time: TimeInterval) -> Double {
        // A stalled/backgrounded input must not invent seconds of microphone history.
        min(Self.barDuration, max(0, time - sampledAt))
    }

    private func fraction(at time: TimeInterval) -> Double {
        min(1, age(at: time) / Self.interpolationDuration)
    }

    private func position(at time: TimeInterval) -> Double {
        let target = Double(bars.elapsedMs) / 1_000
        // A delayed sample may trail our short extrapolation. Hold until capture catches up instead of
        // reversing the scrolling direction while correcting the anchor.
        return max(fromPosition, fromPosition + (target - fromPosition) * fraction(at: time) + age(at: time))
    }

    public struct Frame: Sendable {
        fileprivate let from: [Float]
        fileprivate let to: [Float]
        fileprivate let fraction: Double
        /// Leftward displacement in bar strides, including the fraction within the newest captured bucket.
        public let offset: Double

        public func level(at index: Int) -> Float {
            guard to.indices.contains(index) else { return 0 }
            return from[index] + (to[index] - from[index]) * Float(fraction)
        }

        public func height(at index: Int, in height: Double) -> Double {
            max(4, Double(level(at: index)) * max(0, height - 4))
        }
    }
}
