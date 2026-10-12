import Foundation
import CassiniNotebook

/// The words of the Library, from the Library string table: Android's copy, with "Recently Deleted" for its Trash.
enum LibraryCopy {
    static let headline = String(localized: "A little more present.", table: "Library", comment: "Library headline")
    static let headlineLarge = String(localized: "Notes", table: "Library", comment: "Library headline at accessibility text sizes")
    static let subheadline = String(localized: "Keep the conversation. Find the important parts.", table: "Library",
                                    comment: "Library line under the headline")
    static let settings = String(localized: "Settings", table: "Library", comment: "Library toolbar button")
    static let searchPlaceholder = String(localized: "Search titles and what was said", table: "Library",
                                          comment: "Library search field placeholder")
    static let clearSearch = String(localized: "Clear search", table: "Library", comment: "Library search field clear button")
    static let privacy = String(localized: "Transcribed on this device. Audio never leaves it.", table: "Library",
                                comment: "Library line under the search field")
    static let dismissNotice = String(localized: "Dismiss notice", table: "Library", comment: "VoiceOver label of a notice's close button")
    static let all = String(localized: "All", table: "Library", comment: "Library filter: every note")
    static let starred = String(localized: "Starred", table: "Library", comment: "Library filter: starred notes only")

    // MARK: Activity

    static func recordingCard(_ title: String, paused: Bool) -> String {
        paused ? String(localized: "Recording paused · \(title)", table: "Library", comment: "Library card of a paused recording")
            : String(localized: "Recording · \(title)", table: "Library", comment: "Library card of the recording in progress")
    }
    static let tapToReturn = String(localized: "Tap to return", table: "Library", comment: "Library recording card, second line")
    static let importAudio = String(localized: "Import audio", table: "Library", comment: "Library bottom bar button")
    static let record = String(localized: "Record", table: "Library", comment: "Library bottom bar button")
    static let recordDescription = String(localized: "Record a new note", table: "Library", comment: "VoiceOver label of Record")
    static func recordingButton(_ elapsed: String) -> String {
        String(localized: "Recording · \(elapsed)", table: "Library", comment: "Record button while a recording runs, with its time")
    }
    static let returnToRecording = String(localized: "Return to recording", table: "Library",
                                          comment: "VoiceOver label of the Record button and the card while recording")

    static func progressTitle(_ banner: ProgressBanner) -> String {
        guard let title = banner.title else {
            return String(localized: "Downloading models", table: "Library", comment: "Library banner of a model download on its own")
        }
        return banner.isPreparing
            ? String(localized: "Getting ready to transcribe \(title)", table: "Library", comment: "Library banner while models download for a note")
            : String(localized: "Transcribing \(title)", table: "Library", comment: "Library banner while a note is transcribed")
    }

    /// Line 2 of the banner, with "· N more in queue".
    static func progressLine(_ banner: ProgressBanner) -> String {
        let line = switch banner.line {
        case .timeLeft(let timeLeft): ProgressText.timeLeftLine(timeLeft)
        case .waiting: ProgressText.headline(.waitingForPrevious)
        case .downloading(let part, let percent): downloading(part, percent)
        case .checking(let percent):
            String(localized: "Checking files — \(percent)%", table: "Library", comment: "Library banner: downloaded models are checked")
        }
        guard banner.queued > 0 else { return line }
        let more = String(localized: "\(banner.queued) more in queue", table: "Library", comment: "Library banner: notes waiting")
        return "\(line) · \(more)"
    }

    private static func downloading(_ part: ModelPart, _ percent: Int) -> String {
        switch part {
        case .speech: String(localized: "Downloading speech recognition — \(percent)%", table: "Library", comment: "Library banner")
        case .speakers: String(localized: "Downloading speaker separation — \(percent)%", table: "Library", comment: "Library banner")
        case .voices: String(localized: "Downloading voice recognition — \(percent)%", table: "Library", comment: "Library banner")
        }
    }

    static let openNote = String(localized: "Open note", table: "Library", comment: "VoiceOver hint of a row and the banner")
    static let openSettings = String(localized: "Open settings", table: "Library", comment: "VoiceOver hint of the download banner")

    // MARK: Rows

    static func status(_ status: LibraryRow.Status) -> String {
        switch status {
        case .recording: String(localized: "Recording", table: "Library", comment: "Row status")
        case .transcribing: String(localized: "Transcribing", table: "Library", comment: "Row status")
        case .queued: String(localized: "Queued", table: "Library", comment: "Row status")
        case .paused(let atMs): pausedAt(TimeText.clock(Double(atMs) / 1000))
        case .failed: String(localized: "Couldn’t transcribe", table: "Library", comment: "Row status")
        case .unplayable: String(localized: "Can’t play", table: "Library", comment: "Row status")
        case .unreadable: String(localized: "Can’t read transcript", table: "Library", comment: "Row status")
        case .newerFormat: String(localized: "Newer format", table: "Library", comment: "Row status")
        case .transcribed: String(localized: "Transcribed", table: "Library", comment: "Row status")
        case .audioOnly: String(localized: "Audio only", table: "Library", comment: "Row status")
        }
    }

