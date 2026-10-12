import Foundation
import Observation
import CassiniNotebook

/// Where the Library sends the user.
public enum LibraryEffect: Hashable, Sendable {
    case openNote(Route)
    /// The Recording screen: it starts a recording, or returns to the one in progress.
    case openRecording
    case openSettings
    case openModelDownload(noteID: UUID?)
    /// A Transcribe the queue refused; the app says why.
    case refused(EnqueueRefusal)
}

/// What the Library shows: the day sections, or while searching the flat results, and what it says instead of rows.
public struct LibraryContent: Hashable, Sendable {
    /// The notes have not been read yet: nothing below the search, so the empty state never flashes.
    public var loading: Bool
    public var sections: [DaySection]
    /// The flat results while a query is open; nil when not searching.
    public var results: [LibraryRow]?
    public var emptyState: LibraryEmptyState?

    public init(loading: Bool = false, sections: [DaySection] = [], results: [LibraryRow]? = nil,
                emptyState: LibraryEmptyState? = nil) {
        self.loading = loading; self.sections = sections; self.results = results; self.emptyState = emptyState
    }
}

/// The Library (Android `LibraryViewModel`, features.md section 1): its rows built from the notes, the queue and the
/// recorder; the search, run 150 ms after the last keystroke (an empty query at once); and where its rows, inline
/// actions and progress banner lead.
@MainActor @Observable
public final class LibraryScreenModel {
    public struct Ports {
        /// Every note, newest first, Recently Deleted included.
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
        public var transcribe: @MainActor (UUID, JobKind) async -> TranscribeOutcome
        public var clock: any AppClock
        public var calendar: Calendar

        public init(notes: @escaping @MainActor () -> [Note], loading: @escaping @MainActor () -> Bool,
                    unavailable: @escaping @MainActor () -> Bool, processing: @escaping @MainActor () -> ProcessingState,
                    phase: @escaping @MainActor (UUID) -> JobPhase?, install: @escaping @MainActor () -> DownloadFact?,
                    recording: @escaping @MainActor () -> RecordingState,
                    transcribe: @escaping @MainActor (UUID, JobKind) async -> TranscribeOutcome,
                    clock: any AppClock, calendar: Calendar) {
            self.notes = notes; self.loading = loading; self.unavailable = unavailable; self.processing = processing
            self.phase = phase; self.install = install; self.recording = recording; self.transcribe = transcribe
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

    @ObservationIgnored public var onEffect: (@MainActor (LibraryEffect) -> Void)?
    @ObservationIgnored private let ports: Ports
    @ObservationIgnored private var index = LibraryIndex()
    @ObservationIgnored private var pendingSearch: Task<Void, Never>?
    /// The last search's results: for `query` over the notes at `revision` of the index.
    private var found: Found?
    /// The search running off the main actor.
    @ObservationIgnored private var running: (query: String, revision: Int, task: Task<Void, Never>)?

    private struct Found {
        let query: String
        let revision: Int
        let hits: [LibraryIndex.Hit]
    }

    public init(ports: Ports) { self.ports = ports }

    /// Whether a query is open: the rows are the flat results.
    public var isSearching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var content: LibraryContent {
        index.update(ports.notes())
        let processing = ports.processing(), now = ports.clock.now, calendar = ports.calendar
        let context = RowContext(processing: processing, recording: ports.recording())
        let loading = ports.loading(), unavailable = ports.unavailable()
        let live = favoritesOnly ? index.entries.filter(\.note.isFavorite) : index.entries
        var facts = LibraryFacts(loading: loading, liveNotes: index.entries.count, unavailable: unavailable)
        guard isSearching else {
            facts.results = live.count
            return LibraryContent(loading: loading, sections: LibraryMapping.sections(live, context: context, now: now, calendar: calendar),
                                  emptyState: LibraryMapping.emptyState(facts, favoritesOnly: favoritesOnly))
        }
        // Until the first search answers, the results are empty and say nothing. Afterwards a new query or a changed
        // note shows the last results until the search over them answers.
        if !searched.isEmpty, found?.query != searched || found?.revision != index.revision { search() }
        guard let found else { return LibraryContent(loading: loading, results: []) }
        let hits = found.hits.filter { !favoritesOnly || $0.entry.note.isFavorite }
        if found.query == searched {
            facts.query = searched
            facts.results = hits.count
        }
        return LibraryContent(loading: loading, results: LibraryMapping.results(hits, context: context, now: now, calendar: calendar),
                              emptyState: LibraryMapping.emptyState(facts, favoritesOnly: favoritesOnly))
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

    /// Transcribe or Transcribe again from the note's actions.
    public func transcribe(_ id: UUID, kind: JobKind) async {
        switch await ports.transcribe(id, kind) {
        case .needsConsent: onEffect?(.openModelDownload(noteID: id))
        case .refused(let refusal): onEffect?(.refused(refusal))
        case .queued: break
        }
    }

    /// Waits for the search asked for last and its results (tests).
    public func settleSearch() async {
        await pendingSearch?.value
        await running?.task.value
    }

    /// Searches the notes for `searched` off the main actor, a thousand notes being more than a frame's work; the
    /// tokens it works out are kept for the next search.
    private func search() {
        let query = searched, revision = index.revision
        guard running?.query != query || running?.revision != revision else { return }
        running?.task.cancel()
        let snapshot = index
        let task = Task { [weak self] in
            let (hits, searched) = await Task.detached(priority: .userInitiated) {
                var copy = snapshot
                return (copy.search(SearchQuery(query)), copy)
            }.value
            guard let self, !Task.isCancelled else { return }
            index.adoptTokens(from: searched)
            found = Found(query: query, revision: revision, hits: hits)
            running = nil
        }
        running = (query, revision, task)
    }

    private func scheduleSearch() {
        pendingSearch?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
            searched = text
            index.update(ports.notes())
            search()
        }
    }
}
