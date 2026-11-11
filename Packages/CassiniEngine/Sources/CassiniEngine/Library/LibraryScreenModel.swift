import Foundation
import Observation
import CassiniNotebook

/// The Library (Android `LibraryViewModel`, features.md section 1): its rows built from the notes, the queue and the
/// recorder; the search, run 150 ms after the last keystroke (an empty query at once); the actions menu of each row
/// and its confirmations; and where its rows, inline actions and progress banner lead.
///
/// The notes are indexed when they change (observed through `Ports.notes`), not when the view reads `content`, so
/// reading it has no side effects.
@MainActor @Observable
public final class LibraryScreenModel {
    public struct Ports {
        /// Every note, newest first, Recently Deleted included. Observed: the index follows its changes.
        public var notes: @MainActor () -> [Note]
        /// The notes have not been read yet.
        public var loading: @MainActor () -> Bool
        /// The library could not be opened.
        public var unavailable: @MainActor () -> Bool
        public var processing: @MainActor () -> ProcessingState
        /// The running job's progress; nil before its first report.
        public var phase: @MainActor (UUID) -> JobPhase?
        /// A model download running on its own.
        public var install: @MainActor () -> DownloadFact?
        public var recording: @MainActor () -> RecordingState
        /// The note whose recorded audio is still being written.
        public var finishing: @MainActor () -> UUID?
        public var transcribe: @MainActor (UUID, JobKind) async -> TranscribeOutcome
        public var startOver: @MainActor (UUID) async -> TranscribeOutcome
        /// Stop and keep progress.
        public var stop: @MainActor (UUID) -> Void
        public var dequeue: @MainActor (UUID) -> Void
        /// Saves a note's change.
        public var update: @MainActor (UUID, @escaping @Sendable (inout Note) -> Void) -> Void
        /// Move to Recently Deleted (it asks first while the note is transcribing).
        public var trash: @MainActor (UUID) async -> Void
        /// Whether the speaker models are installed, so names carry over to a new version.
        public var speakerModelsReady: @MainActor () async -> Bool
        public var clock: any AppClock
        public var calendar: Calendar

        public init(notes: @escaping @MainActor () -> [Note], loading: @escaping @MainActor () -> Bool,
                    unavailable: @escaping @MainActor () -> Bool, processing: @escaping @MainActor () -> ProcessingState,
                    phase: @escaping @MainActor (UUID) -> JobPhase?, install: @escaping @MainActor () -> DownloadFact?,
                    recording: @escaping @MainActor () -> RecordingState, finishing: @escaping @MainActor () -> UUID?,
                    transcribe: @escaping @MainActor (UUID, JobKind) async -> TranscribeOutcome,
                    startOver: @escaping @MainActor (UUID) async -> TranscribeOutcome,
                    stop: @escaping @MainActor (UUID) -> Void, dequeue: @escaping @MainActor (UUID) -> Void,
                    update: @escaping @MainActor (UUID, @escaping @Sendable (inout Note) -> Void) -> Void,
                    trash: @escaping @MainActor (UUID) async -> Void,
                    speakerModelsReady: @escaping @MainActor () async -> Bool,
                    clock: any AppClock, calendar: Calendar) {
            self.notes = notes; self.loading = loading; self.unavailable = unavailable; self.processing = processing
            self.phase = phase; self.install = install; self.recording = recording; self.finishing = finishing
            self.transcribe = transcribe; self.startOver = startOver; self.stop = stop; self.dequeue = dequeue
            self.update = update; self.trash = trash; self.speakerModelsReady = speakerModelsReady
            self.clock = clock; self.calendar = calendar
        }
    }

    public static let searchDebounce = Duration.milliseconds(150)

