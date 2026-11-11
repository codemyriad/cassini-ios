import Foundation
import CassiniCore
import CassiniNotebook

/// Every member uses the ordinary importer, including its digest deduplication and single-file size/storage rules.
/// A ZIP's entire directory is validated before any of its members can become notes. Only a UUID-named scratch file
/// is written; archive paths are never handed to the filesystem. Completed imports survive cancellation.
public struct BulkImportService: Sendable {
    public typealias ImportFile = @Sendable (URL, String?) async throws -> ImportOutcome
    private let files: any FileImporting
    private let scratch: URL
    private let limits: ZIPLimits
    private let memberLimit: UInt64
    private let importFile: ImportFile

    public init(files: any FileImporting, scratch: URL, limits: ZIPLimits = .init(),
                memberLimit: UInt64 = UInt64(Limits.maxImportBytes), importFile: @escaping ImportFile) {
        self.files = files; self.scratch = scratch; self.limits = limits; self.importFile = importFile
        self.memberLimit = min(memberLimit, UInt64(Limits.maxImportBytes))
    }

    public func run(_ urls: [URL], progress: @escaping @Sendable (TransferProgress) async -> Void = { _ in },
                    imported: @escaping @Sendable (ImportOutcome) async -> Void = { _ in }) async -> BulkImportReport {
        var report = BulkImportReport()
        var done = 0, total = urls.count
        filesLoop: for url in urls {
            let before = done
            var units = 1
            defer { done = before + units }
            do {
                try Task.checkCancellation()
                await progress(.init(done: done + 1, total: total))
                if url.pathExtension.lowercased() == "zip" {
                    let folder = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    defer { try? FileManager.default.removeItem(at: folder) }
                    let archiveURL = folder.appendingPathComponent("archive.zip")
                    // The 4 GiB note cap applies to members, not the container. The existing coordinated copier
                    // retains file-provider/security-scoped access and checks disk space while streaming.
                    _ = try await files.copy(from: url, to: archiveURL,
                                             maxBytes: Int64.max - Limits.minFreeImportBytes,
                                             reserveBytes: Limits.minFreeImportBytes)
                    let limits = limits
                    let archive = try await ArchiveWork.run { cancel in
                        let archive = try ZIPArchive(url: archiveURL, limits: limits, check: cancel.check)
                        let budget = ArchiveWork.Budget(limits.expandedBytes)
                        // Refuse archive-wide runtime violations before creating even the first note. Ignored
                        // members are subject to the same limits; validation uses no member-sized disk staging.
                        for entry in archive.entries {
                            try cancel.check()
                            if entry.method == 0 {
                                try budget.account(entry.compressedBytes)
                            } else if entry.method == 8 {
                                do {
                                    try archive.read(entry, remainingBytes: budget.remaining, check: cancel.check,
                                                     observed: budget.observed) { _ in }
                                } catch ZIPFailure.entry {
                                    // A directory's stream must prove it is empty; unreadable bytes cannot be
                                    // silently ignored. Corrupt ordinary files may still have good siblings.
                                    if entry.isDirectory { throw ZIPFailure.damaged }
                                }
                            }
                        }
                        return archive
                    }
                    units = max(1, archive.entries.count)
                    total += units - 1
                    guard archive.entries.contains(where: { $0.isFile && !$0.isMetadata && ArchiveAudio.supports($0.name) }) else {
                        report.summary.unsupported += archive.entries.filter { !$0.isDirectory }.count
                        throw ZIPFailure.empty
                    }
                    let budget = ArchiveWork.Budget(limits.expandedBytes)
                    for entry in archive.entries {
                        try Task.checkCancellation()
                        await progress(.init(done: done + 1, total: total))
                        defer { done += 1 }
                        if entry.isDirectory { continue }
                        guard entry.isFile && !entry.isMetadata && ArchiveAudio.supports(entry.name) else { report.summary.unsupported += 1; continue }
                        guard entry.expandedBytes <= memberLimit else { report.summary.failed += 1; continue }
                        let staged = folder.appendingPathComponent(UUID().uuidString + ".tmp")
                        defer { try? FileManager.default.removeItem(at: staged) }
                        do {
                            let remaining = budget.remaining
                            _ = try await ArchiveWork.run { cancel in
                                guard FileManager.default.createFile(atPath: staged.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
                                let file = try FileHandle(forWritingTo: staged)
                                defer { try? file.close() }
                                let n = try archive.read(entry, remainingBytes: remaining, check: cancel.check, observed: budget.observed) {
                                    try file.write(contentsOf: $0)
                                }
                                try file.synchronize()
                                return n
                            }
                            let outcome = try await importFile(staged, entry.name)
                            report.summary.add(outcome)
                            await imported(outcome)
                            if case .rejected(.noSpace(let needed)) = outcome {
                                report.storageFailure = .noSpace(bytesNeeded: needed); break filesLoop
                            }
                        } catch is CancellationError { throw CancellationError() }
                        catch ZIPFailure.tooLarge { throw ZIPFailure.tooLarge }
                        catch {
                            report.summary.failed += 1
                            if let failure = Self.storageFailure(error, bytes: Int64(entry.expandedBytes)) {
                                report.storageFailure = failure; break filesLoop
                            }
                        }
                    }
                } else {
                    let outcome = try await importFile(url, nil)
                    report.summary.add(outcome)
                    await imported(outcome)
                    if case .rejected(.noSpace(let needed)) = outcome {
                        report.storageFailure = .noSpace(bytesNeeded: needed); break filesLoop
                    }
                }
            } catch is CancellationError { report.cancelled = true; break }
            catch let failure as ZIPFailure { if !report.archives.contains(failure) { report.archives.append(failure) } }
            catch {
                report.summary.failed += 1
                if let failure = Self.storageFailure(error, bytes: 0) { report.storageFailure = failure; break }
            }
        }
        report.cancelled = report.cancelled || Task.isCancelled
        return report
    }
    private static func storageFailure(_ error: any Error, bytes: Int64) -> ImportFailureKind? {
        if case .noSpace(let needed) = error as? FileImportError { return .noSpace(bytesNeeded: needed) }
        if (error as? CocoaError)?.code == .fileWriteOutOfSpace || (error as? POSIXError)?.code == .ENOSPC {
            return .noSpace(bytesNeeded: bytes + Limits.minFreeImportBytes)
        }
        return nil
    }

}