    private static func pausedAt(_ clock: String) -> String {
        String(localized: "Paused at \(clock)", table: "Library", comment: "Row status: where it stopped")
    }

    /// "· Resume", "· Try again", "· No speech", "· 3 speakers"; nil without a suffix.
    static func suffix(_ status: LibraryRow.Status) -> String? {
        switch status.suffix {
        case .none: nil
        case .resume: String(localized: "· Resume", table: "Library", comment: "Row suffix: an inline button")
        case .tryAgain: String(localized: "· Try again", table: "Library", comment: "Row suffix: an inline button")
        case .noSpeech: String(localized: "· No speech", table: "Library", comment: "Row suffix: transcribed without words")
        case .speakers:
            if case .transcribed(let speakers, _) = status {
                String(localized: "· \(speakers) speakers", table: "Library", comment: "Row suffix: the number of speakers")
            } else { nil }
        }
    }

    static func resumeDescription(_ title: String) -> String {
        String(localized: "Resume transcribing \(title)", table: "Library", comment: "VoiceOver label of the inline Resume")
    }
    static func tryAgainDescription(_ title: String) -> String {
        String(localized: "Try transcribing \(title) again", table: "Library", comment: "VoiceOver label of the inline Try again")
    }

    static let today = String(localized: "Today", table: "Library", comment: "Day header")
    static let yesterday = String(localized: "Yesterday", table: "Library", comment: "Day header")
    static let todayInline = String(localized: "today", table: "Library", comment: "Day inside a sentence, for VoiceOver")
    static let yesterdayInline = String(localized: "yesterday", table: "Library", comment: "Day inside a sentence, for VoiceOver")
    /// "Today, 09:12" on the meta line of a search result.
    static func dayTime(_ day: String, _ time: String) -> String {
        String(localized: "\(day), \(time)", table: "Library", comment: "A search result's day and time")
    }
    /// "today 10:02" for VoiceOver.
    static func spokenDayTime(_ day: String, _ time: String) -> String {
        String(localized: "\(day) \(time)", table: "Library", comment: "A row's day and time for VoiceOver")
    }
    static let starredLabel = String(localized: "Starred", table: "Library", comment: "VoiceOver: the note is starred")

    // MARK: Actions

    static let star = String(localized: "Star", table: "Library", comment: "Note action (iOS extra)")
    static let removeStar = String(localized: "Remove star", table: "Library", comment: "Note action (iOS extra)")
    static let rename = String(localized: "Rename", table: "Library", comment: "Note action and its dialog title")
    static let resume = String(localized: "Resume", table: "Library", comment: "Note action")
    static let tryAgain = String(localized: "Try again", table: "Library", comment: "Note action")
    static let transcribe = String(localized: "Transcribe", table: "Library", comment: "Note action")
    static let transcribeAgain = String(localized: "Transcribe again", table: "Library", comment: "Note action")
    static func addsVersion(_ number: Int) -> String {
        String(localized: "Adds version \(number).", table: "Library", comment: "Under Transcribe again")
    }
    static let namesCarry = String(localized: "Speaker names carry over.", table: "Library", comment: "Under Transcribe again")
    static let noNewVersion = String(localized: "This file can’t take a new version here.", table: "Library",
                                     comment: "Under a Transcribe again that cannot run")
    static let stop = String(localized: "Stop and keep progress", table: "Library", comment: "Note action while it transcribes")
    static let removeFromQueue = String(localized: "Remove from queue", table: "Library", comment: "Note action while queued")
    static let startOver = String(localized: "Start over", table: "Library", comment: "Note action of a paused transcription")
    static let startOverTitle = String(localized: "Start over?", table: "Library", comment: "Start over confirmation title")
    static let startOverBody = String(localized: "The draft so far is discarded. Your recording is kept.", table: "Library",
                                      comment: "Start over confirmation body")
    static let freshTitle = String(localized: "Transcribe again?", table: "Library", comment: "Confirmation title")
    static let freshBody = String(localized: "Earlier versions can’t be kept because the audio changed.", table: "Library",
                                  comment: "Confirmation before a Transcribe again that replaces the versions")
    static let export = String(localized: "Export", table: "Library", comment: "Note actions submenu")
    static let documentInfo = String(localized: "Document info", table: "Library", comment: "Note action")
    static let cancel = String(localized: "Cancel", table: "Library", comment: "Dialog button")
    static let save = String(localized: "Save", table: "Library", comment: "Rename dialog button")
    static let titleLabel = String(localized: "Title", table: "Library", comment: "Rename dialog field")
    static let titleBlank = String(localized: "Enter a title.", table: "Library", comment: "Rename dialog error")

    // MARK: Empty states

    static let unavailableTitle = String(localized: "Your notes can’t be opened", table: "Library", comment: "The library could not be read")
    static let noStarredTitle = String(localized: "Keep your favorites close.", table: "Library", comment: "Starred filter with nothing (iOS extra)")
    static let noStarredBody = String(localized: "Star a note to find it here.", table: "Library", comment: "Starred filter with nothing (iOS extra)")
}
