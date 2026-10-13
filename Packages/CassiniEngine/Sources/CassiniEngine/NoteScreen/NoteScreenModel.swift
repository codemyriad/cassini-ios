import Foundation
import Observation
import CassiniNotebook

/// What the Note screen could not do, for the app's error presenter to word.
public enum NoteProblem {
    /// A Transcribe (or Start over, or Identify speakers) was refused.
    case refused(EnqueueRefusal)
    /// A transcript or audio export could not be made.
    case export(ExportError)
    /// The Cassini document could not be made.
    case documentNotSaved
    /// An answer to "Is this Luca?" could not be saved.
    case speakerNotSaved(VoicesStore.SaveFailure)
}

/// The Note screen's state and the effects it carries out (Android `NoteViewModel`'s side of the stores). The rules
/// are pure and in CassiniNotebook: `NoteScreenState` turns taps, banner buttons and menu rows into `NoteEffect`s,
/// `NoteSheet(opening:)` picks the sheet an effect opens, and `PlaybackFollow` decides auto-follow and its resume
/// timer. This model keeps what the screen shows (the open sheet, the share sheet, the saved draft) and runs each
/// effect through its `Ports`, which the app binds to its stores. The sheets of the screen (Speakers, Versions, Edit
/// passage, the suggestion cards) act through it too, so the transcript's read-only rule holds in every one of them.
@MainActor @Observable
public final class NoteScreenModel {
    public struct Ports {
        // Notes
        public var note: @MainActor (UUID) -> Note?
        /// The note's job, nil without one.
        public var job: @MainActor (UUID) -> Job?
        /// Saves a note's change.
        public var update: @MainActor (UUID, @escaping @Sendable (inout Note) -> Void) -> Void
        /// Changes the note now and waits for the write; nil when it failed or the note is gone.
        public var commit: @MainActor (UUID, @escaping @Sendable (inout Note) -> Void) async -> Note?
        public var markMoment: @MainActor (UUID, TimeInterval) -> Void
        public var removeBookmark: @MainActor (UUID, UUID) -> Void
        /// Speakers: Add a speaker, by name.
        public var addSpeaker: @MainActor (UUID, String) -> Void
        /// Versions: shows the version.
        public var selectVersion: @MainActor (UUID, UUID) -> Void
        /// "Yes, Luca" (true) or "Not Luca" (false).
        public var answerSuggestion: @MainActor (SpeakerSuggestion, UUID, Bool) async throws(VoicesStore.SaveFailure) -> Void
        /// What Name a speaker needs about a speaker, and the writes it asks for.
        public var namingInput: @MainActor (UUID, String) async -> NamingInput?
        public var performNaming: @MainActor ([NamingEffect], UUID, String) async throws(VoicesStore.SaveFailure) -> Void

        // The queue
        public var transcribe: @MainActor (UUID, JobKind) async -> TranscribeOutcome
        public var startOver: @MainActor (UUID) async -> TranscribeOutcome
        /// Stop and keep progress on the running note; Remove from queue on a queued one.
        public var stop: @MainActor (UUID) -> Void
        public var dequeue: @MainActor (UUID) -> Void
        public var continueQueue: @MainActor () -> Void
        public var clearFailed: @MainActor (UUID) -> Void
        /// Cancel of the running job's model download.
        public var cancelJobDownload: @MainActor () -> Void
        /// The words of the note's saved progress.
        public var savedDraft: @MainActor (UUID) async -> [DraftWord]

        // The player
        /// Whether the note holds the player and it can play.
        public var ownsPlayer: @MainActor (UUID) -> Bool
        public var play: @MainActor () -> Void
        /// Plays the note from a time, when it holds the player.
        public var playFrom: @MainActor (Note, TimeInterval) -> Void
        /// Opens the note's player for the screen, or reloads it when the audio changed.
        public var showPlayer: @MainActor (Note, PlaybackOwner) -> Void
        public var leavePlayer: @MainActor (PlaybackOwner) -> Void
        /// A recording keeps the player closed.
        public var playerBlocked: @MainActor () -> Bool
        /// A recording holds the audio.
        public var recording: @MainActor () -> Bool

