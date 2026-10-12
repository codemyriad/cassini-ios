import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// The app's side of recording: the controller and the Recording screen's model from CassiniEngine, the navigation
/// they ask for, the Live Activity's buttons, bookmarks, and the recovery at launch.
@MainActor @Observable final class RecordingStore {
    let controller: RecordingController
    let screen: RecordingScreenModel
    /// Recordings recovered at this launch, oldest first, for the "recording recovered" notice.
    private(set) var recovered: [RecoveredRecording] = []

    @ObservationIgnored private let recovery: CaptureRecovery
    /// Notes rebuilt from bare audio at this launch, until they are reported with the repaired ones.
    @ObservationIgnored private var rebuilt: [RecoveredRecording] = []
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let playback: PlaybackStore
    @ObservationIgnored private let router: Router
    @ObservationIgnored private let notices: NoticesStore

    struct Parts {
        var environment: AppEnvironment
        var library: LibraryStore
        var processing: ProcessingStore
        var playback: PlaybackStore
        var settings: SettingsStore
        var router: Router
        var notices: NoticesStore
        var ready: @MainActor () async -> Void
    }

    init(_ parts: Parts) {
        let environment = parts.environment
        let locale = environment.locale, timeZone = environment.timeZone
        library = parts.library; playback = parts.playback; router = parts.router; notices = parts.notices
        controller = RecordingController(parts: .init(
            ready: parts.ready, notes: LibraryRecordingNotes(library: parts.library), capture: environment.capture, storage: environment.storage,
            audio: environment.audio, settings: parts.settings, handoff: ProcessingHandoff(parts.processing),
            consent: .recorded(settings: parts.settings, speech: environment.transcriber, speakers: environment.analyzer),
            liveActivity: environment.liveActivity, notifier: environment.notifier, clock: environment.clock,
            defaultTitle: { RecordingCopy.defaultTitle(RecordingTitles.dateTime($0, locale: locale, timeZone: timeZone)) }))
        let transcriber = environment.transcriber, settings = parts.settings
        screen = RecordingScreenModel(controller: controller, ports: .init(
            permission: environment.microphone,
            modelsMissing: { await transcriber.assetStatus(locale: Locale(identifier: settings.speechLanguage)) != .ready },
            notifier: environment.notifier, settings: settings))
        recovery = CaptureRecovery(audio: environment.audio, repairer: CAFCaptureRepairer(), clock: environment.clock,
                                   recoveredTitle: { RecordingCopy.recoveredTitle(RecordingTitles.day($0, locale: locale, timeZone: timeZone)) })
        screen.onEffect = { [weak self] in self?.perform($0) }
        controller.onCompressionFailed = { [weak self] _ in self?.notices.post(RecordingCopy.compressionFailed) }
        controller.observe { [weak self] state in self?.playback.setBlocked(state.inProgress) }
        RecordingIntentRouter.handler = { [weak self] action, noteID in self?.perform(action, for: noteID) }
    }

    var state: RecordingState { controller.state }

    var isBusy: Bool {
        switch state {
        case .starting, .finishing: true
        default: false
        }
    }

    /// The note whose audio is still being sealed or compressed.
    var finishingNoteID: UUID? {
        if case .finishing(let id) = state { return id }
        return controller.finalizing.first
    }

    /// Shows the Recording screen and starts a recording there, or returns to the one in progress.
    func start() async {
        router.presentRecording()
        await screen.enter()
    }

    /// Back to the recording in progress (the Live Activity's tap).
    func returnToRecording() {
        if state.inProgress || screen.ended != nil { router.presentRecording() }
    }

    /// "Mark a moment": a bookmark at the time captured now.
    func addBookmark() {
        guard let id = state.activeRecording?.noteID else { return }
        let time = controller.currentElapsed, bookmark = UUID()
        library.update(id) { $0.addBookmark(at: time, id: bookmark) }
    }

    /// Whether the app is on screen: automatic stops in the background are notified, and coming back may start a
    /// recording that was waiting for microphone access.
    func appActivityChanged(isActive: Bool) {
        controller.isAppActive = isActive
        if isActive { screen.appBecameActive() }
    }

    // MARK: Launch

    /// Before the notes are read: notes for directories that kept their audio but lost `note.json`.
    func rebuildBareDirectories() async {
        guard let root = library.root, let repository = try? NoteRepository(root: root) else { return }
        rebuilt = await recovery.rebuild(in: repository)
    }

    /// After: repairs the captures that were live when Cassini closed, and reports them with the rebuilt notes.
    func recoverInterrupted() async {
        guard let store = library.noteStore else { return }
        let repaired = await recovery.recover(in: store, activeNoteID: state.noteID)
        await library.refresh() // The reconcile that follows reads the mirror.
        let created = { [library] (recording: RecoveredRecording) in library.note(recording.noteID)?.createdAt ?? .distantPast }
        recovered = (rebuilt + repaired).sorted { created($0) < created($1) }
        rebuilt = []
        guard !recovered.isEmpty else { return }
        let captured = recovered.reduce(0) { $0 + $1.duration }
        notices.post(RecordingCopy.recovered(count: recovered.count, captured: captured))
    }

    // MARK: Effects

    private func perform(_ effect: RecordingEffect) {
        switch effect {
        case .close:
            router.dismissRecording()
        case .openSettings:
            openSystemSettings()
        case .show:
            router.presentRecording()
        case .openNote(let id, let modelDownload):
            router.dismissRecording()
            router.openNote(id)
            if modelDownload { router.push(.modelDownload(noteID: id)) }
        }
    }

    /// A Live Activity button; one left by an earlier recording does nothing.
    private func perform(_ action: RecordingIntentAction, for noteID: UUID) {
        guard state.activeRecording?.noteID == noteID else { return }
        switch action {
        case .pause: controller.pause()
        case .resume: controller.resume()
        case .finish: controller.finish()
        }
    }
}