    /// The search field's text, as typed.
    public var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    /// The trimmed query the results are for; it follows `query` after the debounce.
    public private(set) var searched = ""
    /// Only starred notes (an iOS extra).
    public var favoritesOnly = false
    /// D14 search-only filter: transient, reset when the query closes, never scene-persisted.
    public var searchDate: SearchDate = .any
    /// The confirmation or form open over the Library.
    public var dialog: LibraryDialog?
    /// The speaker models are installed (Transcribe again says "Speaker names carry over.").
    public private(set) var speakerModelsReady = false

    @ObservationIgnored public var onEffect: (@MainActor (LibraryEffect) -> Void)?
    @ObservationIgnored let ports: Ports
    @ObservationIgnored private var index = LibraryIndex()
    /// `index.revision`, observed, so the view reads the rows again when the notes change.
    private var revision = 0
    @ObservationIgnored private var pendingSearch: Task<Void, Never>?
    @ObservationIgnored private var pendingNotes: Task<Void, Never>?
    /// The last search's results: for `query` over the notes at `revision` of the index.
    private var found: Found?
    /// The search running off the main actor.
    @ObservationIgnored private var running: (query: String, task: Task<Void, Never>)?

    private struct Found {
        let query: String
        let revision: Int
        let hits: [LibraryIndex.Hit]
    }

    public init(ports: Ports) {
        self.ports = ports
        observeNotes()
    }

    /// Whether a query is open: the rows are the flat results.
    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var content: LibraryContent {
        _ = revision
        let processing = ports.processing(), now = ports.clock.now, calendar = ports.calendar
        let context = RowContext(processing: processing, recording: ports.recording())
        let loading = ports.loading(), unavailable = ports.unavailable()
        let live = favoritesOnly ? index.entries.filter(\.note.isFavorite) : index.entries
        let audioOnly = index.entries.contains { $0.note.status == .audioOnly && $0.note.transcript.isEmpty }
        var facts = LibraryFacts(loading: loading, liveNotes: index.entries.count, audioOnly: audioOnly,
                                 unavailable: unavailable)
        guard isSearching else {
            facts.results = live.count
            return LibraryContent(loading: loading, sections: LibraryMapping.sections(live, context: context, now: now, calendar: calendar),
                                  emptyState: LibraryMapping.emptyState(facts, favoritesOnly: favoritesOnly), facts: facts)
        }
        // Until the first search answers, the results are empty and say nothing. Afterwards a new query or a changed
        // note shows the last results, over the notes as they are now, until the search over them answers.
        guard let found else { return LibraryContent(loading: loading, results: [], facts: facts) }
        let current = found.revision == index.revision ? found.hits : index.current(found.hits, query: SearchQuery(found.query))
        let interval = searchDate.interval(now: now, calendar: calendar)
        let hits = current.filter {
            let note = $0.entry.note
            return (!favoritesOnly || note.isFavorite) &&
                (interval.map { range in
                    note.meetingTime.isWithin(range, calendar: calendar)
                } ?? true)
        }
        if found.query == searched {
            facts.query = searched
            facts.results = hits.count
        }
        return LibraryContent(loading: loading, results: LibraryMapping.results(hits, context: context, now: now, calendar: calendar),
                              emptyState: LibraryMapping.emptyState(facts, favoritesOnly: favoritesOnly), facts: facts)
    }

    /// The note of a row, as the rows were last built.
    public func note(_ id: UUID) -> Note? { index.entry(id)?.note }

    /// The recording card, while a capture is active.
    public var recordingCard: LibraryMapping.RecordingCard? { LibraryMapping.recordingCard(ports.recording()) }

    /// The transcription banner.
    public var progress: ProgressBanner? {
        let processing = ports.processing()
        return LibraryMapping.progress(processing, phase: processing.running.flatMap { ports.phase($0.noteID) },
                                       install: ports.install())
    }

