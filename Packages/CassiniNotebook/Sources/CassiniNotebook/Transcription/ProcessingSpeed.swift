import Foundation

public enum ProcessingSpeed {
    /// Larger is faster: 60 s of audio processed in 30 s is 2x realtime.
    public static func realtime(audioMs: Int64, elapsedMs: Int64) -> Double? {
        audioMs > 0 && elapsedMs > 0 ? Double(audioMs) / Double(elapsedMs) : nil
    }
}
