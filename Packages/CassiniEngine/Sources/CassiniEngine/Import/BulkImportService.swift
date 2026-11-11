import CassiniCore
import CassiniNotebook
import Foundation

public struct BulkImportSummary: Sendable, Equatable {
    public var imported = 0
    public var duplicates = 0
    public var unsupported = 0
    public var failed = 0
    public var outcomes: [ImportOutcome] = []
    public var archiveFailures: [ZipArchiveError] = []
    public init() {}

    mutating func record(_ outcome: ImportOutcome) {
        outcomes.append(outcome)
        switch outcome {
        case .created: imported += 1
        case .existing: duplicates += 1
        case .rejected: failed += 1
        }
    }
}

public enum BulkImportEvent: Sendable {
    case progress(completed: Int, total: Int)
    case outcome(ImportOutcome)
    case unsupported(Int)
    case archiveFailure(ZipArchiveError)
}

/// A selection is processed sequentially. ZIP directories and all staged entry bodies are checked before
/// any of that archive's notes are inserted. A refused archive cannot leave partially imported notes.
public struct BulkImportService: Sendable {
    private let importer: ImportService
    private let files: any FileImporting
    private let storage: any StorageProbe
    private let maxEntryBytes: Int64
    public let folder: URL

    public init(importer: ImportService, files: any FileImporting, storage: any StorageProbe, folder: URL) {
        self.importer = importer; self.files = files; self.storage = storage; self.folder = folder
        maxEntryBytes = Limits.maxImportBytes
    }

    /// Tests can tighten the same production path without allocating a multi-gigabyte fixture.
    init(importer: ImportService, files: any FileImporting, storage: any StorageProbe, folder: URL, maxEntryBytes: Int64) {
        self.importer = importer; self.files = files; self.storage = storage; self.folder = folder
        self.maxEntryBytes = max(0, min(maxEntryBytes, Limits.maxImportBytes))
    }

