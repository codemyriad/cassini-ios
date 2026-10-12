import Foundation

public enum TimeText {
    public static func clock(_ seconds: Double) -> String {
        let value = seconds.isFinite ? Int(max(0, seconds).rounded(.down)) : 0
        return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
            : String(format: "%02d:%02d", value / 60, value % 60)
    }
    public static func subtitle(_ seconds: Double, separator: String = ",") -> String {
        let ms = seconds.isFinite ? Int((max(0, seconds) * 1000).rounded()) : 0
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, separator, ms % 1000)
    }
}
