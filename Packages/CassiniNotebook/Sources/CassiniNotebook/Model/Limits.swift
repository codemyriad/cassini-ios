import Foundation

public enum Limits {
    /// Recording stops one byte below this much free space.
    public static let minRecordingFreeBytes: Int64 = 200 * 1024 * 1024
    /// Audio longer than this is not transcribed.
    public static let maxTranscribeDuration: TimeInterval = 36 * 3600
    /// Parakeet's and Silero's rate: the decode reads every recording as 16 kHz mono float.
    public static let asrRate = 16_000
    /// The most samples a transcription holds: the longest recording plus a second, at `asrRate`.
    public static let maxSamples = (Int(maxTranscribeDuration) * 1000 + 1000) * asrRate / 1000
    public static let maxImportBytes: Int64 = 4 * 1024 * 1024 * 1024
    /// Free space an import must leave besides the file itself.
    public static let minFreeImportBytes: Int64 = 64 * 1024 * 1024
    public static let titleMaxLength = 200
    public static let nameMaxLength = 80
}
