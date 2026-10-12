import CassiniCore
import Foundation

/// The live facts every Library row needs besides its note: the note that records now and its elapsed time, and the
/// note whose job runs now.
public struct RowContext: Hashable, Sendable {
    public var activeNoteID: UUID?
    public var recordingElapsed: TimeInterval
    public var runningNoteID: UUID?
    /// Each note's job.
    public var jobs: [UUID: Job]

    public init(activeNoteID: UUID? = nil, recordingElapsed: TimeInterval = 0, runningNoteID: UUID? = nil,
                jobs: [UUID: Job] = [:]) {
        self.activeNoteID = activeNoteID; self.recordingElapsed = recordingElapsed; self.runningNoteID = runningNoteID
        self.jobs = jobs
    }

    /// The context of `processing` while `recording` runs.
    public init(processing: ProcessingState, recording: RecordingState) {
        let active = recording.activeRecording
        let activeNoteID: UUID? = switch recording {
        case .active(let active): active.noteID
        case .finishing(let noteID): noteID
        default: nil
        }
        self.init(activeNoteID: activeNoteID, recordingElapsed: active?.elapsed ?? 0,
                  runningNoteID: processing.running?.noteID, jobs: processing.jobs)
    }

    /// The state of `id`'s job, running when the queue says it runs.
    func jobState(_ id: UUID) -> JobState? { runningNoteID == id ? .running : jobs[id]?.state }
}

/// One Library row (Android `NoteRowUi`).
public struct LibraryRow: Identifiable, Hashable, Sendable {
    /// The status chip with what its text needs.
    public enum Status: Hashable, Sendable {
        case recording, transcribing, queued
        case paused(atMs: Int64)
        case failed, unplayable, unreadable, newerFormat
        case transcribed(speakers: Int, hasWords: Bool)
        case audioOnly

        public var suffix: RowStatus.Suffix {
            switch self {
            case .paused: .resume
            case .failed: .tryAgain
            case .transcribed(let speakers, let hasWords): RowStatus.suffix(.transcribed, speakerCount: speakers, hasWords: hasWords)
            default: .none
            }
        }
    }

    public var id: UUID
    public var title: String
    public var titleRanges: [Range<Int>]
    /// The recording's elapsed time while it records.
    public var duration: TimeInterval
    public var createdAt: Date
    /// Set in the flat search results only; day sections carry the day in their header.
    public var day: DayKey?
    public var status: Status
    public var preview: Highlighted?
    /// The note whose job runs: drawn on the card surface.
    public var highlighted: Bool
    /// The note being recorded: a tap returns to the Recording screen.
    public var isRecording: Bool
    public var isFavorite: Bool
    public var bookmarkCount: Int
}

/// One day of the Library.
public struct DaySection: Identifiable, Hashable, Sendable {
    public var key: DayKey
    public var rows: [LibraryRow]
    public var id: DayKey { key }
}

/// The transcription banner of the activity area (Android `ProgressBannerUi`).
public struct ProgressBanner: Hashable, Sendable {
    /// Line 2.
    public enum Line: Hashable, Sendable {
        case timeLeft(TimeLeft)
        /// "Finishing the previous note…"
        case waiting
        case downloading(ModelPart, percent: Int)
        case checking(percent: Int)
    }

    /// The running note, which a tap opens; nil for a download on its own, which opens Settings.
    public var noteID: UUID?
    /// The running note's title; nil for "Downloading models".
    public var title: String?
    public var percent: Int?
    /// The bar, 0 to 1; hidden when nil.
    public var fraction: Double?
    public var line: Line
    /// Notes waiting after the running one ("· N more in queue").
    public var queued: Int

    /// The title reads "Getting ready to transcribe …" while models are installed.
    public var isPreparing: Bool {
        switch line {
        case .downloading, .checking: true
        case .timeLeft, .waiting: false
        }
    }

    /// What line 2 is about, without its numbers.
    public enum Stage: Hashable, Sendable {
        /// The time left, or working it out; a new estimate is not a new stage.
        case timeLeft
        /// Nothing is left but saving.
        case finishing
        case waiting
        case downloading(ModelPart)
        case checking
    }

