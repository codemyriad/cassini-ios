import Foundation
import Observation
import UniformTypeIdentifiers
import CassiniEngine
import CassiniNotebook

/// Audio and Cassini documents from the file picker or opened from other apps. Each file is imported on its own, side
/// by side; `ImportTracker` shows the ones that run and the last failure.
@MainActor @Observable final class ImportStore {
    /// What the picker offers: audio (Ogg Opus and Cassini documents included) and any Ogg file.
    static let contentTypes: [UTType] = [.audio, .zip, UTType("org.xiph.opus"), UTType(filenameExtension: "ogg")]
        .compactMap { $0 }

    let tracker: ImportTracker
    var batches: [ImportBatch] = []

    @ObservationIgnored private let service: ImportService?
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let processing: ProcessingStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let router: Router
    @ObservationIgnored private let ready: @MainActor () async -> Void
    @ObservationIgnored private let files: (any FileImporting)?
    @ObservationIgnored private let scratch: URL

    /// `ready` returns once the launch work has run: an import checks for a note with the same bytes, adds its note
    /// and queues it only against the loaded library and transcription queue. A file opened from another app on a cold
    /// launch arrives before that.
    init(service: ImportService?, library: LibraryStore, processing: ProcessingStore, settings: SettingsStore,
         router: Router, clock: any AppClock, files: (any FileImporting)? = nil,
         scratch: URL = URL.temporaryDirectory.appendingPathComponent("CassiniImports"),
         ready: @escaping @MainActor () async -> Void) {
        self.service = service; self.library = library; self.processing = processing; self.settings = settings
        self.router = router; self.ready = ready
        self.files = files; self.scratch = scratch
        tracker = ImportTracker(clock: clock)
    }

    /// Files picked in the Library: each becomes a note in the list, as on Android; nothing opens.
    func start(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        tracker.dismissFailure()
        guard let files, let service else { for url in urls { importFile(url, opensNote: false) }; return }
        let batch = ImportBatch(total: urls.count)
        batches.append(batch)
        let fallback = String(localized: "Imported audio", table: "Import")
        let operation = BulkImportService(files: files, scratch: scratch) { url, name in
            try await service.importFile(url, fallbackTitle: fallback, displayName: name)
        }
        batch.task = Task { [self] in
            await ready()
            guard library.loadFailure == nil else {
                var report = BulkImportReport(); report.summary.failed = urls.count
                batch.report = report; batch.task = nil; return
            }
            batch.report = await operation.run(urls, progress: { value in await MainActor.run { batch.progress = value } },
                                               imported: { [self] outcome in
                let pending = await finish(outcome, opensNote: false, offersConsent: false)
                await MainActor.run { if batch.pendingConsent == nil { batch.pendingConsent = pending } }
            })
            if let failure = batch.report?.storageFailure { tracker.recordFailure(failure, displayName: fallback) }
            batch.task = nil
            if batch.report?.cancelled == false, batch.report?.storageFailure == nil, let pending = batch.pendingConsent { router.offerModelDownload(for: pending) }
        }
    }

    /// A file opened from another app: its note opens when the import ends, the note already there for a file
    /// imported before.
    func open(_ url: URL) {
        if url.pathExtension.lowercased() == "zip" { start([url]) } else { importFile(url, opensNote: true) }
    }

    /// Imports `url` and returns the outcome; nil when the import was cancelled or failed unexpectedly.
    @discardableResult
    func importFile(_ url: URL, opensNote: Bool) -> Task<ImportOutcome?, Never> {
        let fallbackTitle = String(localized: "Imported audio", table: "Import")
        let running = tracker.start(displayName: Self.displayName(of: url)) { [service, library, ready] in
            await ready()
            try Task.checkCancellation()
            guard let service, await library.loadFailure == nil else { return .rejected(.cannotSave) }
            return try await service.importFile(url, fallbackTitle: fallbackTitle)
        }
        return Task {
            let outcome = await running.value
            if let outcome { _ = await finish(outcome, opensNote: opensNote) }
            return outcome
        }
    }

    private func finish(_ outcome: ImportOutcome, opensNote: Bool, offersConsent: Bool = true) async -> UUID? {
        if case .created(let id) = outcome, let note = await library.noteStore?.note(id) {
            library.adopt(note)
        }
        if opensNote, let id = outcome.noteID { router.openNote(id) }
        // After the note opens, so the model download screen can ask over it.
        if case .created(let id) = outcome, let note = library.note(id), ImportedNote.wantsTranscription(note),
           settings.autoTranscribe, await processing.handOff(id) == .askConsent {
            if offersConsent { router.offerModelDownload(for: id) }
            return id
        }
        return nil
    }

    private static func displayName(of url: URL) -> String {
        let name = url.lastPathComponent
        return name.isEmpty || name == "/" ? String(localized: "Imported audio", table: "Import") : name
    }
}

// MARK: Notices

extension ImportStore {
    /// Adds the running imports and the last failure to the facts the banners are built from.
    func contribute(to facts: inout NoticeFacts) {
        facts.importing = tracker.running
        facts.importFailure = tracker.failure
    }

    /// The user closed an import error: it stays closed until the next import fails.
    func dismissNotice(_ kind: BannerKind) {
        if kind.isImportFailure { tracker.dismissFailure() }
    }
}