        // Exports
        public var exportTranscript: @MainActor (UUID, TranscriptFormat) async throws(ExportError) -> URL
        public var copyAudio: @MainActor (UUID) async throws(ExportError) -> URL
        public var exportDocument: @MainActor (UUID) async throws -> URL
        /// Removes an export once the share sheet is done with it.
        public var discardExport: @MainActor (URL) -> Void
        /// Move to Recently Deleted (it asks first while the note is transcribing).
        public var trash: @MainActor (UUID) async -> Void

        // Navigation
        public var session: @MainActor (UUID) -> NoteSession
        public var isOpen: @MainActor (UUID) -> Bool
        public var markStarted: @MainActor (UUID) -> Void
        /// The model download screen over the note (`ScreenStack.offerModelDownload`).
        public var openModelDownload: @MainActor (UUID) -> Void
        public var present: @MainActor (NoteProblem) -> Void

        public init(note: @escaping @MainActor (UUID) -> Note?, job: @escaping @MainActor (UUID) -> Job?,
                    update: @escaping @MainActor (UUID, @escaping @Sendable (inout Note) -> Void) -> Void,
                    commit: @escaping @MainActor (UUID, @escaping @Sendable (inout Note) -> Void) async -> Note?,
                    markMoment: @escaping @MainActor (UUID, TimeInterval) -> Void,
                    removeBookmark: @escaping @MainActor (UUID, UUID) -> Void,
                    addSpeaker: @escaping @MainActor (UUID, String) -> Void,
                    selectVersion: @escaping @MainActor (UUID, UUID) -> Void,
                    answerSuggestion: @escaping @MainActor (SpeakerSuggestion, UUID, Bool) async throws(VoicesStore.SaveFailure) -> Void,
                    namingInput: @escaping @MainActor (UUID, String) async -> NamingInput?,
                    performNaming: @escaping @MainActor ([NamingEffect], UUID, String) async throws(VoicesStore.SaveFailure) -> Void,
                    transcribe: @escaping @MainActor (UUID, JobKind) async -> TranscribeOutcome,
                    startOver: @escaping @MainActor (UUID) async -> TranscribeOutcome,
                    stop: @escaping @MainActor (UUID) -> Void, dequeue: @escaping @MainActor (UUID) -> Void,
                    continueQueue: @escaping @MainActor () -> Void, clearFailed: @escaping @MainActor (UUID) -> Void,
                    cancelJobDownload: @escaping @MainActor () -> Void,
                    savedDraft: @escaping @MainActor (UUID) async -> [DraftWord],
                    ownsPlayer: @escaping @MainActor (UUID) -> Bool, play: @escaping @MainActor () -> Void,
                    playFrom: @escaping @MainActor (Note, TimeInterval) -> Void,
                    showPlayer: @escaping @MainActor (Note, PlaybackOwner) -> Void,
                    leavePlayer: @escaping @MainActor (PlaybackOwner) -> Void,
                    playerBlocked: @escaping @MainActor () -> Bool,
                    recording: @escaping @MainActor () -> Bool,
                    exportTranscript: @escaping @MainActor (UUID, TranscriptFormat) async throws(ExportError) -> URL,
                    copyAudio: @escaping @MainActor (UUID) async throws(ExportError) -> URL,
                    exportDocument: @escaping @MainActor (UUID) async throws -> URL,
                    discardExport: @escaping @MainActor (URL) -> Void,
                    trash: @escaping @MainActor (UUID) async -> Void,
                    session: @escaping @MainActor (UUID) -> NoteSession, isOpen: @escaping @MainActor (UUID) -> Bool,
                    markStarted: @escaping @MainActor (UUID) -> Void,
                    openModelDownload: @escaping @MainActor (UUID) -> Void,
                    present: @escaping @MainActor (NoteProblem) -> Void) {
            self.note = note; self.job = job; self.update = update; self.commit = commit
            self.markMoment = markMoment; self.removeBookmark = removeBookmark; self.addSpeaker = addSpeaker
            self.selectVersion = selectVersion; self.answerSuggestion = answerSuggestion
            self.namingInput = namingInput; self.performNaming = performNaming
            self.transcribe = transcribe; self.startOver = startOver; self.stop = stop; self.dequeue = dequeue
            self.continueQueue = continueQueue; self.clearFailed = clearFailed; self.cancelJobDownload = cancelJobDownload
            self.savedDraft = savedDraft
            self.ownsPlayer = ownsPlayer; self.play = play; self.playFrom = playFrom; self.showPlayer = showPlayer
            self.leavePlayer = leavePlayer; self.playerBlocked = playerBlocked
            self.recording = recording
            self.exportTranscript = exportTranscript; self.copyAudio = copyAudio; self.exportDocument = exportDocument
            self.discardExport = discardExport; self.trash = trash
            self.session = session; self.isOpen = isOpen; self.markStarted = markStarted
            self.openModelDownload = openModelDownload; self.present = present
        }
    }