    public var stage: Stage {
        switch line {
        case .timeLeft(.finishing): .finishing
        case .timeLeft: .timeLeft
        case .waiting: .waiting
        case .downloading(let part, _): .downloading(part)
        case .checking: .checking
        }
    }

    /// The percent VoiceOver hears: the banner's, or while models are installed the download's or the check's.
    public var spokenPercent: Int? {
        if let percent { return percent }
        switch line {
        case .downloading(_, let percent), .checking(let percent): return percent
        case .timeLeft, .waiting: return nil
        }
    }

    public static let announceStep = 5

    /// When VoiceOver hears the banner: at each change of its title or stage, and at each 5 % step, not at every
    /// update.
    public struct Announcement: Hashable, Sendable {
        public var title: String?
        public var stage: Stage
        public var step: Int?
    }

    public var announcement: Announcement {
        Announcement(title: title, stage: stage, step: spokenPercent.map { $0 / Self.announceStep * Self.announceStep })
    }
}

/// What the transcribe item of a note's actions does, by its job (features.md section 6).
public enum TranscribeAction: Hashable, Sendable {
    case transcribe
    /// "Adds version N." and, when `namesCarry`, "Speaker names carry over."
    case transcribeAgain(nextVersion: Int, namesCarry: Bool)
    /// "This file can’t take a new version here."
    case transcribeAgainUnavailable
    /// Stop and keep progress.
    case stop
    case removeFromQueue
    /// Resume, and Start over after a confirmation.
    case resumeOrStartOver
}

/// What the Library shows instead of rows, or above none (Android banners LIB_EMPTY, LIB_NO_MATCH, LIB_UNAVAILABLE).
public enum LibraryEmptyState: Hashable, Sendable {
    /// "No notes yet", with Record and Import.
    case empty
    /// "Nothing matches “q”".
    case noMatch(String)
    /// "Your notes can't be opened": not the same as an empty library.
    case unavailable
    /// The Starred filter (an iOS extra) has nothing.
    case noStarred
}

/// The pure mapping from the notes, the queue and the recorder to what the Library shows (Android `LibraryMapping`).
public enum LibraryMapping {
    /// The status chip of `note` in `context` (`RowStatus.of`, first match wins) with the values its text needs.
    public static func status(_ note: Note, context: RowContext, speakerCount: Int = 0, hasWords: Bool = true) -> LibraryRow.Status {
        let facts = RowFacts(note, jobState: context.jobState(note.id), activeNoteID: context.activeNoteID)
        switch RowStatus.of(facts) {
        case .recording: return .recording
        case .transcribing: return .transcribing
        case .queued: return .queued
        case .paused: return .paused(atMs: context.jobs[note.id]?.doneMs ?? 0)
        case .failed: return .failed
        case .unplayable: return .unplayable
        case .unreadable: return .unreadable
        case .newerFormat: return .newerFormat
        case .transcribed: return .transcribed(speakers: speakerCount, hasWords: hasWords)
        case .audioOnly: return .audioOnly
        }
    }

    /// A search match of one row: its day, the highlighted title and the snippet that replaces the preview.
    public struct Hit: Hashable, Sendable {
        public var day: DayKey
        public var title: String?
        public var titleRanges: [Range<Int>] = []
        public var snippet: Highlighted?
    }

    /// One row; `hit` is set in the flat search results only.
    public static func row(_ entry: LibraryIndex.Entry, context: RowContext, hit: Hit? = nil) -> LibraryRow {
        let note = entry.note
        let recording = note.id == context.activeNoteID && note.audio == .live
        return LibraryRow(
            id: note.id, title: hit?.title ?? note.title, titleRanges: hit?.titleRanges ?? [],
            duration: recording ? context.recordingElapsed : note.duration, createdAt: note.createdAt, day: hit?.day,
            status: status(note, context: context, speakerCount: entry.speakerCount, hasWords: entry.hasWords),
            preview: hit.map(\.snippet) ?? entry.preview,
            highlighted: context.jobState(note.id) == .running,
            isRecording: recording, isFavorite: note.isFavorite, bookmarkCount: note.bookmarks.count)
    }