    /// What the long press on a row offers; nil for a note no longer in the Library.
    public func menu(_ id: UUID) -> LibraryRowMenu? {
        _ = revision
        guard let note = index.entry(id)?.note else { return nil }
        let processing = ports.processing(), finishing = ports.finishing() == id
        return LibraryRowMenu(isFavorite: note.isFavorite, recording: note.isRecording && ports.recording().noteID == id,
                        transcribe: LibraryMapping.transcribeAction(note, job: processing.jobs[id],
                                                                    voiceModelReady: speakerModelsReady),
                        transcribeWaits: finishing, export: TranscriptExports.availability(of: note),
                        exportsDocument: !note.transcript.isEmpty && !processing.isRunning(id) && !finishing)
    }

    // MARK: Events

    /// A tap on a row: the note being recorded returns to the Recording screen; any other opens with the search query,
    /// so the in-note search starts with it.
    public func open(_ id: UUID) {
        if RowContext(processing: ports.processing(), recording: ports.recording()).activeNoteID == id,
           ports.notes().first(where: { $0.id == id })?.audio == .live {
            onEffect?(.openRecording)
            return
        }
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        onEffect?(.openNote(.note(id, query: query.isEmpty ? nil : query)))
    }

    /// The banner: the running note, or Settings for a download on its own.
    public func openProgress() {
        if let running = ports.processing().running?.noteID { onEffect?(.openNote(.note(running))) } else { onEffect?(.openSettings) }
    }

    /// Resume on a paused row and Try again on a failed one: the job's own kind goes to the back of the queue. A final
    /// failure opens the note instead, which tells why; without consent the model download opens.
    public func resume(_ id: UUID) async {
        let job = ports.processing().jobs[id]
        if let job, let note = ports.notes().first(where: { $0.id == id }),
           LibraryMapping.isFinalFailure(job, noNewVersion: LibraryMapping.transcribeAgainRefused(note)) {
            onEffect?(.openNote(.note(id)))
            return
        }
        await transcribe(id, kind: job?.kind ?? .transcribe)
    }

    /// Transcribe or Transcribe again: without consent the model download opens; a refusal says why.
    public func transcribe(_ id: UUID, kind: JobKind) async {
        handle(await ports.transcribe(id, kind), for: id)
    }

    /// A row of the actions menu (Android `LibraryViewModel.sheetAction`). Rename, Start over and a Transcribe again
    /// that replaces the versions open their dialog; the exports and Document info open the note, which starts them.
    public func perform(_ action: NoteAction, on id: UUID) async {
        guard let note = ports.notes().first(where: { $0.id == id }) else { return }
        switch action {
        case .toggleStar: ports.update(id) { $0.isFavorite.toggle() }
        case .rename: dialog = .rename(id)
        case .transcribe: await transcribe(id, kind: .transcribe)
        case .transcribeAgain:
            if LibraryMapping.transcribeAgainRefused(note) { return }
            if LibraryMapping.needsFreshConfirmation(note) { dialog = .transcribeFresh(id) } else { await transcribe(id, kind: .transcribeAgain) }
        case .stop: ports.stop(id)
        case .removeFromQueue: ports.dequeue(id)
        case .resume: await transcribe(id, kind: ports.processing().jobs[id]?.kind ?? .transcribe)
        case .startOver: dialog = .startOver(id)
        case .export(let format): onEffect?(.openNote(.note(id, start: .export(format))))
        case .exportDocument: onEffect?(.openNote(.note(id, start: .exportDocument)))
        case .shareAudio: onEffect?(.openNote(.note(id, start: .shareAudio)))
        case .documentInfo: onEffect?(.openNote(.note(id, start: .documentInfo)))
        case .moveToTrash: await ports.trash(id)
        }
    }

    /// The open confirmation's action (Android `confirmDialog`): Start over, or the fresh Transcribe again. Rename
    /// confirms with `rename(_:to:)`.
    public func confirmDialog() async {
        guard let dialog else { return }
        await confirm(dialog)
    }