    public func importFiles(_ urls: [URL], fallbackTitle: String,
                            onEvent: @escaping @Sendable (BulkImportEvent) async -> Void = { _ in }) async throws -> BulkImportSummary {
        var summary = BulkImportSummary()
        // The empty parent survives between batches. Removing it races another batch creating its UUID child.
        var completed = 0, total = urls.count
        await onEvent(.progress(completed: completed, total: total))
        for url in urls {
            try Task.checkCancellation()
            guard url.pathExtension.lowercased() == "zip" else {
                let outcome = try await importer.importFile(url, fallbackTitle: fallbackTitle)
                summary.record(outcome)
                await onEvent(.outcome(outcome))
                completed += 1
                await onEvent(.progress(completed: completed, total: total))
                continue
            }
            let work = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
            let before = completed
            var archiveUnits = 1
            do {
                try await BulkTransferIO.run { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }
                defer { try? FileManager.default.removeItem(at: work) }
                let archiveURL = work.appendingPathComponent("archive.zip")
                // The archive itself is not a single audio entry: stored archives can exceed 4 GiB.
                // FileImporting still enforces the device's free-space reserve as it streams/co-ordinates access.
                _ = try await files.copy(from: url, to: archiveURL, maxBytes: Int64.max, reserveBytes: Limits.minFreeImportBytes)
                let archive = try await BulkTransferIO.run { try ZipArchive(url: archiveURL) }
                let entries = archive.entries.filter { !$0.isDirectory }
                guard !entries.isEmpty else { throw ZipArchiveError.empty }
                archiveUnits = entries.count
                total += archiveUnits - 1
                await onEvent(.progress(completed: completed, total: total))
                var staged: [(url: URL, displayName: String)] = []
                var oversized = false
                for entry in entries {
                    try Task.checkCancellation()
                    if Self.nestedArchiveExtensions.contains((entry.baseName as NSString).pathExtension.lowercased()) {
                        summary.unsupported += 1
                        await onEvent(.unsupported(1))
                        completed += 1
                        await onEvent(.progress(completed: completed, total: total))
                        continue
                    }
                    guard entry.uncompressedSize <= maxEntryBytes else {
                        oversized = true
                        let outcome = ImportOutcome.rejected(.tooLarge)
                        summary.record(outcome)
                        await onEvent(.outcome(outcome))
                        completed += 1
                        await onEvent(.progress(completed: completed, total: total))
                        continue
                    }
                    // ZIP names can exceed NAME_MAX. Only a generated name touches the filesystem; the original
                    // base name is carried separately into normal import title/container classification.
                    let directory = work.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    let destination = directory.appendingPathComponent("entry")
                    let storage = storage
                    let maxEntryBytes = maxEntryBytes
                    let recognizable = try await BulkTransferIO.run {
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        _ = try archive.extract(entry, to: destination, maxBytes: maxEntryBytes) { bytes in
                            guard storage.availableBytes(at: work) >= Limits.minFreeImportBytes + Int64(bytes) else {
                                throw FileImportError.noSpace(bytesNeeded: Limits.minFreeImportBytes + Int64(bytes))
                            }
                        }
                        return try Self.supportedAudio(destination, displayName: entry.baseName)
                    }
                    let supported: Bool
                    if recognizable { supported = true }
                    else { supported = try await importer.canInspectAudio(destination) }
                    if supported { staged.append((destination, entry.baseName)) }
                    else {
                        try? FileManager.default.removeItem(at: destination)
                        summary.unsupported += 1
                        await onEvent(.unsupported(1))
                        completed += 1
                        await onEvent(.progress(completed: completed, total: total))
                    }
                }
                guard !staged.isEmpty else {
                    // Oversized audio entries are already represented by their precise per-file failure.
                    if oversized { continue }
                    throw ZipArchiveError.empty
                }
                for source in staged {
                    try Task.checkCancellation()
                    let outcome = try await importer.importFile(source.url, fallbackTitle: fallbackTitle, displayName: source.displayName)
                    summary.record(outcome)
                    await onEvent(.outcome(outcome))
                    completed += 1
                    await onEvent(.progress(completed: completed, total: total))
                }
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: work)
                throw CancellationError()
            } catch let failure as FileImportError {
                try? FileManager.default.removeItem(at: work)
                let outcome = ImportOutcome.rejected(failure.failure)
                summary.record(outcome)
                await onEvent(.outcome(outcome))
                completed = before + archiveUnits
                await onEvent(.progress(completed: completed, total: total))
            } catch {
                try? FileManager.default.removeItem(at: work)
                if let failure = Self.storageFailure(error) {
                    let outcome = ImportOutcome.rejected(failure)
                    summary.record(outcome)
                    await onEvent(.outcome(outcome))
                    completed = before + archiveUnits
                    await onEvent(.progress(completed: completed, total: total))
                    continue
                }
                let reason = (error as? ZipArchiveError) ?? .damaged
                summary.failed += 1; summary.archiveFailures.append(reason)
                await onEvent(.archiveFailure(reason))
                completed = before + archiveUnits
                await onEvent(.progress(completed: completed, total: total))
            }
        }
        return summary
    }

    /// Called behind the launch-ready fence, before incoming files can start an import.
    public func sweep() async {
        let folder = folder
        _ = try? await BulkTransferIO.run { try? FileManager.default.removeItem(at: folder) }
    }

    private static let nestedArchiveExtensions: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar"]
    private static let audioExtensions: Set<String> = ["opus", "ogg", "oga", "wav", "wave", "mp3", "m4a", "aac", "flac",
        "aif", "aiff", "aifc", "caf", "amr", "awb", "3gp", "3g2", "mp4", "au", "snd", "ac3", "mp2"]

    private static func storageFailure(_ error: any Error) -> ImportFailureKind? {
        let error = error as NSError
        if (error.domain == NSCocoaErrorDomain && error.code == CocoaError.fileWriteOutOfSpace.rawValue)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOSPC)) {
            return .noSpace(bytesNeeded: Limits.minFreeImportBytes)
        }
        if error.domain == NSCocoaErrorDomain,
           [CocoaError.fileWriteUnknown.rawValue, CocoaError.fileWriteNoPermission.rawValue,
            CocoaError.fileWriteFileExists.rawValue, CocoaError.fileWriteVolumeReadOnly.rawValue].contains(error.code) {
            return .cannotSave
        }
        return nil
    }

    private static func supportedAudio(_ url: URL, displayName: String) throws -> Bool {
        if audioExtensions.contains((displayName as NSString).pathExtension.lowercased()) { return true }
        switch try ImportClassifier.sniff(fileAt: url) {
        case .oggOpus, .other(fileExtension: .some): return true
        case .other(fileExtension: .none): return false
        }
    }
}

/// Blocking archive/metadata work never inherits the UI actor; cancellation reaches the worker's chunk checks.
enum BulkTransferIO {
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let task = Task.detached(priority: .userInitiated, operation: work)
        return try await withTaskCancellationHandler {
            do {
                let value = try await task.value
                try Task.checkCancellation()
                return value
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: { task.cancel() }
    }
}
