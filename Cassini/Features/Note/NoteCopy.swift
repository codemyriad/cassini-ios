import Foundation
import CassiniEngine
import CassiniNotebook

/// The words of the Note screen, from the Note string table: Android's English copy (with "device" for "phone").
enum NoteCopy {
    // MARK: Header and menu

    static let searchInTranscript = String(localized: "Search in transcript", table: "Note")
    static let shareAndMore = String(localized: "Share and more", table: "Note", comment: "The Note screen's actions button (Android ui_note_share_more)")
    static let star = String(localized: "Star", table: "Note", comment: "Menu: star the note")
    static let removeStar = String(localized: "Remove star", table: "Note")
    static let speakers = String(localized: "Speakers", table: "Note")
    static let versions = String(localized: "Transcript versions", table: "Note")
    static let rename = String(localized: "Rename", table: "Note")
    static let documentInfo = String(localized: "Document info", table: "Note")
    static let exportTranscript = String(localized: "Export transcript", table: "Note")
    static let exportDocument = String(localized: "Export Cassini document", table: "Note")
    static let preparingDocument = String(localized: "Preparing Cassini document…", table: "Note")
    static let shareAudio = String(localized: "Share original audio", table: "Note")
    static let transcribe = String(localized: "Transcribe", table: "Note")
    static let transcribeAgain = String(localized: "Transcribe again", table: "Note")
    static let noNewVersion = String(localized: "This file can’t take a new version here.", table: "Note")
    static let stopKeepProgress = String(localized: "Stop and keep progress", table: "Note")
    static let removeFromQueue = String(localized: "Remove from queue", table: "Note")
    static let resume = String(localized: "Resume", table: "Note")
    static let startOver = String(localized: "Start over", table: "Note")
    static let close = String(localized: "Close", table: "Note")
    static let cancel = String(localized: "Cancel", table: "Note")

    /// "Today, 10:02 · 48:13", "Monday 5 Oct, 10:02 · 48:13": the day as the Library heads it (`DateLabels.day`).
    static func subtitle(_ subtitle: NoteSubtitle, calendar: Calendar) -> String {
        let dates = DateLabels(calendar: calendar)
        let day = dates.day(subtitle.day), time = dates.time(subtitle.createdAt)
        return String(localized: "\(day), \(time) · \(TimeText.clock(subtitle.duration))", table: "Note",
                      comment: "The Note screen's subtitle: day, time of day and duration (Today, 10:02 · 48:13)")
    }

    // MARK: Read-only and dialogs

    static func readOnly(_ reason: ReadOnlyReason) -> String {
        switch reason {
        case .jobPending: String(localized: "Wait until transcription finishes", table: "Note")
        case .trust: String(localized: "Fix the transcript first: Transcribe again", table: "Note")
        }
    }

    static let startOverTitle = String(localized: "Start over?", table: "Note")
    static let startOverBody = String(localized: "The draft so far is discarded. Your recording is kept.", table: "Note")
    static let freshTitle = String(localized: "Transcribe again?", table: "Note")
    static let freshBody = String(localized: "Earlier versions can’t be kept because the audio changed.", table: "Note")

    // MARK: Transcript

    static let noSpeechTitle = String(localized: "No speech", table: "Note")
    static let noSpeechBody = String(localized: "No words were found in this recording.", table: "Note")
    static let draftTitle = String(localized: "Draft transcript", table: "Note")
    static let draftTag = String(localized: "Words may still change", table: "Note")
    static let nameThisSpeaker = String(localized: "Name this speaker", table: "Note")
    static let auto = String(localized: "auto", table: "Note", comment: "Badge of a speaker named automatically from a saved voice")
    static let playFromStartOfTurn = String(localized: "Play from start of turn", table: "Note")
    static let followPlayback = String(localized: "Follow playback", table: "Note")
    static let editPassage = String(localized: "Edit passage", table: "Note")
    static let markThisMoment = String(localized: "Mark this moment", table: "Note")

    // MARK: Bookmarks (an iOS extra)