    /// The action of `dialog`, as it was presented (an alert may have cleared `dialog` before its button runs).
    public func confirm(_ dialog: LibraryDialog) async {
        if self.dialog == dialog { self.dialog = nil }
        switch dialog {
        case .rename: break
        case .startOver(let id): handle(await ports.startOver(id), for: id)
        case .transcribeFresh(let id): await transcribe(id, kind: .transcribeAgain)
        }
    }

    public func dismissDialog() { dialog = nil }

    /// Rename's Save: the trimmed title, at most `NoteTitles.maxLength`, stored only when it changed. A blank title
    /// keeps the dialog open and returns false.
    @discardableResult
    public func rename(_ id: UUID, to title: String) -> Bool {
        guard let cleaned = NoteTitles.clean(title) else { return false }
        if dialog == .rename(id) { dialog = nil }
        if note(id)?.title != cleaned { ports.update(id) { $0.title = cleaned } }
        return true
    }

    /// Asks whether the speaker models are installed, for Transcribe again's "Speaker names carry over."
    public func refreshSpeakerModels() async { speakerModelsReady = await ports.speakerModelsReady() }

    /// Waits until the index has the latest notes and the search asked for last has answered (tests).
    public func settle() async {
        while pendingNotes != nil || pendingSearch != nil || running != nil {
            await pendingNotes?.value
            await pendingSearch?.value
            await running?.task.value
        }
    }

    func handle(_ outcome: TranscribeOutcome, for id: UUID) {
        switch outcome.followUp {
        case .openModelDownload: onEffect?(.openModelDownload(noteID: id))
        case .refused(let refusal): onEffect?(.refused(refusal))
        case .none: break
        }
    }
}

/// The Library's index of the notes, kept up to date as they change, and its search, run off the main actor after
/// the debounce.
private extension LibraryScreenModel {
    /// Indexes the notes now and again each time they change: the change is observed, and the index is brought up to
    /// date on the main actor right after it.
    func observeNotes() {
        pendingNotes = nil
        let notes = withObservationTracking { ports.notes() } onChange: { [weak self] in
            // The stores change on the main actor, so the update is scheduled right away and `settle()` sees it.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.notesChanged() }
            } else {
                Task { @MainActor [weak self] in self?.notesChanged() }
            }
        }
        index.update(notes)
        guard index.revision != revision else { return }
        revision = index.revision
        if !searched.isEmpty, found?.revision != revision { search() }
    }

    func notesChanged() {
        guard pendingNotes == nil else { return }
        pendingNotes = Task { @MainActor [weak self] in self?.observeNotes() }
    }

    /// Searches the notes for `searched` off the main actor, a thousand notes being more than a frame's work; the
    /// tokens it works out are kept for the next search. A search over notes that changed meanwhile still publishes
    /// its results, then runs again over the new notes; a new query cancels it.
    func search() {
        let query = searched
        if let running {
            if running.query == query { return } // it searches again over the new notes when it answers
            running.task.cancel()
        }
        let snapshot = index, revision = index.revision
        let task = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                var copy = snapshot
                return (copy.search(SearchQuery(query)), copy)
            }
            let (hits, searched) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled else { return }
            index.adoptTokens(from: searched)
            found = Found(query: query, revision: revision, hits: hits)
            running = nil
            if self.searched == query, revision != index.revision { search() }
        }
        running = (query, task)
    }

    func scheduleSearch() {
        pendingSearch?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { searchDate = .any }
        guard text != searched else { pendingSearch = nil; return }
        guard !text.isEmpty else {
            searched = ""
            found = nil
            running?.task.cancel()
            running = nil
            pendingSearch = nil
            return
        }
        pendingSearch = Task { [weak self, clock = ports.clock] in
            do { try await clock.sleep(for: Self.searchDebounce) } catch { return }
            guard let self, !Task.isCancelled else { return }
            pendingSearch = nil
            searched = text
            search()
        }
    }
}