    /// How an Edit passage save ended.
    public enum PassageSave: Hashable, Sendable {
        case saved
        /// The transcript no longer holds the passage as it was opened.
        case changed
        /// A job for the note makes the transcript read-only.
        case locked
    }

    public let noteID: UUID
    public var screen: NoteScreenState
    public var sheet: NoteSheet?
    /// The text typed so far into Name this speaker or Rename, kept with the open sheet.
    public var sheetDraft: String?
    public var shareItem: ShareItem?
    /// A Cassini document is being prepared.
    public private(set) var exportingDocument = false
    public var showBookmarks = false
    /// The saved progress of a stopped or failed job, for its read-only draft.
    public private(set) var savedDraft: [DraftWord] = []
    /// This screen, as the owner of the player.
    @ObservationIgnored public let playerOwner = PlaybackOwner()
    @ObservationIgnored let ports: Ports
    @ObservationIgnored private var resumeFollow: Task<Void, Never>?
    /// The search kept with the stack was brought back into this screen.
    @ObservationIgnored private var restored = false
    /// The screen is on the stack and shown; a screen that left opens no player.
    @ObservationIgnored private var visible = false

    public init(noteID: UUID, query: String? = nil, ports: Ports) {
        self.noteID = noteID
        self.ports = ports
        screen = NoteScreenState(query: query)
    }

    public var note: Note? { ports.note(noteID) }
    public var job: Job? { ports.job(noteID) }
    /// Why the transcript cannot be changed now (`ReadOnlyReason.of`); every sheet of the screen follows it.
    public var readOnly: ReadOnlyReason? { note.flatMap { ReadOnlyReason.of($0, job: job) } }

    // MARK: Effects

    public func run(_ effect: NoteEffect?) {
        guard let effect else { return }
        if let opened = NoteSheet(opening: effect, in: note) {
            sheet = opened
            return
        }
        switch effect {
        case .seekAndPlay(let time): seek(time)
        case .transcribe(let kind): Task { follow(await ports.transcribe(noteID, kind)) }
        case .startOver: Task { follow(await ports.startOver(noteID)) }
        case .acknowledgeTrustAndPlay:
            ports.update(noteID) { $0.document?.trustAcknowledged = true }
            if ports.ownsPlayer(noteID) { ports.play() }
        case .continueQueue: ports.continueQueue()
        case .clearFailed: ports.clearFailed(noteID)
        case .toggleStar: ports.update(noteID) { $0.isFavorite.toggle() }
        case .exportTranscript(let format):
            export { ports, id throws(ExportError) in try await ports.exportTranscript(id, format) }
        case .shareAudio: export { ports, id throws(ExportError) in try await ports.copyAudio(id) }
        case .exportDocument: exportDocument()
        case .stop: ports.stop(noteID)
        case .removeFromQueue: ports.dequeue(noteID)
        case .moveToTrash: Task { await ports.trash(noteID) }
        case .nameSpeaker, .openVersions, .openSpeakers, .editPassage, .rename, .documentInfo:
            break // A sheet (above); a passage that is gone opens nothing.
        }
    }

    /// A row of the note's "…" menu.
    public func perform(_ action: NoteMenuAction) {
        guard let note else { return }
        run(screen.menu(action, note: note, job: job, readOnly: readOnly))
    }

