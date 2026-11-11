import CassiniCore
import CassiniNotebook
import Foundation

/// "Import audio" (Android `ImportRepository`, architecture section 4.2). An import:
///
/// 1. copies the file into `<root>/<newId>/source.tmp` with its SHA-256, within the size cap and the free space
///    (`FileImporting`);
/// 2. gives `existing` when a live note has the same bytes (one in Recently Deleted does not count);
/// 3. classifies the copy by its first bytes, never by its name: Ogg Opus that names a Cassini format becomes
///    `document.opus`, read and verified once now; other Ogg Opus `source.opus`; anything else `source.<ext>` when
///    AVFoundation reads it. Opus is decoded to `playback.caf`, which the note plays;
/// 4. writes the note, unless a live note got the same bytes meanwhile.
///
/// Imports run beside each other and beside a transcription. Nothing is left behind when one is rejected or cancelled,
/// and a storage error after the copy is a `cannotSave` or `noSpace` outcome, not an error.
public struct ImportService: Sendable {
    public static let stagingFilename = "source.tmp"
    public static let plainOpusFilename = "source.opus"
    public static let documentFilename = "document.opus"
    public static let playbackFilename = "playback.caf"

    private let notes: NoteStore
    private let files: any FileImporting
    private let audio: any AudioProcessing
    private let storage: any StorageProbe
    private let clock: any AppClock

    public init(notes: NoteStore, files: any FileImporting, audio: any AudioProcessing, storage: any StorageProbe,
                clock: any AppClock) {
        self.notes = notes; self.files = files; self.audio = audio; self.storage = storage; self.clock = clock
    }

    public func importBatch(_ urls: [URL], fallbackTitle: String,
                            onEvent: @escaping @Sendable (BulkImportEvent) async -> Void = { _ in }) async throws -> BulkImportSummary {
        try await bulkImporter.importFiles(urls, fallbackTitle: fallbackTitle, onEvent: onEvent)
    }

    public func sweepBatchStaging() async { await bulkImporter.sweep() }

    /// Signature/extension-less ZIP entries get the same platform audio probe as an ordinary file-picker import.
    func canInspectAudio(_ url: URL) async throws -> Bool {
        do { _ = try await audio.inspect(url); return true }
        catch is CancellationError { throw CancellationError() }
        catch { return false }
    }

    private var bulkImporter: BulkImportService {
        BulkImportService(importer: self, files: files, storage: storage,
                          folder: notes.root.appendingPathComponent(".bulk-imports", isDirectory: true))
    }

