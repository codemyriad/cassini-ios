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
        settings = SettingsStore(defaults: environment.defaults, clock: environment.clock)
        library = LibraryStore(root: environment.root, errors: errors)
        voices = VoicesStore(library: library, settings: settings, errors: errors)
        playback = PlaybackStore(playback: environment.playback, library: library, errors: errors, clock: environment.clock)
        processing = ProcessingStore(transcriber: environment.transcriber, analyzer: environment.analyzer,
                                     background: environment.background, library: library, voices: voices,
                                     settings: settings, notices: notices)
        recording = RecordingStore(capture: environment.capture, audio: environment.audio, storage: environment.storage,
                                   library: library, processing: processing, playback: playback, settings: settings,
                                   router: router, errors: errors, notices: notices, clock: environment.clock,
                                   locale: environment.locale, timeZone: environment.timeZone)
        imports = ImportStore(library: library, processing: processing, settings: settings, audio: environment.audio,
                              storage: environment.storage, router: router, errors: errors, clock: environment.clock)
        trash = TrashStore(library: library, voices: voices, processing: processing, playback: playback,
                           recording: recording, settings: settings, errors: errors, clock: environment.clock,
                           calendar: environment.calendar)
        exports = ExportStore(library: library)
        registerStartup()
    }

    /// Runs the launch steps once; the app is ready when it returns.
    @discardableResult func start() async -> StartupReport {
        let report = await startup.run()
        #if DEBUG
        if let seed = environment.launch.seed { TestFixtures.prepare(seed, settings: settings, processing: processing) }
        if let fixture = environment.launch.openFixture, let id = fixture ?? library.notes.first?.id { router.openNote(id) }
        #endif
        return report
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
        startup.register(.reconcile) { [processing] in processing.reconcileOnStart() }
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
