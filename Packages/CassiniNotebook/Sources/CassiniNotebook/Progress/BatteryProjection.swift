import Foundation

/// Where the battery will be when the job finishes, measured only while the job runs: each run, and a charge, starts a
/// fresh measurement. iOS reports the level in steps of 5 %, so a projection needs a few minutes of discharge.
public struct BatteryProjection: Sendable {
    public struct Reading: Hashable, Sendable {
        public var elapsedMs: Int64
        /// 0 to 100.
        public var percent: Int
        public var charging: Bool
        /// The charge in µAh where the device reports it; iOS does not.
        public var chargeMicroampHours: Int64?
        public init(elapsedMs: Int64, percent: Int, charging: Bool, chargeMicroampHours: Int64? = nil) {
            self.elapsedMs = elapsedMs; self.percent = percent; self.charging = charging
            self.chargeMicroampHours = chargeMicroampHours
        }
    }

    public struct Estimate: Hashable, Sendable {
        public var percentNow: Int?
        public var percentAfter: Int?
        public var charging: Bool
    }

    /// Fuel gauges and their percentage steps are noisy: a projection needs this much time and drop.
    static let minimumMeasureMs: Int64 = 120_000
    static let minimumDrop = 0.5

    private var baseline: Reading?

    public init() {}

    public mutating func sample(_ now: Reading, remainingMs: Int64?) -> Estimate {
        precondition((0...100).contains(now.percent))
        if now.charging {
            baseline = nil
            return Estimate(percentNow: now.percent, percentAfter: nil, charging: true)
        }
        if let first = baseline, now.elapsedMs >= first.elapsedMs, now.percent <= first.percent,
           !Self.charged(from: first, to: now) {
            // Keep measuring from the first reading.
        } else {
            baseline = now
        }
        let start = baseline ?? now
        let elapsed = now.elapsedMs - start.elapsedMs
        let drop: Double = if let startCharge = start.chargeMicroampHours, let charge = now.chargeMicroampHours,
                              startCharge > 0, start.percent > 0 {
            Double(startCharge - charge) * Double(start.percent) / Double(startCharge)
        } else {
            Double(start.percent - now.percent)
        }
        var after: Int?
        if elapsed >= Self.minimumMeasureMs, drop >= Self.minimumDrop, let remainingMs, remainingMs > 0 {
            let projected = (Double(now.percent) - drop * Double(remainingMs) / Double(elapsed)).rounded(.down)
            after = min(max(Int(projected), 0), now.percent)
        }
        return Estimate(percentNow: now.percent, percentAfter: after, charging: false)
    }

    private static func charged(from first: Reading, to now: Reading) -> Bool {
        guard let before = first.chargeMicroampHours, let after = now.chargeMicroampHours else { return false }
        return after > before
    }
}
