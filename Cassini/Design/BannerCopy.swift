import Foundation
import CassiniEngine
import CassiniNotebook

/// The words of a banner in the shown language (Android `BannerText`): the kind's copy from the Notices table with the
/// arguments its kind `uses`, formatted.
enum BannerCopy {
    static func title(_ spec: BannerSpec) -> String { title(spec.kind, spec.args) }
    static func body(_ spec: BannerSpec, locale: Locale = .autoupdatingCurrent) -> String? {
        body(spec.kind, spec.args, locale: locale)
    }

    static func title(_ kind: BannerKind, _ args: BannerArgs) -> String {
        switch kind {
        case .trustVerified: String(localized: "Verified", table: "Notices")
        case .trustNotVerified: String(localized: "Not verified", table: "Notices")
        case .trustAudioChanged: String(localized: "Audio changed since transcription", table: "Notices")
        case .trustUnreadable: String(localized: "Transcript can’t be read", table: "Notices")
        case .trustNewerFormat: String(localized: "Newer Cassini format", table: "Notices")
        case .plainAudio: String(localized: "Plain audio", table: "Notices")
        case .unplayable: String(localized: "This recording can’t be played", table: "Notices")

        case .recPausedOtherApp: String(localized: "Paused — another app is using audio", table: "Notices")
        case .recInputLost: String(localized: "Paused — audio input disconnected", table: "Notices")
        case .recStorageLow:
            String(localized: "Storage almost full — about \(atLeastOneMinute(args.ms1)) left", table: "Notices")
        case .recStoppedStorage: String(localized: "Stopped — storage almost full", table: "Notices")
        case .recMicOff: String(localized: "Microphone access is off", table: "Notices")
        case .recMicFailed: String(localized: "Microphone stopped working", table: "Notices")
        case .recCouldNotStart: String(localized: "Couldn’t start the microphone", table: "Notices")
        case .recovered: String(localized: "\(args.count) recordings recovered", table: "Notices")
        case .recCompressionFailed: String(localized: "Saved in its original quality", table: "Notices")

        case .txPaused: String(localized: "Paused at \(clock(args.ms1)) of \(clock(args.ms2))", table: "Notices")
        case .txPausedEarly: String(localized: "Paused before any words were found", table: "Notices")
        case .txQueueHeld: String(localized: "Transcription paused · \(args.count) waiting", table: "Notices")
        case .txCalculating: String(localized: "Calculating time left…", table: "Notices")
        case .txBattery: String(localized: "Measuring battery use…", table: "Notices")
        case .txOneVoice: String(localized: "All words shown as one voice", table: "Notices")
        case .txCheckpointMismatch: String(localized: "Saved progress no longer matches", table: "Notices")
        case .txFailed: String(localized: "Couldn’t transcribe", table: "Notices")

        case .dlDownloading: downloading(args.part ?? .speech, percent: args.downloadPercent)
        case .dlChecking:
            if let percent = args.percent {
                String(localized: "Checking files — \(percent)%", table: "Notices")
            } else {
                String(localized: "Checking files", table: "Notices", comment: "A model install checks its files; no count yet")
            }
        case .dlNoConnection: String(localized: "No connection", table: "Notices")
        case .dlStopped: String(localized: "Download stopped", table: "Notices")
        case .dlNoSpace: String(localized: "Not enough storage", table: "Notices")
        case .dlFileCheck: String(localized: "File check failed", table: "Notices")
        case .dlInstallFailed: String(localized: "Couldn’t finish installing", table: "Notices")
        case .dlRecordNow: String(localized: "Record now, transcribe later", table: "Notices")

        case .libEmpty: String(localized: "No notes yet", table: "Notices")
        case .libNoMatch: String(localized: "Nothing matches “\(args.text ?? "")”", table: "Notices")
        case .importing: String(localized: "Importing \(args.text ?? "")…", table: "Notices")
        case .importTooLarge: String(localized: "File too large", table: "Notices")
        case .importNoSpace: String(localized: "Not enough space to import", table: "Notices")
        case .importOpen: String(localized: "Can’t open this file", table: "Notices")
        case .notificationsOff: String(localized: "Notifications are off", table: "Notices")
        case .voicesUnreadable: String(localized: "Saved voices can’t be read", table: "Notices")
        case .libUnavailable: String(localized: "Your notes can’t be opened", table: "Notices")
        case .notesUnreadable: String(localized: "\(args.count) notes can’t be read", table: "Notices")
        }
    }

