import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The stores of one app run, built from an `AppEnvironment`, and the launch work that makes them ready.
@MainActor final class AppGraph {
    let environment: AppEnvironment
    let startup = Startup()
    let router = Router()
    let errors = ErrorPresenter()
    let notices = NoticesStore()
    let settings: SettingsStore
    let library: LibraryStore
    let voices: VoicesStore
    let playback: PlaybackStore
    let processing: ProcessingStore
    let recording: RecordingStore
    let imports: ImportStore
    let trash: TrashStore
    let exports: ExportStore

    init(environment: AppEnvironment) {
        self.environment = environment
        settings = SettingsStore(defaults: environment.defaults, clock: environment.clock,
                                 defaultLanguage: environment.locale.identifier(.bcp47))
        library = LibraryStore(root: environment.root, errors: errors)
        voices = VoicesStore(library: library, settings: settings, errors: errors)
        playback = PlaybackStore(playback: environment.playback, library: library, errors: errors, clock: environment.clock)
        processing = ProcessingStore(
            coordinator: Self.queue(environment, library: library, voices: voices, settings: settings),
            transcriber: environment.transcriber, analyzer: environment.analyzer, clock: environment.clock)
        recording = RecordingStore(capture: environment.capture, audio: environment.audio, storage: environment.storage,
                                   library: library, processing: processing, playback: playback, settings: settings,
                                   router: router, errors: errors, notices: notices, clock: environment.clock,
                                   locale: environment.locale, timeZone: environment.timeZone)
        imports = ImportStore(library: library, processing: processing, settings: settings, audio: environment.audio,
                              storage: environment.storage, router: router, errors: errors, clock: environment.clock)
        trash = TrashStore(library: library, voices: voices, processing: processing, playback: playback,
                           recording: recording, settings: settings, router: router, errors: errors,
                           clock: environment.clock, calendar: environment.calendar)
        exports = ExportStore(library: library)
        processing.modelDownload = ModelDownloadAdapter(
            settings: settings, processing: processing, transcriber: environment.transcriber,
            analyzer: environment.analyzer, storage: environment.storage, notifier: environment.notifier,
            root: environment.root)
        registerStartup()
    }

    /// The transcription queue over the library's notes; none when the library could not be opened.
    private static func queue(_ environment: AppEnvironment, library: LibraryStore, voices: VoicesStore,
                              settings: SettingsStore) -> TranscriptionCoordinator? {
        guard let notes = library.noteStore else { return nil }
        let job = WholeFileTranscriptionJob(
            notes: notes, transcriber: environment.transcriber, analyzer: environment.analyzer,
            options: {
                .init(allowSpeechDownload: settings.downloadsAllowed, identifySpeakers: settings.identifySpeakers,
                      allowSpeakerDownload: settings.speakerDownloadsAllowed, voicesGeneration: settings.voicesGeneration)
            },
            applySpeakers: { analysis, id, generation in
                try await voices.applySpeakerAnalysis(analysis, to: id, generation: generation)
            })
        let parts = TranscriptionCoordinator.Parts(
            jobs: JobStore(repository: JobRepository(root: environment.root)), notes: notes, runner: job,
            checkpoints: WorkDirectories(root: environment.root),
            consent: .recorded(settings: settings, speech: environment.transcriber, speakers: environment.analyzer),
            notifier: environment.notifier, background: environment.background, clock: environment.clock,
            backgroundTitle: { String(localized: "Transcribing “\($0)”", table: "Transcription",
                                      comment: "The system's progress while a note is transcribed") })
        return TranscriptionCoordinator(parts, settings: settings)
    }

    /// Runs the launch steps once; the app is ready when it returns.
    @discardableResult func start() async -> StartupReport {
        let report = await startup.run()
        #if DEBUG
        if let seed = environment.launch.seed { TestFixtures.prepare(seed, settings: settings, processing: processing) }
        switch environment.launch.openFixture {
        case .note(let id): router.openNote(id)
        case .newest: if let id = library.notes.first?.id { router.openNote(id) }
        case nil: break
        }
        #endif
        return report
    }

    /// Saves the playback position and keeps the app awake until every pending write has landed.
    func enterBackground() {
        let token = environment.background.begin(title: "Saving your recordings", progress: Progress(), onExpire: {})
        playback.savePosition()
        Task { [library, background = environment.background] in
            await library.settle()
            background.end(token)
        }
    }

    private func registerStartup() {
        #if DEBUG
        if let seed = environment.launch.seed, let store = library.noteStore {
            startup.register(.load) { [environment] in
                try await TestFixtures.seed(seed, into: store, now: environment.clock.now)
            }
        }
        #endif
        startup.register(.load) { [library, voices, notices] in
            await library.load()
            if library.unreadableCount > 0 {
                notices.post("\(library.unreadableCount) recording documents could not be read. Their files have been preserved.")
            }
            if library.loadFailure == nil, !voices.load() {
                notices.post("Saved voices could not be read. Their files have been preserved. Recordings remain available.")
            }
        }
        startup.register(.recover) { [recording] in await recording.recoverInterrupted() }
        startup.register(.reconcile) { [processing, recording] in
            try await processing.reconcileOnStart(activeNoteID: recording.state.noteID)
        }
        startup.register(.purge) { [trash] in await trash.purgeExpired() }
    }
}

extension View {
    /// Puts every store of `graph` into the environment.
    func environment(_ graph: AppGraph) -> some View {
        self
            .environment(graph.router).environment(graph.errors).environment(graph.notices)
            .environment(graph.settings).environment(graph.library).environment(graph.voices)
            .environment(graph.playback).environment(graph.processing).environment(graph.recording)
            .environment(graph.imports).environment(graph.trash).environment(graph.exports)
            .environment(\.clock, graph.environment.clock)
            .environment(\.locale, graph.environment.locale)
            .environment(\.timeZone, graph.environment.timeZone)
            .environment(\.calendar, graph.environment.calendar)
    }
}
