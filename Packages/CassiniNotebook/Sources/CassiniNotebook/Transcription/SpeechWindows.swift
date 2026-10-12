import Foundation

/// The timing rules of the decode, from Android's `SpeechWindows`. Apple's analyzer finds its own speech segments, so
/// iOS keeps only the parts that do not depend on Parakeet's windows: reading the file in fixed blocks, where a resumed
/// run starts, and how far apart checkpoints are.
public enum SpeechWindows {
    /// Audio is read from the file in blocks this long.
    public static let blockMs = 1_000
    /// A resumed run starts this long before the checkpoint, so the analyzer hears the word that ends there whole.
    public static let resumeOverlapMs: Int64 = 1_000
    /// A checkpoint is saved once this much more audio is final than the last one covered.
    public static let checkpointMs: Int64 = 30_000
    /// And at most this often in time, so a fast decode of a long file does not rewrite a large checkpoint all the time.
    public static let checkpointMinIntervalMs: Int64 = 10_000

    public static func samples(_ ms: Int, sampleRate: Int) -> Int { Int(Int64(ms) * Int64(sampleRate) / 1000) }
    /// The first frame at or after `ms` in a file of any rate.
    public static func frame(atMs ms: Int64, sampleRate: Double) -> Int64 { Int64((Double(ms) * sampleRate / 1000).rounded(.up)) }

    /// Where a run that resumes from `doneMs` starts reading.
    public static func resumeStartMs(doneMs: Int64) -> Int64 { max(0, doneMs - resumeOverlapMs) }

    /// Whether a checkpoint is due: enough more audio is final than `savedMs` covered, and the last one was saved at
    /// least `checkpointMinIntervalMs` ago (`savedAt` nil when this run saved none yet).
    public static func checkpointDue(doneMs: Int64, savedMs: Int64, nowMs: Int64, savedAt: Int64?) -> Bool {
        guard doneMs - savedMs >= checkpointMs else { return false }
        return savedAt.map { nowMs - $0 >= checkpointMinIntervalMs } ?? true
    }
}