    /// `locale` formats the decimal sizes ("1.4 GB").
    static func body(_ kind: BannerKind, _ args: BannerArgs, locale: Locale = .autoupdatingCurrent) -> String? {
        switch kind {
        case .trustVerified: String(localized: "Audio matches the transcript exactly. Everything works.", table: "Notices")
        case .trustNotVerified: String(localized: "The audio could not be checked, so word timing may be off.", table: "Notices")
        case .trustAudioChanged: String(localized: "Word timing may not match what you hear.", table: "Notices")
        case .trustUnreadable: String(localized: "The file’s Cassini data is damaged. The audio still plays.", table: "Notices")
        case .trustNewerFormat: String(localized: "This version can’t be read here yet. The audio still plays.", table: "Notices")
        // The reason why there is no transcript (too long to transcribe), else "No transcript yet."
        case .plainAudio: args.text.flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "No transcript yet.", table: "Notices")
        // Why it can't be played when it is not Android's one reason (iOS: a container this device can't decode).
        case .unplayable:
            args.text.flatMap { $0.isEmpty ? nil : $0 }
                ?? String(localized: "Cassini closed before the recording was saved. You can still save the file.", table: "Notices")

        case .recPausedOtherApp: String(localized: "Resume when your call ends. Nothing was lost.", table: "Notices")
        case .recInputLost: String(localized: "Check your microphone, then resume. Nothing was lost.", table: "Notices")
        case .recStorageLow:
            String(localized: "Free some space to keep going. If it runs out, the recording saves automatically.", table: "Notices")
        case .recStoppedStorage:
            String(localized: "Less than \(megabytes(args.bytes)) free. The recording so far is saved.", table: "Notices")
        case .recMicOff: String(localized: "Turn it on in system settings. Recording starts when you come back.", table: "Notices")
        case .recMicFailed: String(localized: "Recording ended. The audio so far is in your library.", table: "Notices")
        case .recCouldNotStart: String(localized: "Another app may be using it. Try again.", table: "Notices")
        case .recovered: String(localized: "Cassini closed unexpectedly. We saved what was captured (\(clock(args.ms1))).", table: "Notices")
        case .recCompressionFailed: String(localized: "Compression could not finish. Your recording is safe.", table: "Notices")

        case .txPaused, .txPausedEarly:
            if args.bySystem {
                String(localized: "iOS ended the time Cassini had in the background. Resume to continue where it stopped.",
                       table: "Notices")
            } else if kind == .txPaused {
                String(localized: "Pick up where you left off. The draft so far is kept.", table: "Notices")
            } else {
                String(localized: "Resume to start transcribing.", table: "Notices")
            }
        case .txQueueHeld: String(localized: "Continue when you’re ready.", table: "Notices")
        case .txCalculating: String(localized: "An estimate appears after the first few minutes of audio.", table: "Notices")
        case .txBattery: String(localized: "Plugged in — no battery estimate needed.", table: "Notices")
        case .txOneVoice: String(localized: "Speakers couldn’t be told apart in this recording.", table: "Notices")
        case .txCheckpointMismatch: String(localized: "The recording or models changed. Your recording is kept.", table: "Notices")
        case .txFailed:
            if let text = args.text, !text.isEmpty {
                String(localized: "\(text) Your recording is kept.", table: "Notices")
            } else {
                String(localized: "Your recording is kept.", table: "Notices")
            }

        case .dlDownloading:
            // Apple's speech assets report a fraction, not bytes.
            args.bytes > 0 || args.bytes2 > 0
                ? String(localized: "\(args.bytes / mebibyte) of \(megabytes(args.bytes2)).", table: "Notices") : nil
        case .dlChecking: String(localized: "Each file is verified before it is used.", table: "Notices")
        case .dlNoConnection: String(localized: "Connect to the internet and try again. Recording still works.", table: "Notices")
        case .dlStopped:
            args.bySystem
                ? String(localized: "iOS stopped the download. Try again to continue where it stopped.", table: "Notices")
                : String(localized: "The connection dropped. Try again to continue where it stopped.", table: "Notices")
        case .dlNoSpace:
            // Without a figure the body names no size, never "0 MB".
            args.bytes > 0
                ? String(localized: "Free about \(megabytes(args.bytes)) and try again.", table: "Notices")
                : String(localized: "Free some space and try again.", table: "Notices")
        case .dlFileCheck: String(localized: "The download was damaged and has been discarded.", table: "Notices")
        case .dlInstallFailed: String(localized: "Try again. Your recordings are safe.", table: "Notices")
        case .dlRecordNow: String(localized: "Transcription needs a one-time download. Audio is safe meanwhile.", table: "Notices")

        case .libEmpty: String(localized: "Record something, or import an audio file.", table: "Notices")
        case .libNoMatch: String(localized: "Try another word or title.", table: "Notices")
        case .importing: nil
        case .importTooLarge: String(localized: "Choose a file under 4 GB.", table: "Notices")
        case .importNoSpace:
            String(localized: "This file needs about \(storage(args.bytes, locale: locale)) free. Free some space and try again.", table: "Notices")
        case .importOpen: String(localized: "It doesn’t look like audio Cassini can read.", table: "Notices")
        case .notificationsOff: String(localized: "Progress shows only in the app.", table: "Notices")
        case .voicesUnreadable:
            String(localized: "They were made by a newer Cassini or are damaged. Nothing was changed.", table: "Notices")
        case .libUnavailable: String(localized: "Your files are kept. Free some storage, then open Cassini again.", table: "Notices")
        case .notesUnreadable: String(localized: "Their files are kept on this device.", table: "Notices")
        }
    }

    static func action(_ action: BannerAction) -> String {
        switch action {
        case .resume: String(localized: "Resume", table: "Notices")
        case .startOver: String(localized: "Start over", table: "Notices")
        case .tryAgain: String(localized: "Try again", table: "Notices")
        case .transcribe: String(localized: "Transcribe", table: "Notices")
        case .transcribeAgain: String(localized: "Transcribe again", table: "Notices")
        case .playAnyway: String(localized: "Play anyway", table: "Notices")
        case .open: String(localized: "Open", table: "Notices")
        case .openNote: String(localized: "Open note", table: "Notices")
        case .openSettings: String(localized: "Open settings", table: "Notices")
        case .turnOn: String(localized: "Turn on", table: "Notices")
        case .download: String(localized: "Download", table: "Notices")
        case .downloadAgain: String(localized: "Download again", table: "Notices")
        case .retry: String(localized: "Retry", table: "Notices")
        case .cancel: String(localized: "Cancel", table: "Notices")
        case .chooseAnother: String(localized: "Choose another", table: "Notices")
        case .record: String(localized: "Record", table: "Notices")
        case .import: String(localized: "Import", table: "Notices")
        case .continue: String(localized: "Continue", table: "Notices")
        }
    }

    static var dismiss: String { String(localized: "Dismiss", table: "Notices") }

    // MARK: Formats

    private static let mebibyte: Int64 = 1_048_576
    private static let gibibyte: Int64 = 1_073_741_824

    /// "Downloading speech recognition — 46%".
    private static func downloading(_ part: ModelPart, percent: Int) -> String {
        switch part {
        case .speech: String(localized: "Downloading speech recognition — \(percent)%", table: "Notices")
        case .speakers: String(localized: "Downloading speaker separation — \(percent)%", table: "Notices")
        case .voices: String(localized: "Downloading voice recognition — \(percent)%", table: "Notices")
        }
    }

    /// "05:12", "1:02:03".
    private static func clock(_ ms: Int64) -> String { TimeText.clock(Double(ms) / 1000) }

    /// "10 min", "1 h 5 min": never under a minute.
    private static func atLeastOneMinute(_ ms: Int64) -> String {
        RecordingCopy.hoursMinutes(max(1, (ms + 30_000) / 60_000))
    }

    /// "860 MB", rounded up.
    private static func megabytes(_ bytes: Int64) -> String {
        let mb = (max(bytes, 0) + mebibyte - 1) / mebibyte
        return String(localized: "\(mb) MB", table: "Notices")
    }

    /// "1.4 GB" from a gibibyte, else megabytes.
    private static func storage(_ bytes: Int64, locale: Locale) -> String {
        guard bytes >= gibibyte else { return megabytes(bytes) }
        let gb = (Double(bytes) / Double(gibibyte)).formatted(.number.precision(.fractionLength(1)).locale(locale))
        return String(localized: "\(gb) GB", table: "Notices")
    }
}