    /// The day sections of `entries` (newest first), grouped by the local day of their creation at `now`.
    public static func sections(_ entries: [LibraryIndex.Entry], context: RowContext, now: Date,
                                calendar: Calendar) -> [DaySection] {
        DayGroups.group(entries, now: now, calendar: calendar) { $0.note.createdAt }
            .map { DaySection(key: $0.key, rows: $0.items.map { row($0, context: context) }) }
    }

    /// The flat search results, newest first, each with its day. The transcript snippet is the preview when it has a
    /// match; a title-only match highlights the title and shows no snippet. A title that the snippet cut (a very
    /// long title) is shown plain, without ranges.
    public static func results(_ hits: [LibraryIndex.Hit], context: RowContext, now: Date, calendar: Calendar) -> [LibraryRow] {
        hits.map { found in
            let title = Highlighted(marked: found.titleSnippet)
            let shownTitle = title.text.isEmpty || title.leadingEllipsis || title.trailingEllipsis ? nil : title
            let snippet = found.snippet.contains(Highlighted.matchStart) ? Highlighted(marked: found.snippet) : nil
            let hit = Hit(day: DayGroups.key(found.entry.note.createdAt, now: now, calendar: calendar),
                          title: shownTitle?.text, titleRanges: shownTitle?.ranges ?? [], snippet: snippet)
            return row(found.entry, context: context, hit: hit)
        }
    }

    /// The stored preview: `Note.previewText` in its display form (`PreviewText`, with its ellipses). A stored text
    /// without ellipses that fills the 160 characters (the start of a transcript, as older notes stored it) is cut at
    /// a word here, with a trailing ellipsis.
    public static func storedPreview(_ stored: String?) -> Highlighted? {
        guard let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let parsed = Highlighted(marked: stored)
        let fallback = !parsed.leadingEllipsis && !parsed.trailingEllipsis && stored.unicodeScalars.count >= PreviewText.limit
        return fallback ? Highlighted(cutAtWord(stored), trailingEllipsis: true) : parsed
    }

    private static func cutAtWord(_ text: String) -> String {
        let end = text.lastIndex(of: " ").flatMap { $0 > text.startIndex ? $0 : nil } ?? text.endIndex
        let cut = String(text[..<end].reversed().drop { PreviewText.cutPunctuation.contains($0) || $0.isWhitespace }.reversed())
        return cut.isEmpty ? text : cut
    }

    // MARK: The activity area

    /// The recording card and the Record button's recording form, while a capture is active.
    public struct RecordingCard: Hashable, Sendable {
        public var noteID: UUID
        public var title: String
        public var elapsed: TimeInterval
        public var paused: Bool
    }

    public static func recordingCard(_ state: RecordingState) -> RecordingCard? {
        guard let active = state.activeRecording else { return nil }
        let title = active.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return RecordingCard(noteID: active.noteID, title: title.isEmpty ? active.defaultTitle : active.title,
                             elapsed: active.elapsed, paused: active.pause != nil)
    }

    /// The transcription banner while a job runs (`phase` is its progress, nil before the first report) or a model
    /// download runs on its own (`install`). The queue suffix counts the notes waiting after the running one.
    public static func progress(_ state: ProcessingState, phase: JobPhase?, install: DownloadFact? = nil) -> ProgressBanner? {
        guard let running = state.running else { return standaloneDownload(install, queued: state.queue.count) }
        let queued = state.queue.count
        func banner(percent: Int? = nil, fraction: Double? = nil, _ line: ProgressBanner.Line) -> ProgressBanner {
            ProgressBanner(noteID: running.noteID, title: running.title, percent: percent, fraction: fraction, line: line,
                           queued: queued)
        }
        switch phase ?? .starting {
        case .starting: return banner(.timeLeft(.calculating))
        case .stopping: return banner(.timeLeft(.finishing))
        case .waitingForPrevious: return banner(.waiting)
        case .downloading(let download):
            let line = downloadLine(download)
            return banner(fraction: fill(line), line)
        case .transcribing(let progress, _):
            if let download = progress.download {
                let line = downloadLine(download)
                return banner(fraction: fill(line), line)
            }
            return banner(percent: progress.percent, fraction: progress.percent.map { Double($0) / 100 },
                          .timeLeft(progress.timeLeft))
        }
    }

