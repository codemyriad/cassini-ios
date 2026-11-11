import Foundation
import CassiniCore
import CassiniNotebook

/// A complete stored ZIP, published only once its directory is durable. Each private note snapshot is discarded
/// immediately after appending it. On cancellation/failure the entire partial export folder is removed.
public struct BulkExportService: Sendable {
    public typealias Prepare = @Sendable (Note, URL) async throws -> URL
    private let folder: URL
    private let limits: ZIPLimits
    private let prepare: Prepare
    public init(folder: URL, limits: ZIPLimits = .init(), prepare: @escaping Prepare) {
        self.folder = folder; self.limits = limits; self.prepare = prepare
    }
    public func export(_ notes: [Note], progress: @escaping @Sendable (TransferProgress) async -> Void = { _ in }) async throws -> URL {
        guard !notes.isEmpty else { throw ExportError.noNote }
        guard notes.count <= limits.entries else { throw ZIPFailure.tooLarge }
        try Task.checkCancellation()
        let temporary = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let url = temporary.appendingPathComponent("Cassini.zip")
        do {
            let archive = try await ArchiveOutput.create(url, limits: limits)
            var names = ArchiveNames()
            for (index, note) in notes.enumerated() {
                try Task.checkCancellation()
                await progress(.init(done: index + 1, total: notes.count))
                guard !note.isRecording else { throw ExportError.cannotSave }
                let work = temporary.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
                defer { try? FileManager.default.removeItem(at: work) }
                let snapshot = try await prepare(note, work)
                try Task.checkCancellation()
                try await archive.add(snapshot, name: names.next(title: note.title, extension: snapshot.pathExtension))
            }
            try await archive.finish()
            try Task.checkCancellation()
            return url
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    /// An unchanged original; cancellation also works when APFS cannot clone across volumes.
    public static func copyOriginal(_ source: URL, to target: URL) async throws -> URL {
        try await ArchiveWork.run { cancel in
            let input = try FileHandle(forReadingFrom: source)
            defer { try? input.close() }
            guard FileManager.default.createFile(atPath: target.path, contents: nil) else { throw ExportError.cannotSave }
            let output = try FileHandle(forWritingTo: target)
            defer { try? output.close() }
            while true {
                try cancel.check()
                let data = try input.read(upToCount: ZIPArchive.chunkBytes) ?? Data()
                if data.isEmpty { break }
                try output.write(contentsOf: data)
            }
            try output.synchronize()
            return target
        }
    }
}
