import Foundation
import CassiniEngine
import CassiniNotebook

/// The words of the results notifications, from the Notices table.
enum NotificationCopy {
    struct Text: Equatable {
        var title: String
        var body: String
    }

    static func text(_ notification: ResultNotification) -> Text {
        let title = notification.title
        switch notification.kind {
        case .transcribed(let speakers, let duration):
            let clock = ExportClock.clock(Int64(duration * 1000), durationMs: Int64(duration * 1000))
            return Text(title: String(localized: "Transcribed: \(title)", table: "Notices"),
                        body: speakers > 0 ? String(localized: "\(speakers) speakers · \(clock)", table: "Notices") : clock)
        case .failed(let failure):
            return Text(title: String(localized: "Couldn’t transcribe \(title)", table: "Notices"), body: failureText(failure))
        case .readyToTranscribe:
            return Text(title: String(localized: "Ready to transcribe", table: "Notices"),
                        body: String(localized: "\(title) is waiting. Open Cassini to start.", table: "Notices"))
        case .pausedBySystem:
            // The job's stop reaches the queue before its last progress is saved, so no "Paused at" numbers.
            return Text(title: String(localized: "Transcription paused by iOS", table: "Notices"),
                        body: String(localized: "iOS needed the time back. Open Cassini to resume.", table: "Notices"))
        case .transcriptionStopped:
            return Text(title: String(localized: "Transcription stopped", table: "Notices"),
                        body: String(localized: "Cassini closed while transcribing \(title).", table: "Notices"))
        case .recordingStopped:
            let floor = Limits.minRecordingFreeBytes / 1_048_576
            return Text(title: String(localized: "Recording stopped", table: "Notices"),
                        body: String(localized: "Less than \(floor) MB free. The recording so far is saved.", table: "Notices"))
        case .microphoneFailed:
            return Text(title: String(localized: "Microphone stopped working", table: "Notices"),
                        body: String(localized: "Recording ended. The audio so far is in your library.", table: "Notices"))
        }
    }

    /// What the Lock Screen shows with previews hidden: never the note's title.
    static func placeholder(_ category: NotificationCategory) -> String {
        switch category {
        case .transcribed: String(localized: "A note was transcribed", table: "Notices")
        case .failed: String(localized: "A note couldn’t be transcribed", table: "Notices")
        case .ready: String(localized: "A note is waiting. Open Cassini to start.", table: "Notices")
        case .paused: String(localized: "Open Cassini to resume.", table: "Notices")
        case .stopped: String(localized: "Cassini closed while transcribing a note.", table: "Notices")
        case .recordingStopped: String(localized: "Recording stopped", table: "Notices")
        case .microphoneFailed: String(localized: "Microphone stopped working", table: "Notices")
        }
    }

    static var resume: String { String(localized: "Resume", table: "Notices") }

    /// The text of a failed job's code.
    static func failureText(_ failure: JobFailure) -> String {
        switch failure {
        case .download(.noConnection):
            String(localized: "No connection. Connect to the internet and try again.", table: "Notices")
        case .checkpointMismatch:
            String(localized: "Saved progress no longer matches. Your recording is kept.", table: "Notices")
        case .documentRefused:
            String(localized: "This transcript can’t take a new version. Your recording is kept.", table: "Notices")
        default:
            failure.transcriptionMessage
        }
    }
}
