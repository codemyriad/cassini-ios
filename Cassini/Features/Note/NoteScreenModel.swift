import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The stores the Note screen acts through, as the view's environment has them.
struct NoteScreenStores {
    let library: LibraryStore
    let playback: PlaybackStore
    let processing: ProcessingStore
    let recording: RecordingStore
    let router: Router
    let errors: ErrorPresenter
    let exports: ExportStore
    let trash: TrashService
}

/// The Note screen's state and the effects it carries out (Android `NoteViewModel`'s side of the stores). The rules
/// are pure and in CassiniNotebook: `NoteScreenState` turns taps, banner buttons and menu rows into `NoteEffect`s,
/// `NoteSheet(opening:)` picks the sheet an effect opens, and `PlaybackFollow` decides auto-follow and its resume timer.
/// This model keeps what the screen shows (the open sheet, the share sheet, the saved draft) and runs each effect
/// through the stores.
@MainActor @Observable final class NoteScreenModel {
    let noteID: UUID
    var screen: NoteScreenState
    var sheet: NoteSheet?
    /// The text typed so far into Name this speaker or Rename, kept with the open sheet.
    var sheetDraft: String?
    var shareItem: ShareItem?
    /// A Cassini document is being prepared.
    private(set) var exportingDocument = false
    var showBookmarks = false
    /// The saved progress of a stopped or failed job, for its read-only draft.
    private(set) var savedDraft: [DraftWord] = []
    /// This screen, as the owner of the player.
    @ObservationIgnored let playerOwner = PlaybackOwner()
    @ObservationIgnored private var resumeFollow: Task<Void, Never>?
    /// The search kept with the stack was brought back into this screen.
    @ObservationIgnored private var restored = false

    init(noteID: UUID, query: String? = nil) {
        self.noteID = noteID
        screen = NoteScreenState(query: query)
    }

    // MARK: Effects

    func run(_ effect: NoteEffect?, _ stores: NoteScreenStores) {
        guard let effect else { return }
        let note = stores.library.note(noteID)
        if let opened = NoteSheet(opening: effect, in: note) {
            sheet = opened
            return
        }
        switch effect {
        case .seekAndPlay(let time): seek(time, stores)
        case .transcribe(let kind): Task { handle(await stores.processing.transcribe(noteID, kind: kind), stores) }
        case .startOver: Task { handle(await stores.processing.startOver(noteID), stores) }
        case .acknowledgeTrustAndPlay:
            stores.library.update(noteID) { $0.document?.trustAcknowledged = true }
            if stores.playback.owns(noteID) { stores.playback.play() }
        case .continueQueue: stores.processing.continueQueue()
        case .clearFailed: stores.processing.clearFailed(noteID)
        case .toggleStar: stores.library.update(noteID) { $0.isFavorite.toggle() }
        case .exportTranscript(let format):
            export(stores) { exports, id throws(ExportError) in try await exports.exportTranscript(id, format: format) }
        case .shareAudio: export(stores) { exports, id throws(ExportError) in try await exports.copyAudio(id) }
        case .exportDocument: exportDocument(stores)
        case .stop: stores.processing.stop(noteID)
        case .removeFromQueue: stores.processing.dequeue(noteID)
        case .moveToTrash: Task { await stores.trash.requestTrash(noteID) }
        case .nameSpeaker, .openVersions, .openSpeakers, .editPassage, .rename, .documentInfo:
            break // A sheet (above); a passage that is gone opens nothing.
        }
    }

    /// A row of the note's "…" menu.
    func perform(_ action: NoteMenuAction, note: Note, job: Job?, readOnly: ReadOnlyReason?, _ stores: NoteScreenStores) {
        run(screen.menu(action, note: note, job: job, readOnly: readOnly), stores)
    }

    /// "Mark this moment": the bookmark, and the section that lists it open.
    func markMoment(at time: TimeInterval, _ stores: NoteScreenStores) {
        stores.library.markMoment(noteID, at: time)
        showBookmarks = true
    }

    /// What queuing a transcription led to: without consent the model download asks first; a refusal says why.
    private func handle(_ outcome: TranscribeOutcome, _ stores: NoteScreenStores) {
        switch outcome {
        case .needsConsent: stores.router.push(.modelDownload(noteID: noteID))
        case .refused(let refusal): stores.errors.present(refusal.message)
        case .queued: break
        }
    }

    /// Plays from `time`, unless a recording holds the audio.
    func seek(_ time: TimeInterval, _ stores: NoteScreenStores) {
        guard !stores.recording.state.isActive, let note = stores.library.note(noteID) else { return }
        stores.playback.play(note, from: time)
    }

    /// Shares the file `file` writes for the note, or says why there is none.
    private func export(_ stores: NoteScreenStores,
                        _ file: @escaping @MainActor (ExportStore, UUID) async throws(ExportError) -> URL) {
        Task {
            do throws(ExportError) { shareItem = stores.exports.shareItem(try await file(stores.exports, noteID)) }
            catch { stores.errors.present(ExportCopy.message(error)) }
        }
    }

    private func exportDocument(_ stores: NoteScreenStores) {
        exportingDocument = true
        Task {
            do { shareItem = stores.exports.shareItem(try await stores.exports.exportPortable(noteID)) }
            catch { stores.errors.present(ExportCopy.notSaved) }
            exportingDocument = false
        }
    }

    // MARK: Opening

    /// Brings back the search the stack kept for this screen (when SwiftUI built the view again), and runs the
    /// Library's start action.
    func appeared(start: NoteStartAction?, _ stores: NoteScreenStores) {
        if !restored {
            restored = true
            if let kept = stores.router.session(noteID).search { screen.search = NoteScreenState(query: kept).search }
        }
        runStart(start, stores)
    }

    /// Runs the Library's start action once for the screen: the router remembers that it ran, and a route restored
    /// with the scene carries none. A screen leaving the stack forgets it ran, and runs nothing.
    func runStart(_ start: NoteStartAction?, _ stores: NoteScreenStores) {
        guard let start, stores.router.isOpen(noteID), !stores.router.session(noteID).started else { return }
        stores.router.markStarted(noteID)
        run(start.effect, stores)
    }

    /// Reads a stopped or failed job's saved progress for its draft; any other job shows none.
    func loadSavedDraft(job: Job?, _ processing: ProcessingStore) async {
        let stopped = job.map { $0.state == .paused || $0.state == .failed } == true
        let draft = stopped ? await processing.savedDraft(noteID) : []
        if !Task.isCancelled { savedDraft = draft }
    }

    // MARK: Follow

    /// A drag during playback pauses auto-follow; once the scrolling stops, `PlaybackFollow.resumeAfter` without
    /// scrolling resumes it.
    func scrolled(_ scrolling: PlaybackFollow.Scrolling, playing: Bool) {
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
    func resumeFollowing() {
        resumeFollow?.cancel()
        screen.follow.resume()
    }

    func disappeared(_ playback: PlaybackStore) {
        playback.leave(playerOwner)
        resumeFollow?.cancel()
    }
}

extension PlaybackFollow.Scrolling {
    init(_ phase: ScrollPhase) {
        switch phase {
        case .interacting: self = .dragging
        case .idle: self = .idle
        default: self = .moving
        }
    }
}
