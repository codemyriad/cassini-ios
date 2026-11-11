import CassiniCore
import CassiniNotebook
import Foundation

/// One stored ZIP, using the ordinary portable export for transcribed notes and the original bytes for audio-only
/// notes. Every output/intermediate belongs to one export folder and disappears on failure or cancellation.
public struct BulkExportService: Sendable {
    private let notes: NoteStore
    private let portable: PortableExportService
    private let files: ExportService

    public init(notes: NoteStore, portable: PortableExportService, folder: URL) {
        self.notes = notes; self.portable = portable
        files = ExportService(notes: notes, folder: folder)
    }

    public func export(_ ids: [UUID], onProgress: @escaping @Sendable (Int, Int) async -> Void = { _, _ in }) async throws -> URL {
        var seen: Set<UUID> = []
        let ids = ids.filter { seen.insert($0).inserted }
        guard !ids.isEmpty else { throw ExportError.noNote }
        guard ids.count <= ZipArchive.maxEntries else { throw ZipArchiveError.tooLarge }
        var snapshots: [Note] = []
        for id in ids {
            try Task.checkCancellation()
            guard let note = await notes.note(id), note.trashedAt == nil, !note.isRecording else { throw ExportError.noNote }
            snapshots.append(note)
        }
        let work = try files.newFolder()
        do {
            var sources: [ZipSource] = []
            var used: Set<String> = []
            var nextSuffix: [String: Int] = [:]
            var totalBytes: UInt64 = 0
            await onProgress(0, snapshots.count)
            for (index, note) in snapshots.enumerated() {
                try Task.checkCancellation()
                let original = notes.originalAudioURL(for: note)
                let source: URL
                let ext: String
                if !note.transcript.isEmpty {
                    let stage = work.appendingPathComponent(note.id.uuidString, isDirectory: true)
                    source = try await portable.export(note, original: original, playable: notes.audioURL(for: note),
                                                       into: stage, filename: "document")
                    ext = "opus"
                } else {
                    source = original
                    ext = original.pathExtension
                }
                let size = try await BulkTransferIO.run { () -> UInt64 in
                    let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          let size = values.fileSize, size >= 0 else { throw ExportError.cannotSave }
                    return UInt64(size)
                }
                let (sum, overflow) = totalBytes.addingReportingOverflow(size)
                guard !overflow, sum <= ZipArchive.maxUncompressedBytes else { throw ZipArchiveError.tooLarge }
                totalBytes = sum
                let stem = ExportNames.stem(note.title)
                var name = ext.isEmpty ? stem : "\(stem).\(ext)"
                let baseKey = Self.collisionKey(name)
                var suffix = nextSuffix[baseKey] ?? 2
                while !used.insert(Self.collisionKey(name)).inserted {
                    name = ext.isEmpty ? "\(stem) (\(suffix))" : "\(stem) (\(suffix)).\(ext)"
                    suffix += 1
                }
                nextSuffix[baseKey] = suffix
                sources.append(ZipSource(url: source, name: name))
                await onProgress(index + 1, snapshots.count)
            }
            let destination = work.appendingPathComponent("Cassini.zip")
            let inputs = sources
            try await BulkTransferIO.run { try ZipArchive.write(inputs, to: destination) }
            try Task.checkCancellation()
            // Keep only the shareable archive, never expose the staging documents as extra items.
            for note in snapshots {
                try? FileManager.default.removeItem(at: work.appendingPathComponent(note.id.uuidString, isDirectory: true))
            }
            return destination
        } catch {
            files.discardFolder(work)
            throw error
        }
    }

    private static func collisionKey(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }
}
