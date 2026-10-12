import Foundation
import Observation
import CassiniAudio
import CassiniEngine
import CassiniNotebook

/// Audio and Cassini documents opened from other apps or the file picker, one at a time.
@MainActor @Observable final class ImportStore {
    private(set) var isImporting = false

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let processing: ProcessingStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let audio: any AudioProcessing
    @ObservationIgnored private let storage: any StorageProbe
    @ObservationIgnored private let router: Router
    @ObservationIgnored private let errors: ErrorPresenter
    @ObservationIgnored private let clock: any AppClock

    init(library: LibraryStore, processing: ProcessingStore, settings: SettingsStore, audio: any AudioProcessing,
         storage: any StorageProbe, router: Router, errors: ErrorPresenter, clock: any AppClock) {
        self.library = library; self.processing = processing; self.settings = settings; self.audio = audio
        self.storage = storage; self.router = router; self.errors = errors; self.clock = clock
    }

    /// Copies the file into a new note and opens it. The source is never changed.
    func importAudio(_ url: URL) async {
        guard !isImporting, let root = library.root else { return }
        isImporting = true; defer { isImporting = false }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let ext = url.pathExtension.lowercased()
        let safeExtension = !ext.isEmpty && ext.count < 8 && ext.allSatisfy { $0.isLetter || $0.isNumber } ? ext : "audio"
        var note = Note(title: url.deletingPathExtension().lastPathComponent, createdAt: clock.now, audioFilename: "audio.\(safeExtension)")
        note.language = settings.speechLanguage; note.origin = .imported
        guard let folder = library.directory(for: note.id) else { return }
        do {
            guard storage.availableBytes(at: root) >= Limits.minRecordingFreeBytes else { throw AudioError.storageLow }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let destination = folder.appendingPathComponent(note.audioFilename)
            try await Task.detached(priority: .userInitiated) { try FileManager.default.copyItem(at: url, to: destination) }.value
            let portable = await Task.detached(priority: .userInitiated) { PortableTranscript.read(from: destination) }.value
            if let portable {
                note.title = portable.title; note.language = portable.language; note.origin = .importedDocument
                note.duration = portable.duration; note.transcript = portable.segments; note.status = .ready
                note.speakers = portable.speakers; note.versions = portable.versions; note.selectedVersionID = portable.selectedVersionID
            }
            if ["opus", "ogg"].contains(ext) {
                let decoded = folder.appendingPathComponent("playback.caf")
                do {
                    try await audio.decodeOpus(destination, to: decoded)
                    note.originalAudioFilename = note.audioFilename; note.audioFilename = "playback.caf"
                } catch {
                    try? FileManager.default.removeItem(at: decoded)
                    if portable == nil { throw error }
                }
            }
            do {
                let summary = try await audio.inspect(folder.appendingPathComponent(note.audioFilename))
                note.duration = summary.duration; note.waveform = summary.waveform
            } catch {
                guard portable != nil else { throw error }
                note.audio = .unplayable(.unsupportedFormat)
            }
            try await library.insert(note)
            router.openNote(note.id)
            if portable == nil && settings.autoTranscribe && settings.downloadsAllowed { processing.enqueue(note.id) }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            errors.present("Could not import audio: \(error.localizedDescription)")
        }
    }
}
