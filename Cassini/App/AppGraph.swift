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
    let trash: TrashService
    let exports: ExportStore
    /// What the Settings screen reads.
    let settingsPorts: SettingsAdapter

    init(environment: AppEnvironment) {
        self.environment = environment
        settings = SettingsStore(defaults: environment.defaults, clock: environment.clock,
                                 defaultLanguage: environment.locale.identifier(.bcp47))
        library = LibraryStore(root: environment.root, errors: errors)
        voices = VoicesStore(library: library, settings: settings, errors: errors, clock: environment.clock)
        playback = PlaybackStore(playback: environment.playback, library: library)
        processing = Self.processing(environment: environment, library: library, voices: voices, settings: settings,
                                     notices: notices)
        recording = RecordingStore(.init(environment: environment, library: library, processing: processing,
                                         playback: playback, settings: settings, router: router, notices: notices,
                                         ready: { [startup] in _ = await startup.ready() }))
        let importService = library.noteStore.map {
            ImportService(notes: $0, files: CoordinatedFileImporter(storage: environment.storage), audio: environment.audio,
                          storage: environment.storage, clock: environment.clock)
        }
        imports = ImportStore(service: importService, library: library, processing: processing, settings: settings,
                              router: router, clock: environment.clock) { [startup] in _ = await startup.ready() }
        trash = TrashService(.init(
            notes: library, queue: processing, voices: voices,
            host: AppTrashHost(recording: recording, playback: playback, router: router, settings: settings),
            undo: TrashUndo(), clock: environment.clock, calendar: environment.calendar))
        exports = ExportStore(library: library, portable: PortableExportService(audio: environment.audio),
                              folder: environment.exports,
                              locale: environment.locale, timeZone: environment.timeZone) { [startup] in _ = await startup.ready() }
        processing.modelDownload = ModelDownloadAdapter(
            settings: settings, processing: processing, transcriber: environment.transcriber,
            analyzer: environment.analyzer, storage: environment.storage, notifier: environment.notifier,
            root: environment.root)
        settingsPorts = SettingsAdapter(settings: settings, library: library, voices: voices, processing: processing,
                                        notifier: environment.notifier)
        registerStartup()
    }

    /// The transcription queue and the job it runs, over the library's notes. Without a library there is no queue.
    private static func processing(environment: AppEnvironment, library: LibraryStore, voices: VoicesStore,
                                   settings: SettingsStore, notices: NoticesStore) -> ProcessingStore {
        let progress = JobProgress(battery: UIDeviceBattery(), onFinalization: { [settings] in settings.recordFinalization($0) })
        let checkpoints: any CheckpointStoring = library.noteStore.map { CheckpointFiles(notes: $0) } ?? NoLibraryWork()
        let coordinator = library.noteStore.map { notes in
            let job = TranscriptionJob(notes: notes, transcriber: environment.transcriber, analyzer: environment.analyzer,
                                       checkpoints: checkpoints, provenance: ProvenanceFiles(notes: notes),
                                       host: AppJobHost(settings: settings, voices: voices), clock: environment.clock)
            let parts = TranscriptionCoordinator.Parts(
                jobs: JobStore(repository: JobRepository(root: environment.root)), notes: notes, runner: job,
                checkpoints: NoteWorkFolders(notes: notes),
                consent: .recorded(settings: settings, speech: environment.transcriber, speakers: environment.analyzer),
                notifier: environment.notifier, background: environment.background, clock: environment.clock,
                backgroundTitle: { String(localized: "Transcribing “\($0)”", table: "Transcription",
                                          comment: "The system's progress while a note is transcribed") },
                progress: progress)
            return TranscriptionCoordinator(parts, settings: settings)
        }
        let models = ModelInstalls(transcriber: environment.transcriber, analyzer: environment.analyzer,
                                   clock: environment.clock) { [settings] in settings.speechLanguage }
        return ProcessingStore(coordinator: coordinator, progress: progress, checkpoints: checkpoints, models: models,
                               analyzer: environment.analyzer, library: library, notices: notices)
    }

    /// Runs the launch steps once; the app is ready when it returns.
    @discardableResult func start() async -> StartupReport {
        let report = await startup.run()
        // The models' status is read once the library is ready, without holding the launch for it.
        Task { [models = processing.models] in await models.refresh() }
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
        Task { [playback, library, background = environment.background] in
            await playback.settle()
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
        startup.register(.load) { [recording] in await recording.rebuildBareDirectories() }
        startup.register(.load) { [library, voices, notices] in
            await library.load()
            if library.unreadableCount > 0 {
                notices.post("\(library.unreadableCount) recording documents could not be read. Their files have been preserved.")
            }
            if library.loadFailure == nil, !(await voices.load()) {
                notices.post("Saved voices could not be read. Their files have been preserved. Recordings remain available.")
            }
        }
        startup.register(.recover) { [recording] in await recording.recoverInterrupted() }
        startup.register(.reconcile) { [processing, recording] in
            try await processing.reconcileOnStart(activeNoteID: recording.state.noteID)
        }
        startup.register(.voiceLinks) { [voices] in try await voices.sweepOrphans() }
        // Unreadable saved voices delete nothing; the report keeps the failure and the trash its fact, with no alert.
        startup.register(.purge) { [trash] in try await trash.purgeExpired() }
        startup.register(.sweep) { [exports, clock = environment.clock] in await exports.sweep(now: clock.now) }
    }
}

/// The saved progress of the notes when the library could not be opened: there is none.
private struct NoLibraryWork: CheckpointStoring {
    func load(_ noteID: UUID) throws -> CheckpointState? { nil }
    func save(_ state: CheckpointState, for noteID: UUID) throws { throw CocoaError(.fileWriteUnknown) }
    func discard(_ noteID: UUID) throws {}
    func exists(_ noteID: UUID) -> Bool { false }
}

extension View {
    /// Puts every store of `graph` into the environment.
    func environment(_ graph: AppGraph) -> some View {
        self
            .environment(graph.router).environment(graph.errors).environment(graph.notices)
            .environment(graph.settings).environment(graph.library).environment(graph.voices)
            .environment(graph.playback).environment(graph.processing).environment(graph.processing.progress)
            .environment(graph.recording)
            .environment(graph.imports).environment(graph.trash).environment(graph.trash.undo).environment(graph.exports)
            .environment(graph.settingsPorts)
            .environment(\.clock, graph.environment.clock)
            .environment(\.locale, graph.environment.locale)
            .environment(\.timeZone, graph.environment.timeZone)
            .environment(\.calendar, graph.environment.calendar)
    }
}
