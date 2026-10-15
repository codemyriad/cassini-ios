import Foundation

/// The reading rules of the Apple Speech fallback (devices that cannot hold Parakeet Ultra). Apple's analyzer finds
/// its own speech segments, so this path reads the file in fixed blocks from the resume point instead of using
/// `SpeechWindows`' windows. iOS only: Android has no fallback recognizer.
public enum AppleSpeechWindows {
    /// Audio is read from the file in blocks this long.
    public static let blockMs = 1_000
    /// A resumed run starts this long before the checkpoint, so the analyzer hears the word that ends there whole.
    public static let resumeOverlapMs: Int64 = 1_000

    public static func samples(_ ms: Int, sampleRate: Int) -> Int { SpeechWindows.samples(ms, sampleRate: sampleRate) }
    /// The first frame at or after `ms` in a file of any rate.
    public static func frame(atMs ms: Int64, sampleRate: Double) -> Int64 { Int64((Double(ms) * sampleRate / 1000).rounded(.up)) }

    /// Where a run that resumes from `doneMs` starts reading.
    public static func resumeStartMs(doneMs: Int64) -> Int64 { max(0, doneMs - resumeOverlapMs) }
}
