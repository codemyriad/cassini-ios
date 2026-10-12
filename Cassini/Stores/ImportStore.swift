import Foundation
import Observation
import UniformTypeIdentifiers
import CassiniEngine
import CassiniNotebook

/// Audio and Cassini documents from the file picker or opened from other apps. Each file is imported on its own, side
/// by side; `ImportTracker` shows the ones that run and the last failure.
@MainActor @Observable final class ImportStore {
    /// What the picker offers: audio (Ogg Opus and Cassini documents included) and any Ogg file.
    static let contentTypes: [UTType] = [.audio, UTType("org.xiph.opus"), UTType(filenameExtension: "ogg")]
        .compactMap { $0 }

    let tracker: ImportTracker

    @ObservationIgnored private let service: ImportService?
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let processing: ProcessingStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let router: Router

    init(service: ImportService?, library: LibraryStore, processing: ProcessingStore, settings: SettingsStore,
         router: Router, clock: any AppClock) {
        self.service = service; self.library = library; self.processing = processing; self.settings = settings
        self.router = router
        tracker = ImportTracker(clock: clock)
    }

    /// Files picked in the Library: each becomes a note in the list, as on Android; nothing opens.
    func start(_ urls: [URL]) {
        for url in urls { importFile(url, opensNote: false) }
    }

    /// A file opened from another app: its note opens when the import ends, the note already there for a file
    /// imported before.
    func open(_ url: URL) { importFile(url, opensNote: true) }

    /// Imports `url` and returns the outcome; nil when the import was cancelled or failed unexpectedly.
    @discardableResult
    func importFile(_ url: URL, opensNote: Bool) -> Task<ImportOutcome?, Never> {
        let language = settings.speechLanguage
        let fallbackTitle = String(localized: "Imported audio", table: "Import")
        let running = tracker.start(displayName: Self.displayName(of: url)) { [service] in
            guard let service else { return .rejected(.cannotSave) }
            return try await service.importFile(url, language: language, fallbackTitle: fallbackTitle)
        }
        return Task {
            let outcome = await running.value
            if let outcome { await finish(outcome, opensNote: opensNote) }
            return outcome
        }
    }

    private func finish(_ outcome: ImportOutcome, opensNote: Bool) async {
        if case .created(let id) = outcome, let note = await library.noteStore?.note(id) {
            library.adopt(note)
            if ImportedNote.wantsTranscription(note) && settings.autoTranscribe && settings.downloadsAllowed {
                processing.enqueue(id)
            }
        }
        if opensNote, let id = outcome.noteID { router.openNote(id) }
    }

    private static func displayName(of url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? String(localized: "Imported audio", table: "Import") : name
    }
}
