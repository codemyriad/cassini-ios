import Foundation
import CassiniEngine
import CassiniNotebook

/// The words of recording, from the Recording string table.
enum RecordingCopy {
    static func defaultTitle(_ dateTime: String) -> String { String(localized: "Voice note \(dateTime)", table: "Recording") }
    static func recoveredTitle(_ day: String) -> String { String(localized: "Recovered recording \(day)", table: "Recording") }

    /// "Recording" or "Paused".
    static func status(paused: Bool) -> String {
        paused ? String(localized: "Paused", table: "Recording") : String(localized: "Recording", table: "Recording")
    }

    /// "Space for about 31 h more." after the fixed hint.
    static func hint(_ space: RecordingSpace?) -> String {
        let hint = String(localized: "Keeps recording with the screen off or in another app.", table: "Recording")
        guard let space else { return hint }
        let left = hoursMinutes(space.approx.totalMinutes)
        return hint + " " + String(localized: "Space for about \(left) more.", table: "Recording")
    }

    /// "PCM 48 kHz".
    static func format(_ format: CaptureFormat) -> String {
        let rate = (format.sampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))
        return String(localized: "\(format.codec) \(rate) kHz", table: "Recording")
    }

    /// "N min" below an hour, else "N h M min" ("N h" when M is 0).
    static func hoursMinutes(_ minutes: Int64) -> String {
        let hours = minutes / 60, rest = minutes % 60
        if hours == 0 { return String(localized: "\(rest) min", table: "Recording") }
        if rest == 0 { return String(localized: "\(hours) h", table: "Recording") }
        return String(localized: "\(hours) h \(rest) min", table: "Recording")
    }

    /// "45 s", "3 min 12 s", "3 min", "1 h 12 min", "1 h"; seconds are dropped from 1 h.
    static func compact(_ duration: TimeInterval) -> String {
        let seconds = Int64(max(0, duration))
        let minutes = seconds / 60, rest = seconds % 60
        if minutes == 0 { return String(localized: "\(rest) s", table: "Recording") }
        if minutes < 60 {
            return rest == 0 ? String(localized: "\(minutes) min", table: "Recording")
                : String(localized: "\(minutes) min \(rest) s", table: "Recording")
        }
        return hoursMinutes(minutes)
    }

    /// "24 minutes, 7 seconds", for VoiceOver.
    static func spoken(_ elapsed: TimeInterval) -> String {
        Duration.seconds(Int64(max(0, elapsed))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide))
    }
}
