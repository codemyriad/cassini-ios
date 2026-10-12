import Foundation
import CassiniEngine
import CassiniNotebook

/// The words of recording, from the Recording string table.
enum RecordingCopy {
    static func defaultTitle(_ dateTime: String) -> String { String(localized: "Voice note \(dateTime)", table: "Recording") }
    static func recoveredTitle(_ day: String) -> String { String(localized: "Recovered recording \(day)", table: "Recording") }

    static let compressionFailed = String(localized: "Your recording is saved in its original quality. Compression could not finish.",
                                          table: "Recording")

    /// "1 recording recovered. Cassini closed unexpectedly. We saved what was captured (2 min 4 s)."
    static func recovered(count: Int, captured: TimeInterval) -> String {
        let title = String(localized: "\(count) recordings recovered", table: "Recording")
        let body = String(localized: "Cassini closed unexpectedly. We saved what was captured (\(compact(captured))).", table: "Recording")
        return "\(title). \(body)"
    }

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

    struct BannerText {
        var title: String
        var body: String
        var action: String?
    }

    static func banner(_ banner: RecordingBanner) -> BannerText {
        let action = banner.action.map(actionTitle)
        switch banner {
        case .pausedByOtherApp:
            return BannerText(title: String(localized: "Paused — another app is using audio", table: "Recording"),
                              body: String(localized: "Resume when your call ends. Nothing was lost.", table: "Recording"), action: action)
        case .inputLost:
            return BannerText(title: String(localized: "Paused — audio input disconnected", table: "Recording"),
                              body: String(localized: "Check your microphone, then resume. Nothing was lost.", table: "Recording"), action: action)
        case .storageLow(let minutes):
            let left = hoursMinutes(Int64(minutes))
            return BannerText(title: String(localized: "Storage almost full — about \(left) left", table: "Recording"),
                              body: String(localized: "Free some space to keep going. If it runs out, the recording saves automatically.", table: "Recording"),
                              action: action)
        case .stoppedForSpace:
            let floor = String(localized: "\(Limits.minRecordingFreeBytes / (1024 * 1024)) MB", table: "Recording")
            return BannerText(title: String(localized: "Stopped — storage almost full", table: "Recording"),
                              body: String(localized: "Less than \(floor) free. The recording so far is saved.", table: "Recording"), action: action)
        case .microphoneOff:
            return BannerText(title: String(localized: "Microphone access is off", table: "Recording"),
                              body: String(localized: "Turn it on in system settings. Recording starts when you come back.", table: "Recording"), action: action)
        case .microphoneFailed:
            return BannerText(title: String(localized: "Microphone stopped working", table: "Recording"),
                              body: String(localized: "Recording ended. The audio so far is in your library.", table: "Recording"), action: action)
        case .couldNotStart:
            return BannerText(title: String(localized: "Couldn’t start the microphone", table: "Recording"),
                              body: String(localized: "Another app may be using it. Try again.", table: "Recording"), action: action)
        }
    }

    private static func actionTitle(_ action: RecordingBanner.Action) -> String {
        switch action {
        case .resume: String(localized: "Resume", table: "Recording")
        case .openNote: String(localized: "Open note", table: "Recording")
        case .tryAgain: String(localized: "Try again", table: "Recording")
        case .openSettings: String(localized: "Open settings", table: "Recording")
        }
    }
}