    static func markedMoments(_ count: Int) -> String {
        String(localized: "\(count) marked moments", table: "Note", comment: "The bookmarks section of a note: 3 marked moments")
    }
    static let removeBookmark = String(localized: "Remove bookmark", table: "Note")
    /// The user's label, or "Moment at 01:05" for a moment marked without one.
    static func bookmarkLabel(_ bookmark: Bookmark) -> String {
        bookmark.label ?? String(localized: "Moment at \(TimeText.clock(bookmark.time))", table: "Note",
                                 comment: "A bookmark without a label of its own, named by its time")
    }
    static let copyText = String(localized: "Copy text", table: "Note")
    static let unknownSpeaker = String(localized: "Unknown speaker", table: "Note", comment: "A passage without a speaker")

    /// A speaker's stored label as every screen shows it: a placeholder ("Speaker 2", which a note may hold in English
    /// or Italian) in the reader's language, "Speaker `ordinal + 1`" for a blank one, any other label as it is.
    static func speakerLabel(_ label: String, id: String, ordinal: Int) -> String {
        speakerName(NoteTranscripts.name(label: label, id: id, ordinal: ordinal))
    }

    static func speakerName(_ name: SpeakerName) -> String {
        switch name {
        case .named(let text): text
        case .placeholder(let number): String(localized: "Speaker \(number)", table: "Note")
        case .unknown: unknownSpeaker
        }
    }

    /// "Giulia, named automatically, at 11 minutes 41 seconds".
    static func turn(_ name: String, start: TimeInterval, auto: Bool) -> String {
        let time = spokenTime(start)
        return auto
            ? String(localized: "\(name), named automatically, at \(time)", table: "Note")
            : String(localized: "\(name), at \(time)", table: "Note")
    }

    static func editPassage(at start: TimeInterval) -> String {
        String(localized: "Passage at \(TimeText.clock(start))", table: "Note")
    }

    /// A time for VoiceOver: "11 minutes, 41 seconds".
    static func spokenTime(_ seconds: TimeInterval) -> String {
        Duration.seconds(Int(seconds.rounded(.down)))
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .wide, zeroValueUnits: .hide))
            .ifEmpty(Duration.seconds(0).formatted(.units(allowed: [.seconds], width: .wide)))
    }

    // MARK: Chips

    static func speakerCount(_ count: Int) -> String { String(localized: "\(count) speakers", table: "Note") }

    static func version(_ chip: VersionChip) -> String {
        let base = String(localized: "Version \(chip.index) of \(chip.count)", table: "Note")
        switch chip.kind {
        case .original: return base
        case .merged: return base + " " + String(localized: "· speakers merged", table: "Note")
        case .edited: return base + " " + String(localized: "· edited", table: "Note")
        case .transcribedAgain: return base + " " + String(localized: "· transcribed again", table: "Note")
        }
    }


    // MARK: Search

    static func searchCounter(current: Int, total: Int) -> String {
        total == 0 ? String(localized: "No matches", table: "Note")
            : String(localized: "\(current) of \(total)", table: "Note", comment: "In-note search: the current match of all")
    }
    static let closeSearch = String(localized: "Close search", table: "Note")
    static let previousMatch = String(localized: "Previous match", table: "Note")
    static let nextMatch = String(localized: "Next match", table: "Note")

    // MARK: Passage editor

    static let passageText = String(localized: "Passage text", table: "Note")
    static let speaker = String(localized: "Speaker", table: "Note")
    static let unassigned = String(localized: "Unassigned", table: "Note")
    static let speakerFooter = String(localized: "Assign this passage to a speaker. Rename or merge people from Speakers.", table: "Note")
    static let save = String(localized: "Save", table: "Note")

    // MARK: Rename and the missing note

    static let unavailableTitle = String(localized: "Recording unavailable", table: "Note")
    static let unavailableBody = String(localized: "Return to your library to choose a recording.", table: "Note")
    static let backToLibrary = String(localized: "Back to library", table: "Note")
    static let passageChanged = String(localized: "This passage changed while you were editing.", table: "Note")
    static let passageLocked = String(localized: "Wait until transcription finishes", table: "Note")
}

private extension String {
    func ifEmpty(_ fallback: @autoclosure () -> String) -> String { isEmpty ? fallback() : self }
}
