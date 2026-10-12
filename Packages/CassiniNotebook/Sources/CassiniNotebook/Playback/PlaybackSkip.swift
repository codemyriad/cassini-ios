import Foundation

/// The player's skips and the slider's accessibility steps: 10 s, as on Android.
public enum PlaybackSkip {
    /// Back and forward skips in seconds; also the lock screen's interval and VoiceOver's slider step.
    public static let interval: TimeInterval = 10

    /// `position` moved by `seconds`, kept inside the file.
    public static func target(from position: TimeInterval, by seconds: TimeInterval, duration: TimeInterval) -> TimeInterval {
        min(max(0, position + seconds), max(0, duration))
    }

    /// Where one VoiceOver swipe on the slider goes: one step forward or back.
    public static func step(from position: TimeInterval, forward: Bool, duration: TimeInterval) -> TimeInterval {
        target(from: position, by: forward ? interval : -interval, duration: duration)
    }

    /// How many steps the slider has between its ends (Android's `ProgressBarRangeInfo.steps`).
    public static func steps(duration: TimeInterval) -> Int {
        max(0, Int((max(0, duration) / interval).rounded(.down)) - 1)
    }
}
