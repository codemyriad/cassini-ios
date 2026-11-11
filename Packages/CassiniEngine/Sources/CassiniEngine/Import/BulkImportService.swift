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
        for url in urls {
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
                    let archive = try await ArchiveWork.run { try ZIPArchive(url: archiveURL, limits: limits, check: $0.check) }
                    units = max(1, archive.entries.count)
                    total += units - 1
                    guard archive.entries.contains(where: { $0.isFile && !$0.isMetadata && ArchiveAudio.supports($0.name) }) else {
                        report.summary.unsupported += archive.entries.count
                        throw ZIPFailure.empty
                    }
                    let budget = ArchiveWork.Budget(limits.expandedBytes)
                    for entry in archive.entries {
                        try Task.checkCancellation()
                        await progress(.init(done: done + 1, total: total))
                        defer { done += 1 }
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
                        } catch is CancellationError { throw CancellationError() }
                        catch ZIPFailure.tooLarge { throw ZIPFailure.tooLarge }
                        catch { report.summary.failed += 1 }
                    }
                } else {
                    let outcome = try await importFile(url, nil)
                    report.summary.add(outcome)
                    await imported(outcome)
                }
            } catch is CancellationError { report.cancelled = true; break }
            catch let failure as ZIPFailure { report.archives.append(failure); report.summary.failed += 1 }
            catch { report.summary.failed += 1 }
        }
        report.cancelled = report.cancelled || Task.isCancelled
        return report
    }
}