    /// The banner of a download from Settings or the model download screen: no note, "Downloading models".
    private static func standaloneDownload(_ install: DownloadFact?, queued: Int) -> ProgressBanner? {
        guard let install, install.failure == nil else { return nil }
        let percent = Int(((install.fraction ?? 0) * 100).rounded(.down))
        let line = ProgressBanner.Line.downloading(install.part, percent: percent)
        return ProgressBanner(noteID: nil, title: nil, percent: nil, fraction: fill(line), line: line, queued: queued)
    }

    private static func downloadLine(_ progress: DownloadProgress?) -> ProgressBanner.Line {
        guard let progress else { return .downloading(.speech, percent: 0) }
        return progress.verifying ? .checking(percent: progress.percent) : .downloading(progress.part, percent: progress.percent)
    }

    private static func fill(_ line: ProgressBanner.Line) -> Double? {
        switch line {
        case .downloading(_, let percent), .checking(let percent): Double(percent) / 100
        case .timeLeft, .waiting: nil
        }
    }

    // MARK: Empty states

    /// What the Library says instead of rows: unavailable before anything else, then an empty library (only once the
    /// notes were read, so it never flashes), then a search that found nothing.
    public static func emptyState(_ facts: LibraryFacts, favoritesOnly: Bool = false) -> LibraryEmptyState? {
        if facts.unavailable { return .unavailable }
        if facts.loading { return nil }
        if facts.liveNotes == 0 && facts.query.isEmpty { return .empty }
        if !facts.query.isEmpty { return facts.results == 0 ? .noMatch(facts.query) : nil }
        return favoritesOnly && facts.results == 0 ? .noStarred : nil
    }

    // MARK: Note actions

    /// The transcribe item of `note`'s actions for its `job`. Names carry over to a new version only through voice
    /// prints, so "Speaker names carry over." needs `voiceModelReady` and a named speaker.
    public static func transcribeAction(_ note: Note, job: Job?, voiceModelReady: Bool) -> TranscribeAction {
        switch job?.state {
        case .running: return .stop
        case .queued: return .removeFromQueue
        case .paused: return .resumeOrStartOver
        case .failed, .needsConsent, nil:
            if transcribeAgainRefused(note) { return .transcribeAgainUnavailable }
            guard isDocument(note) else { return .transcribe }
            let named = note.speakers?.contains { DefaultLabels.placeholderNumber($0.name) == nil } ?? false
            return .transcribeAgain(nextVersion: max(note.versions?.count ?? 0, 1) + 1, namesCarry: voiceModelReady && named)
        }
    }

    /// An unverified or newer-format document cannot take a new version; the item shows disabled and the banners do
    /// not offer it.
    public static func transcribeAgainRefused(_ note: Note) -> Bool {
        isDocument(note) && [.unverified, .unknownFormat].contains(documentState(note))
    }

    /// Whether Transcribe again on `note` replaces its transcripts, which needs a confirmation first ("Earlier
    /// versions can’t be kept because the audio changed.").
    public static func needsFreshConfirmation(_ note: Note) -> Bool {
        isDocument(note) && [.staleAudio, .unreadable, .invalidMetadata].contains(documentState(note))
    }

    /// A failure that repeats at each try: too long, or a refused document (or a new version of a file that cannot
    /// take one). Try again opens the note, which tells why, instead of queueing the job again.
    public static func isFinalFailure(_ job: Job, noNewVersion: Bool) -> Bool {
        guard job.state == .failed else { return false }
        if case .documentRefused = job.failure { return true }
        return job.failure == .long || (noNewVersion && job.kind == .transcribeAgain)
    }

    private static func isDocument(_ note: Note) -> Bool {
        RowFacts(note, jobState: nil, activeNoteID: nil).audioKind == .document
    }

    private static func documentState(_ note: Note) -> DocumentState? {
        RowFacts(note, jobState: nil, activeNoteID: nil).documentState
    }
}
