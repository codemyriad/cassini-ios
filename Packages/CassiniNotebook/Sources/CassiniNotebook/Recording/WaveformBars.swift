import Foundation

/// The Recording waveform: `count` bars of `barMs` each, the last 7 s. Each bar is the loudest level sampled in its
/// time. Bars follow the captured time, not the wall clock, so they stand still while the recording is paused.
public struct WaveformBars: Hashable, Sendable {
    public static let count = 56
    public static let barMs: Int64 = 125
    /// The newest bars, drawn in the fresh colour.
    public static let freshCount = 7

    /// 0...1, oldest first.
    public private(set) var levels = Array(repeating: Float(0), count: count)
    private var lastBar: Int64?

    public init() {}

    /// Puts one level sample (0...1), taken at `elapsedMs` of captured time, into its bar.
    public mutating func add(_ level: Float, atMs elapsedMs: Int64) {
        let bar = max(0, elapsedMs) / Self.barMs
        if let lastBar {
            let shift = Int(min(max(bar - lastBar, 0), Int64(Self.count)))
            if shift > 0 {
                levels.removeFirst(shift)
                levels.append(contentsOf: repeatElement(0, count: shift))
                self.lastBar = bar
            }
        } else {
            lastBar = bar
        }
        levels[Self.count - 1] = max(levels[Self.count - 1], min(1, max(0, level.isFinite ? level : 0)))
    }
}
