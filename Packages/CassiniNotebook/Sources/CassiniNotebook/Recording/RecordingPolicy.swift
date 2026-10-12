import Foundation

/// What a running recording does next, decided once a second from the free space, the size of the capture file and
/// the time captured. A recording has no time limit: it runs until the user stops it, or until the free space falls
/// below the floor (`Decision.stopForSpace`). The floor is `Limits.minRecordingFreeBytes` plus the room the finish
/// needs for its M4A copy of what was captured so far, written next to the capture before the capture is removed.
/// When 15 min or less are left, `Decision.storageLow` warns first.
public enum RecordingPolicy {
    /// File growth of the capture: 48 kHz 16-bit mono linear PCM.
    public static let pcmBytesPerSecond: Int64 = 96_000

    /// What the finish's M4A copy takes per second captured: AAC at 128 kb/s, above what Apple's M4A preset writes
    /// for mono speech, so the copy always fits.
    public static let finishBytesPerSecond: Int64 = 16_000

    /// Space left (as recording time) at or below which the storage warning shows.
    public static let storageLowMs: Int64 = 15 * 60 * 1000

    /// The file's measured growth replaces the nominal rate once it has recorded this long.
    public static let measureAfterMs: Int64 = 10_000

    public enum Decision: Hashable, Sendable {
        case `continue`
        /// About `minutes` of space left, rounded as `RecordingSpace.approx` rounds (down to 5, at least 5).
        case storageLow(minutes: Int64)
        case stopForSpace
    }

    /// The decision with `usableBytes` free, a capture that takes `bytesPerSecond`, and `reserveBytes` that must stay
    /// free besides the floor. At the floor itself the recording goes on; one byte less stops it.
    public static func decide(usableBytes: Int64, bytesPerSecond: Int64, reserveBytes: Int64 = 0) -> Decision {
        if usableBytes < Limits.minRecordingFreeBytes.addingClamped(max(0, reserveBytes)) { return .stopForSpace }
        let space = RecordingSpace.of(usableBytes: usableBytes, bytesPerSecond: bytesPerSecond, reserveBytes: reserveBytes)
        if space.spaceMs <= storageLowMs { return .storageLow(minutes: RecordingSpace.approx(space.spaceMs).totalMinutes) }
        return .continue
    }

    /// The nominal rate until the file has recorded for `measureAfterMs`, then its measured growth.
    public static func bytesPerSecond(fileBytes: Int64, elapsedMs: Int64, nominal: Int64 = pcmBytesPerSecond) -> Int64 {
        guard elapsedMs >= measureAfterMs else { return nominal }
        let measured = fileBytes.multipliedReportingOverflow(by: 1000).partialValue / elapsedMs
        return measured > 0 ? measured : nominal
    }

    /// The room the finish needs for the M4A copy of `elapsedMs` of audio.
    public static func finishReserve(elapsedMs: Int64) -> Int64 { max(0, elapsedMs) * finishBytesPerSecond / 1000 }

    /// One check of the policy loop: the decision and the hint for a capture of `fileBytes` after `elapsedMs`.
    /// Each further second takes the capture's growth on disk and grows the finish's reserve, so both count.
    public static func check(usableBytes: Int64, fileBytes: Int64, elapsedMs: Int64) -> (decision: Decision, space: RecordingSpace) {
        let rate = bytesPerSecond(fileBytes: fileBytes, elapsedMs: elapsedMs) + finishBytesPerSecond
        let reserve = finishReserve(elapsedMs: elapsedMs)
        return (decide(usableBytes: usableBytes, bytesPerSecond: rate, reserveBytes: reserve),
                RecordingSpace.of(usableBytes: usableBytes, bytesPerSecond: rate, reserveBytes: reserve))
    }
}