    /// A button of a banner over the transcript.
    public func bannerAction(_ action: BannerAction) {
        guard let note else { return }
        run(screen.bannerAction(action, note: note, job: job))
    }

    public func dismiss(_ banner: BannerSpec) {
        guard let note else { return }
        run(screen.dismiss(banner, note: note, job: job))
    }

    /// The question open over the screen was confirmed.
    public func confirmDialog() { run(screen.confirmDialog()) }

    /// A speaker header, a speaker of the Speakers list or a suggestion card's header: Name a speaker, unless the
    /// transcript is read-only (then the screen says why).
    public func speakerTapped(_ speakerID: String) { run(screen.speakerTapped(speakerID, readOnly: readOnly)) }
    public func versionsTapped() { run(screen.versionsTapped(readOnly: readOnly)) }
    public func speakersTapped() { run(screen.speakersTapped(readOnly: readOnly)) }
    public func editPassage(_ segmentID: UUID) { run(screen.editPassage(segmentID, readOnly: readOnly)) }

    /// "Mark this moment": the bookmark, and the section that lists it open.
    public func markMoment(at time: TimeInterval) {
        ports.markMoment(noteID, time)
        showBookmarks = true
    }

    public func removeBookmark(_ bookmarkID: UUID) { ports.removeBookmark(noteID, bookmarkID) }

    /// The processing card's Stop and keep progress, and the Speakers list's Cancel analysis.
    public func stopJob() { ports.stop(noteID) }
    /// The Queued card's Remove from queue.
    public func removeFromQueue() { ports.dequeue(noteID) }
    /// The processing card's Cancel of the job's model download.
    public func cancelJobDownload() { ports.cancelJobDownload() }

    /// What queuing a job led to (`TranscribeOutcome.followUp`): without consent the open sheet gives way to the
    /// model download screen, which asks over the note; a refusal says why.
    private func follow(_ outcome: TranscribeOutcome) {
        switch outcome.followUp {
        case .openModelDownload:
            sheet = nil
            ports.openModelDownload(noteID)
        case .refused(let refusal): ports.present(.refused(refusal))
        case .none: break
        }
    }

    /// Plays from `time`, unless a recording holds the audio.
    public func seek(_ time: TimeInterval) {
        guard !ports.recording(), let note else { return }
        ports.playFrom(note, time)
    }

    /// Shares the file `file` writes for the note, or says why there is none. The file is removed once the sheet is
    /// done with it.
    private func export(_ file: @escaping @MainActor (Ports, UUID) async throws(ExportError) -> URL) {
        Task {
            do throws(ExportError) { shareItem = shared(try await file(ports, noteID)) }
            catch { ports.present(.export(error)) }
        }
    }

    private func exportDocument() {
        exportingDocument = true
        Task {
            do { shareItem = shared(try await ports.exportDocument(noteID)) }
            catch { ports.present(.documentNotSaved) }
            exportingDocument = false
        }
    }

    private func shared(_ url: URL) -> ShareItem {
        ShareItem(url: url) { [discard = ports.discardExport] in discard(url) }
    }

    // MARK: The screen's sheets

    /// Speakers: whether its speakers and Add a speaker can change the note. Identify speakers waits too while
    /// `readOnly` is `jobPending`, which the list shows with its progress and Cancel analysis.
    public var speakersEditable: Bool { readOnly == nil }

    /// Add a speaker, refused while the transcript is read-only. Returns whether the speaker was added.
    @discardableResult
    public func addSpeaker(named name: String) -> Bool {
        guard readOnly == nil else { return false }
        ports.addSpeaker(noteID, name)
        return true
    }

    /// Identify speakers: a speakers-only job; without consent the sheet gives way to the model download screen.
    public func identifySpeakers() async {
        guard readOnly == nil else { return }
        follow(await ports.transcribe(noteID, .speakersOnly))
    }

    /// Versions: shows the version and closes the sheet.
    public func selectVersion(_ versionID: UUID) {
        ports.selectVersion(noteID, versionID)
        sheet = nil
    }