    /// Imports `url` as a new note, in the language of the document's selected variant (none for plain audio);
    /// `fallbackTitle` names a file without a usable name. Throws only `CancellationError`, and then leaves nothing
    /// behind.
    public func importFile(_ url: URL, fallbackTitle: String, displayName: String? = nil) async throws -> ImportOutcome {
        let id = UUID()
        let folder = notes.directory(for: id)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return .rejected(storageFailure(bytes: 0))
        }
        let outcome: ImportOutcome
        do {
            outcome = try await stage(url, as: id, in: folder, fallbackTitle: fallbackTitle, displayName: displayName)
        } catch {
            await discard(id, folder)
            throw error
        }
        if case .created = outcome {} else { await discard(id, folder) }
        return outcome
    }

    private func stage(_ url: URL, as id: UUID, in folder: URL, fallbackTitle: String, displayName: String?) async throws -> ImportOutcome {
        let staging = folder.appendingPathComponent(Self.stagingFilename)
        var copied: ImportedFile
        do {
            copied = try await files.copy(from: url, to: staging, maxBytes: Limits.maxImportBytes,
                                          reserveBytes: Limits.minFreeImportBytes)
        } catch let error as FileImportError {
            return .rejected(error.failure)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .rejected(.cannotOpen)
        }
        if let displayName { copied.displayName = displayName }
        if let existing = await notes.liveNote(withSourceSha256: copied.sha256) { return .existing(existing.id) }
        try Task.checkCancellation()
        let staged: Staged
        do {
            staged = try await classify(staging, in: folder, displayName: copied.displayName, bytes: copied.byteCount)
        } catch let rejection as Rejection {
            return .rejected(rejection.kind)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .rejected(storageFailure(bytes: copied.byteCount))
        }
        let note = ImportedNote.make(id: id, displayName: copied.displayName, fallbackTitle: fallbackTitle,
                                     sha256: copied.sha256, importedAt: clock.now, audio: staged.audio,
                                     document: staged.document)
        try Task.checkCancellation()
        do {
            if let existing = try await notes.insert(note, unlessLiveSourceIs: copied.sha256) { return .existing(existing) }
        } catch {
            return .rejected(storageFailure(bytes: copied.byteCount))
        }
        return .created(id)
    }

    private struct Staged {
        var audio: ImportedAudio
        var document: PortableTranscript?
    }

    /// The file cannot become a note; anything else thrown while classifying is a storage error.
    private struct Rejection: Error {
        var kind: ImportFailureKind
    }

    /// Step 3: decides what the copy is, moves it to its name in the note directory and reads what the note shows.
    /// Ogg Opus is a document only when it names a Cassini format, as Android's `AudioFiles.isCassini`.
    private func classify(_ staging: URL, in folder: URL, displayName: String, bytes: Int64) async throws -> Staged {
        let kind = try await Self.blocking { () throws -> Classified in
            switch try ImportClassifier.sniff(fileAt: staging) {
            case .oggOpus:
                switch try CassiniDocument.namesCassiniFormat(staging) {
                case nil: throw Rejection(kind: .cannotOpen)
                case false: return .plainOpus
                case true: return .document
                }
            case .other(let content): return .other(fileExtension: content)
            }
        }
        switch kind {
        case .plainOpus:
            return try await plainOpus(staging, in: folder, bytes: bytes)
        case .document:
            let document = try await Self.blocking { CassiniDocument.readChecked(staging) }
            // The headers read a moment ago, so this is our own copy failing to read: a storage error.
            if document.state == .unreadable { throw CocoaError(.fileReadUnknown) }
            return try await cassiniDocument(document, staging, in: folder, bytes: bytes)
        case .other(let content):
            let name = "source." + ImportTitles.fileExtension(displayName: displayName, content: content)
            let source = try move(staging, to: name, in: folder)
            let summary: AudioSummary
            do { summary = try await audio.inspect(source) } catch {
                throw audioFailure(error, bytes: bytes) ?? Rejection(kind: .cannotOpen)
            }
            return Staged(audio: ImportedAudio(filename: name, duration: summary.duration, waveform: summary.waveform))
        }
    }

    private enum Classified: Sendable {
        case plainOpus, document
        case other(fileExtension: String?)
    }

    private func plainOpus(_ staging: URL, in folder: URL, bytes: Int64) async throws -> Staged {
        let info = try? await Self.blocking { try OggOpus.scan(staging) }
        guard let info, info.sampleCount > 0 else { throw Rejection(kind: .cannotOpen) }
        let source = try move(staging, to: Self.plainOpusFilename, in: folder)
        guard let waveform = try await decode(source, in: folder, bytes: bytes) else { throw Rejection(kind: .cannotOpen) }
        return Staged(audio: ImportedAudio(filename: Self.playbackFilename, originalFilename: Self.plainOpusFilename,
                                           duration: Double(info.durationMs) / 1000, waveform: waveform))
    }

    /// A document stays one whatever its state; when its audio does not decode, the note keeps it unplayable.
    private func cassiniDocument(_ document: CassiniDocument, _ staging: URL, in folder: URL, bytes: Int64) async throws -> Staged {
        let source = try move(staging, to: Self.documentFilename, in: folder)
        guard let portable = PortableTranscript(document, vendor: PortableTranscript.vendor(of: source)) else {
            throw Rejection(kind: .cannotOpen)
        }
        // A verified document's duration is the one verification measured; any other is scanned for it.
        let duration: TimeInterval
        if document.state == .ok, let verified = portable.duration {
            duration = verified
        } else {
            duration = ((try? await Self.blocking { try OggOpus.scan(source) }).map { Double($0.durationMs) / 1000 }) ?? 0
        }
        let audio: ImportedAudio
        if let waveform = try await decode(source, in: folder, bytes: bytes) {
            audio = ImportedAudio(filename: Self.playbackFilename, originalFilename: Self.documentFilename,
                                  duration: duration, waveform: waveform)
        } else {
            audio = ImportedAudio(filename: Self.documentFilename, duration: duration, state: .unplayable(.unsupportedFormat))
        }
        return Staged(audio: audio, document: portable)
    }

    /// Decodes `opus` to the playback file and returns its waveform; nil when it does not decode.
    private func decode(_ opus: URL, in folder: URL, bytes: Int64) async throws -> [Float]? {
        let playback = folder.appendingPathComponent(Self.playbackFilename)
        do {
            try await audio.decodeOpus(opus, to: playback)
        } catch {
            try? FileManager.default.removeItem(at: playback)
            if let failure = audioFailure(error, bytes: bytes) { throw failure }
            return nil
        }
        return (try? await audio.inspect(playback))?.waveform ?? []
    }

    /// What an error of AVFoundation or libopus means for the import: the cancellation itself, a storage error, or
    /// `noSpace` when the volume ran out (AVFoundation reports a full disk as its own status codes); nil when the audio
    /// just does not read.
    private func audioFailure(_ error: any Error, bytes: Int64) -> (any Error)? {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if Self.isStorageError(error) { return error }
        let space = storageFailure(bytes: bytes)
        if case .noSpace = space { return Rejection(kind: space) }
        return nil
    }

    /// Runs blocking file work (a sniff, a verification or a scan of up to 4 GiB) on its own queue rather than the
    /// cooperative pool, checking for cancellation before and after it.
    static func blocking<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let value = try await BulkTransferIO.run(work)
        try Task.checkCancellation()
        return value
    }

    private func move(_ staging: URL, to name: String, in folder: URL) throws -> URL {
        let target = folder.appendingPathComponent(name)
        try FileManager.default.moveItem(at: staging, to: target)
        return target
    }

    /// `noSpace` when the volume is nearly full, else `cannotSave`.
    private func storageFailure(bytes: Int64) -> ImportFailureKind {
        guard storage.availableBytes(at: notes.root) < Limits.minFreeImportBytes else { return .cannotSave }
        return .noSpace(bytesNeeded: bytes + Limits.minFreeImportBytes)
    }

    /// Deletes what the import of `id` copied, unless its note was written.
    private func discard(_ id: UUID, _ folder: URL) async {
        guard await notes.note(id) == nil else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// An error of the file system rather than of the audio: the import then fails as a save, not as a file that
    /// cannot be opened.
    static func isStorageError(_ error: any Error) -> Bool {
        if error is POSIXError { return true }
        guard let cocoa = error as? CocoaError else { return false }
        return [.fileWriteOutOfSpace, .fileWriteUnknown, .fileWriteNoPermission, .fileWriteVolumeReadOnly,
                .fileReadUnknown, .fileReadNoPermission].contains(cocoa.code)
    }
}

extension FileImportError {
    var failure: ImportFailureKind {
        switch self {
        case .tooLarge: .tooLarge
        case .noSpace(let bytes): .noSpace(bytesNeeded: bytes)
        case .cannotOpen: .cannotOpen
        }
    }
}
