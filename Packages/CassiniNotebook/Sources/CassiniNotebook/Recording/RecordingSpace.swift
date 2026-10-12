import Foundation

/// How much longer a recording can go on: `spaceMs` until the free space reaches `Limits.minRecordingFreeBytes` plus
/// the reserve, at the given bytes per second. A recording has no time limit, so the Recording screen's hint shows
/// only this: "Space for about 31 h more.".
public struct RecordingSpace: Hashable, Sendable {
    public var spaceMs: Int64

    public init(spaceMs: Int64) { self.spaceMs = spaceMs }

    /// `spaceMs` as the hint shows it.
    public var approx: Approx { Self.approx(spaceMs) }

    /// A rounded duration: `hours` and `minutes` (0...55, a multiple of 5; always 0 from 2 h).
    public struct Approx: Hashable, Sendable {
        public var hours: Int64
        public var minutes: Int64
        public init(hours: Int64, minutes: Int64) { self.hours = hours; self.minutes = minutes }
        public var totalMinutes: Int64 { hours * 60 + minutes }
    }

    /// The remaining time with `usableBytes` free, writing `bytesPerSecond`. Space below the floor counts as none;
    /// `reserveBytes` is room that must stay free besides the floor (the finish's compressed copy).
    public static func of(usableBytes: Int64, bytesPerSecond: Int64, reserveBytes: Int64 = 0) -> RecordingSpace {
        precondition(bytesPerSecond > 0, "bytesPerSecond must be positive")
        let floor = Limits.minRecordingFreeBytes.addingClamped(max(0, reserveBytes))
        let spare = max(0, usableBytes - floor)
        let (ms, overflow) = spare.multipliedReportingOverflow(by: 1000)
        // Only a volume that does not report its space (`Int64.max`) gets here.
        guard !overflow else { return RecordingSpace(spaceMs: spare / bytesPerSecond * 1000) }
        return RecordingSpace(spaceMs: ms / bytesPerSecond)
    }

    /// Whole hours (rounded down) from 2 h; below that, minutes rounded down to 5, at least 5.
    public static func approx(_ ms: Int64) -> Approx {
        let minutes = max(0, ms) / 60_000
        if minutes >= 120 { return Approx(hours: minutes / 60, minutes: 0) }
        let rounded = max(5, minutes / 5 * 5)
        return Approx(hours: rounded / 60, minutes: rounded % 60)
    }
}

extension Int64 {
    func addingClamped(_ other: Int64) -> Int64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}