    /// Edit passage's Save. The change runs again on the stored note when someone else saved it meanwhile; it then
    /// finds the passage gone, and the editor says so.
    public func revisePassage(_ original: TranscriptSegment, to revised: TranscriptSegment,
                              stamp: VersionStamp) async -> PassageSave {
        guard readOnly == nil else { return .locked }
        guard note?.holds(original) == true else { return .changed }
        guard revised != original else { return .saved }
        let saved = await ports.commit(noteID) { _ = $0.revisePassage(original, to: revised, stamp: stamp) }
        return saved?.holds(revised) == true ? .saved : .changed
    }

    /// "Yes, Luca" or "Not Luca" on a suggestion card; nothing while the transcript is read-only.
    public func answer(_ suggestion: SpeakerSuggestion, yes: Bool) async {
        guard readOnly == nil else { return }
        do throws(VoicesStore.SaveFailure) {
            try await ports.answerSuggestion(suggestion, noteID, yes)
        } catch {
            ports.present(.speakerNotSaved(error))
        }
    }

    /// The model of Name a speaker for one of the note's speakers.
    public func naming(_ speakerID: String) -> NameSpeakerModel {
        NameSpeakerModel(noteID: noteID, speakerID: speakerID, ports: .init(
            input: ports.namingInput, perform: ports.performNaming,
            readOnly: { [weak self] in self?.readOnly }))
    }

    // MARK: Opening

    /// What the screen's player follows (`NotePlayer.key`): nil in a mode without a player (a running job) and while a
    /// recording keeps the player closed. The screen calls `updatePlayer()` when it changes.
    public var playerKey: NotePlayer.Key? {
        guard let note, NoteMode.of(note, job: job).hasPlayer else { return nil }
        return NotePlayer.key(for: note, blocked: ports.playerBlocked())
    }

    /// Opens, reloads or leaves the player for `playerKey`. A screen that left does nothing: it opens no player, and
    /// has none to leave.
    public func updatePlayer() {
        guard visible else { return }
        if let note, playerKey != nil { ports.showPlayer(note, playerOwner) } else { ports.leavePlayer(playerOwner) }
    }

    /// Brings back the search the stack kept for this screen (when SwiftUI built the view again), opens the player,
    /// and runs the Library's start action.
    public func appeared(start: NoteStartAction?) {
        visible = true
        if !restored {
            restored = true
            if let kept = ports.session(noteID).search { screen.search = NoteScreenState(query: kept).search }
        }
        updatePlayer()
        runStart(start)
    }

    /// Runs the Library's start action once for the screen: the router remembers that it ran, and a route restored
    /// with the scene carries none. A screen leaving the stack forgets it ran, and runs nothing.
    public func runStart(_ start: NoteStartAction?) {
        guard let start, ports.isOpen(noteID), !ports.session(noteID).started else { return }
        ports.markStarted(noteID)
        run(start.effect)
    }

    /// Reads a stopped or failed job's saved progress for its draft; any other job shows none.
    public func loadSavedDraft() async {
        let stopped = job.map { $0.state == .paused || $0.state == .failed } == true
        let draft = stopped ? await ports.savedDraft(noteID) : []
        if !Task.isCancelled { savedDraft = draft }
    }

    // MARK: Follow

    /// A drag during playback pauses auto-follow; once the scrolling stops, `PlaybackFollow.resumeAfter` without
    /// scrolling resumes it.
    public func scrolled(_ scrolling: PlaybackFollow.Scrolling, playing: Bool) {
        switch screen.follow.scrolled(scrolling, playing: playing) {
        case .keep: break
        case .cancel: resumeFollow?.cancel()
        case .restart(let delay):
            resumeFollow?.cancel()
            resumeFollow = Task {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                screen.follow.resume()
            }
        }
    }

    /// The Follow playback chip.
    public func resumeFollowing() {
        resumeFollow?.cancel()
        screen.follow.resume()
    }

    /// The screen left: so does its player, and the follow timer stops.
    public func disappeared() {
        visible = false
        ports.leavePlayer(playerOwner)
        resumeFollow?.cancel()
    }
}
