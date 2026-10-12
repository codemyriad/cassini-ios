import CassiniCore
import Foundation

/// The mode of the Note screen (Android `NoteMode`): one destination whose body follows the note's job and audio.
public enum NoteMode: Hashable, Sendable {
    /// A plain note (or one whose job waits for consent): the plain audio banner and the player.
    case audioOnly
    /// A queued job: the Queued card, `ahead` jobs before it; over a transcript, the reading content follows.
    case queued(ahead: Int, overDocument: Bool)
    /// A running job: the progress card and the draft. No player.
    case processing
    /// A stopped job at `doneMs` of `totalMs`: the pause banner, the read-only draft and the player.
    case paused(doneMs: Int64, totalMs: Int64, hasCheckpoint: Bool)
    /// A failed job: the failure banner; over a transcript, the reading content follows, else the draft so far.
    case failed(overDocument: Bool)
    /// A transcript and no job.
    case reading
    /// The audio cannot play: the unplayable banner and no player.
    case unplayable

    /// The mode for `note` with its `job` (nil without one); `ahead` counts the jobs that run before a queued one.
    /// First match wins: unplayable, queued, processing, paused, failed, reading, audio only.
    public static func of(_ note: Note, job: Job?, ahead: Int = 0) -> NoteMode {
        let document = note.hasDocument
        if case .unplayable = note.audio { return .unplayable }
        switch job?.state {
        case .queued?: return .queued(ahead: ahead, overDocument: document)
        case .running?: return .processing
        case .paused?:
            let job = job!
            let total = job.totalMs ?? Int64((note.duration * 1000).rounded())
            return .paused(doneMs: job.doneMs, totalMs: max(total, job.doneMs), hasCheckpoint: job.doneMs > 0)
        case .failed?: return .failed(overDocument: document)
        case .needsConsent?, nil: return document ? .reading : .audioOnly
        }
    }

    /// The mode shows the job's draft rather than the note's transcript.
    public var showsDraft: Bool {
        switch self {
        case .processing, .paused: true
        case .failed(let overDocument): !overDocument
        default: false
        }
    }

    /// The mode has a player: all but processing and unplayable.
    public var hasPlayer: Bool {
        switch self {
        case .processing, .unplayable: false
        default: true
        }
    }

    /// The reading content (transcript, chips, trust banner) shows, alone or below a card or banner.
    public var showsReading: Bool {
        switch self {
        case .reading: true
        case .queued(_, let overDocument), .failed(let overDocument): overDocument
        default: false
        }
    }
}

extension Note {
    /// The note has a transcript to read, was transcribed and found no words, or came from a Cassini document (whose
    /// transcript may be unreadable): it opens in reading mode (Android's DOCUMENT audio kind).
    public var hasDocument: Bool { !transcript.isEmpty || document != nil || status == .ready }

    /// "No speech" shows only for a transcript that was read and has no words: not for a draft, and not for a
    /// document whose transcript cannot be read.
    public func saysNoSpeech(in mode: NoteMode) -> Bool {
        guard mode.showsReading, !mode.showsDraft, transcript.isEmpty else { return false }
        switch document?.state {
        case .unreadable?, .invalidMetadata?, .unknownFormat?: return false
        default: return true
        }
    }
}

/// Why the shown transcript cannot be renamed, merged, switched or edited now, and the message an attempt shows.
public enum ReadOnlyReason: Hashable, Sendable {
    /// "Wait until transcription finishes": the note has a job.
    case jobPending
    /// "Fix the transcript first: Transcribe again": a document whose trust is not verified.
    case trust

    /// The reason for `note` with its `job`, or nil when the transcript can be changed. A job waiting for consent does
    /// not count. Speakers are named only after a job on iOS, so there is no draft naming to close (Android SAVING).
    public static func of(_ note: Note, job: Job?) -> ReadOnlyReason? {
        if let job, job.state != .needsConsent { return .jobPending }
        if let document = note.document, document.state != .ok { return .trust }
        return nil
    }
}

/// The version chip: "Version `index` of `count`" plus the suffix of `kind`.
public struct VersionChip: Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case original, merged, edited, transcribedAgain }
    public var index: Int
    public var count: Int
    public var kind: Kind
}

/// The chips row of the reading content: the trust chip of a document, the version chip from 2 versions on and the
/// speaker count.
public struct NoteChips: Hashable, Sendable {
    public var trust: DocumentTrust?
    public var version: VersionChip?
    public var speakers: Int

    public static func of(_ note: Note) -> NoteChips? {
        guard note.hasDocument else { return nil }
        let speakers = Set(note.transcript.compactMap(\.speakerID)).count
        return NoteChips(trust: DocumentTrust.of(note), version: versionChip(note), speakers: speakers)
    }

    /// Versions are numbered from 1 in the order they were kept; the transcript shown is the selected kept one, or a
    /// new one after them when nothing kept holds it.
    static func versionChip(_ note: Note) -> VersionChip? {
        let versions = note.versions ?? []
        let shown = note.mergeVersionNumbers.shown
        let count = note.versionCount
        guard count >= 2 else { return nil }
        let kind: VersionChip.Kind = switch versions.indices.contains(shown - 1) ? versions[shown - 1].name : nil {
        case Note.mergedVersionName?: .merged
        case Note.editedVersionName?: .edited
        default: shown > 1 ? .transcribedAgain : .original
        }
        return VersionChip(index: shown, count: count, kind: kind)
    }
}

extension Note {
    /// The name `mergeSpeaker` gives the version it adds.
    public static let mergedVersionName = "Merged speakers"
}

/// What a Transcribe again does to a document (Android `LibraryMapping.transcribeAgainRefused` and
/// `needsFreshConfirmation`).
public enum TranscribeAgainRule {
    /// The document cannot take a new version here (unverified or newer format).
    public static func refused(_ note: Note) -> Bool {
        guard let state = note.document?.state else { return false }
        return state == .unverified || state == .unknownFormat
    }

    /// Transcribe again makes a fresh document, which asks first ("Earlier versions can't be kept…").
    public static func needsFreshConfirmation(_ note: Note) -> Bool {
        guard let state = note.document?.state else { return false }
        return state == .staleAudio || state == .unreadable || state == .invalidMetadata
    }
}

/// The header subtitle outside reading mode: "Today, 10:02 · 48:13".
public struct NoteSubtitle: Hashable, Sendable {
    public enum Day: Hashable, Sendable {
        case today, yesterday
        /// The start of another day.
        case date(Date)
    }

    public var day: Day
    public var createdAt: Date
    public var duration: TimeInterval

    /// Nil in reading mode, whose header has the search and the chips instead.
    public static func of(_ note: Note, mode: NoteMode, now: Date, calendar: Calendar) -> NoteSubtitle? {
        guard mode != .reading else { return nil }
        let day = calendar.startOfDay(for: note.createdAt)
        let today = calendar.startOfDay(for: now)
        let label: Day = if day == today {
            .today
        } else if calendar.date(byAdding: .day, value: -1, to: today) == day {
            .yesterday
        } else {
            .date(day)
        }
        return NoteSubtitle(day: label, createdAt: note.createdAt, duration: note.duration)
    }
}
