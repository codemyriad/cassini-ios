import Foundation
import Observation
import UniformTypeIdentifiers
import CassiniEngine
import CassiniCore
import CassiniNotebook

/// Audio, Cassini documents and ZIP archives. Picker selections run as one cancellable batch;
/// individual audio files opened from other apps keep their existing open-note behavior.
@MainActor @Observable final class ImportStore {
    /// What the picker offers: audio (Ogg Opus and Cassini documents included) and any Ogg file.
    static let contentTypes: [UTType] = [.audio, UTType("org.xiph.opus"), UTType(filenameExtension: "ogg"), .zip]
        .compactMap { $0 }

    let tracker: ImportTracker
    private(set) var batchProgress: BulkProgress?
    private(set) var batchSummary: BulkImportSummary?
    private(set) var batchCancelled = false
    private(set) var batchArchiveFailures: [ZipArchiveError] = []
    @ObservationIgnored private var batchTask: Task<Void, Never>?
    @ObservationIgnored private var queuedURLs: [URL] = []

    @ObservationIgnored private let service: ImportService?
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let processing: ProcessingStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let router: Router
    @ObservationIgnored private let ready: @MainActor () async -> Void

    /// `ready` returns once the launch work has run: an import checks for a note with the same bytes, adds its note
    /// and queues it only against the loaded library and transcription queue. A file opened from another app on a cold
    /// launch arrives before that.
    init(service: ImportService?, library: LibraryStore, processing: ProcessingStore, settings: SettingsStore,
         router: Router, clock: any AppClock, ready: @escaping @MainActor () async -> Void) {
        self.service = service; self.library = library; self.processing = processing; self.settings = settings
        self.router = router; self.ready = ready
        tracker = ImportTracker(clock: clock)
    }

    /// One selection is a batch. Further incoming ZIP selections queue behind it, never overlap it.
    func start(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        queuedURLs.append(contentsOf: urls)
        beginQueuedBatch()
    }

    private func beginQueuedBatch() {
        guard batchTask == nil, !queuedURLs.isEmpty else { return }
        batchSummary = BulkImportSummary()
        batchArchiveFailures = []
        batchCancelled = false
        batchProgress = BulkProgress(completed: 0, total: queuedURLs.count)
        let fallbackTitle = String(localized: "Imported audio", table: "Import")
        batchTask = Task {
            defer {
                batchProgress = nil
                batchTask = nil
                // A selection made after cancellation/error belongs to a fresh task, not the one unwinding.
                beginQueuedBatch()
            }
            await ready()
            do {
                try Task.checkCancellation()
                guard let service, library.loadFailure == nil else {
                    batchSummary?.failed += queuedURLs.count
                    queuedURLs = []
                    return
                }
                while !queuedURLs.isEmpty {
                    try Task.checkCancellation()
                    let next = queuedURLs
                    queuedURLs = []
                    let previous = batchSummary ?? BulkImportSummary()
                    let summary = try await service.importBatch(next, fallbackTitle: fallbackTitle) { [weak self] event in
                        await self?.receive(event)
                    }
                    // Final engine counts are authoritative, including unsupported entries with no note outcome.
                    var combined = summary
                    combined.imported += previous.imported
                    combined.duplicates += previous.duplicates
                    combined.unsupported += previous.unsupported
                    combined.failed += previous.failed
                    combined.outcomes = previous.outcomes + summary.outcomes
                    combined.archiveFailures = batchArchiveFailures
                    batchSummary = combined
                }
            } catch is CancellationError {
                batchCancelled = true
            } catch {
                batchSummary?.failed += 1
            }
        }
    }

    func cancelBatch() {
        // Discard only selections queued before this cancellation. Later selections must survive the old catch.
        queuedURLs = []
        batchTask?.cancel()
    }
    func settleBatch() async {
        while let task = batchTask { await task.value }
    }
    /// Launch runs this before the ready fence releases any incoming picker/open-URL batch.
    func sweepBatchStaging() async { await service?.sweepBatchStaging() }

    private func receive(_ event: BulkImportEvent) async {
        switch event {
        case .progress(let completed, let total): batchProgress = BulkProgress(completed: completed, total: total)
        case .outcome(let outcome):
            switch outcome {
            case .created: batchSummary?.imported += 1
            case .existing: batchSummary?.duplicates += 1
            case .rejected: batchSummary?.failed += 1
            }
            batchSummary?.outcomes.append(outcome)
            await finish(outcome, opensNote: false)
        case .unsupported(let count): batchSummary?.unsupported += count
        case .archiveFailure(let failure):
            batchArchiveFailures.append(failure)
            batchSummary?.archiveFailures.append(failure)
            batchSummary?.failed += 1
        }
    }

    /// A file opened from another app: its note opens when the import ends, the note already there for a file
    /// imported before.
    func open(_ url: URL) {
        if url.pathExtension.lowercased() == "zip" { start([url]) }
        else { importFile(url, opensNote: true) }
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
            if let outcome { await finish(outcome, opensNote: opensNote) }
            return outcome
        }
    }

    private func finish(_ outcome: ImportOutcome, opensNote: Bool) async {
        if case .created(let id) = outcome, let note = await library.noteStore?.note(id) {
            library.adopt(note)
        }
        if opensNote, let id = outcome.noteID { router.openNote(id) }
        // After the note opens, so the model download screen can ask over it.
        if case .created(let id) = outcome, let note = library.note(id), ImportedNote.wantsTranscription(note),
           settings.autoTranscribe, await processing.handOff(id) == .askConsent {
            router.offerModelDownload(for: id)
        }
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
