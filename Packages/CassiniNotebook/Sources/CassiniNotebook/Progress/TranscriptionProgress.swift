import Foundation

/// The words step of one run, measured as Android's core `TranscriptionProgress`: transcribed audio drives the bar and
/// a stage never resets it. Times are the run's elapsed milliseconds.
public struct TranscriptionProgress: Sendable {
    public struct Snapshot: Hashable, Sendable {
        public var doneMs: Int64
        public var totalMs: Int64
        /// Nil while the total is unknown.
        public var percent: Int?
        public var words: Int
        public var stage: TranscriptionStage
        public var startMs: Int64
        public var endMs: Int64
        /// Nil until the pace is known; 0 once every bit of audio is done.
        public var remainingMs: Int64?
        public var remainingLowMs: Int64?
        public var remainingHighMs: Int64?
    }

    /// A stage shown for less than this is not shown at all, so a quick read between two results does not flash.
    static let stageDebounceMs: Int64 = 400
    /// The shortest time left an estimate gives before every bit of audio is done.
    static let minimumRemainingMs: Int64 = 5_000

    private var totalMs: Int64
    private var doneMs: Int64 = 0
    private var words = 0
    private var percent = 0
    private var completions = 0
    private var completedAtMs: Int64 = 0
    private var rate: Double?
    private var deviation = 0.0
    private var stage = TranscriptionStage.reading
    private var stageAtMs: Int64 = 0
    private var startMs: Int64 = 0
    private var endMs: Int64 = 0
    private var shownStage = TranscriptionStage.reading
    private var shownStartMs: Int64 = 0
    private var shownEndMs: Int64 = 0

    public init(totalMs: Int64) { self.totalMs = max(0, totalMs) }

    /// Starts from a checkpoint. Loading the model again is another cold start, so its first result does not count
    /// towards the pace.
    public mutating func restore(doneMs: Int64, totalMs: Int64, words: Int, elapsedMs: Int64) {
        total(totalMs)
        self.doneMs = doneMs; self.words = words; completedAtMs = elapsedMs
        completions = 0
    }

    public mutating func total(_ value: Int64) { if value > 0 { totalMs = value } }

    public mutating func stage(_ value: TranscriptionStage, at elapsedMs: Int64, startMs: Int64 = 0, endMs: Int64 = 0) {
        if stage != value { stageAtMs = elapsedMs }
        stage = value; self.startMs = startMs; self.endMs = endMs
    }

    /// Audio up to `done` is transcribed, with `count` words so far.
    public mutating func complete(done: Int64, total: Int64, words count: Int, at elapsedMs: Int64) {
        self.total(total)
        if done > doneMs {
            // The first result includes loading the model; the pace comes from the results after it.
            if completions > 0, elapsedMs > completedAtMs {
                let measured = Double(elapsedMs - completedAtMs) / Double(done - doneMs)
                deviation = rate.map { deviation * 0.8 + abs(measured - $0) * 0.2 } ?? 0
                rate = rate.map { $0 * 0.8 + measured * 0.2 } ?? measured
            }
            completions += 1
            doneMs = done
            completedAtMs = elapsedMs
        }
        words = count
    }

    public mutating func snapshot(at elapsedMs: Int64) -> Snapshot {
        if elapsedMs - stageAtMs >= Self.stageDebounceMs || stage == shownStage {
            shownStage = stage; shownStartMs = startMs; shownEndMs = endMs
        }
        let fraction = totalMs > 0 ? Int(min(max(doneMs * 100 / totalMs, 0), 100)) : nil
        if let fraction { percent = max(percent, fraction) }
        let remaining: Int64? = if totalMs > 0, doneMs >= totalMs {
            0
        } else if completions >= 3, totalMs > doneMs, let rate {
            max(Int64(Double(totalMs - doneMs) * rate - Double(elapsedMs - completedAtMs)), Self.minimumRemainingMs)
        } else {
            nil
        }
        let spread = uncertainty
        let open = remaining.flatMap { $0 > 0 ? $0 : nil }
        return Snapshot(
            doneMs: doneMs, totalMs: totalMs, percent: fraction.map { _ in percent }, words: words, stage: shownStage,
            startMs: shownStartMs, endMs: shownEndMs, remainingMs: remaining,
            remainingLowMs: open.map { max(Int64(Double($0) * (1 - spread)), Self.minimumRemainingMs) },
            remainingHighMs: open.map { Int64(Double($0) * (1 + spread)) })
    }

    private var uncertainty: Double { min(max(0.15, deviation / (rate ?? 1) * 2), 0.75) }

    /// An estimate rounded up to 5 s, 10 s or a minute, so it never looks precise to the second.
    public static func roundedRemaining(_ value: Int64) -> Int64 {
        let step: Int64 = value >= 300_000 ? 60_000 : value >= 60_000 ? 10_000 : 5_000
        return value <= 0 ? 0 : (value + step - 1) / step * step
    }
}
