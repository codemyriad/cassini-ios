import CryptoKit
import Foundation
import Synchronization

/// Copies a file another app offered (the picker, Files, a share) into the library, as Android's `ImportRepository.copy`.
///
/// The read is coordinated (`NSFileCoordinator`), so a file provider downloads an iCloud placeholder first, and runs
/// under the URL's security scope. The size the provider reports (a placeholder reports its logical size) is checked
/// against the cap and the free space before coordinating, so a file that cannot be imported is never downloaded. It runs on its own queue, not the cooperative pool, because coordination can wait for
/// a download. The copy streams in 64 KiB blocks, hashing as it goes; it enforces the size cap even when the size is
/// unknown, and re-checks the free space every 8 MiB. Cancelling the task stops the copy (and a pending download).
public struct CoordinatedFileImporter: FileImporting {
    public static let bufferBytes = 64 * 1024
    public static let spaceCheckBytes: Int64 = 8 << 20

    private let storage: any StorageProbe
    private let sizeOf: @Sendable (URL) -> Int64?

    /// `sizeOf` gives the size the provider reports, nil when it does not say; tests pass their own.
    public init(storage: any StorageProbe, sizeOf: @escaping @Sendable (URL) -> Int64? = Self.reportedSize) {
        self.storage = storage
        self.sizeOf = sizeOf
    }

    public static func reportedSize(of url: URL) -> Int64? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .totalFileSizeKey])
        return (values?.fileSize ?? values?.totalFileSize).map(Int64.init)
    }

    public func copy(from source: URL, to destination: URL, maxBytes: Int64, reserveBytes: Int64) async throws -> ImportedFile {
        let cancel = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try coordinatedCopy(from: source, to: destination, maxBytes: maxBytes, reserveBytes: reserveBytes, cancel: cancel)
                    })
                }
            }
        } onCancel: {
            cancel.cancel()
        }
    }

    private func coordinatedCopy(from source: URL, to destination: URL, maxBytes: Int64, reserveBytes: Int64,
                                 cancel: Cancellation) throws -> ImportedFile {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let copy = Copy(storage: storage, folder: destination.deletingLastPathComponent(), maxBytes: maxBytes,
                        reserveBytes: reserveBytes, cancel: cancel)
        // Before any download: the cap and the space for the whole file. Once a placeholder has been downloaded, its
        // bytes already take space on this volume, so the check in the accessor covers only a size not reported here.
        let reported = sizeOf(source)
        try copy.check(reported, space: true)
        let coordinator = NSFileCoordinator()
        guard cancel.watch(coordinator) else { throw CancellationError() }
        var coordinationError: NSError?
        var result: Result<ImportedFile, any Error> = .failure(FileImportError.cannotOpen)
        coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
            result = Result {
                let size = sizeOf(readable) ?? reported
                try copy.check(size, space: reported == nil)
                return try copy.run(from: readable, size: size, to: destination, name: source.lastPathComponent)
            }
        }
        if coordinationError != nil { throw cancel.isCancelled ? CancellationError() : FileImportError.cannotOpen }
        return try result.get()
    }
}

/// One streaming copy and its limits.
private struct Copy {
    let storage: any StorageProbe
    let folder: URL
    let maxBytes: Int64
    let reserveBytes: Int64
    let cancel: Cancellation

    /// Rejects a known `size` over the cap and, with `space`, one the free space cannot hold with the reserve.
    func check(_ size: Int64?, space: Bool) throws {
        guard let size else { return }
        if size > maxBytes { throw FileImportError.tooLarge }
        if space, storage.availableBytes(at: folder) < size + reserveBytes {
            throw FileImportError.noSpace(bytesNeeded: size + reserveBytes)
        }
    }

    /// Streams `source` to `destination`; the limits are enforced as it goes.
    func run(from source: URL, size: Int64?, to destination: URL, name: String) throws -> ImportedFile {
        do {
            let (sha256, bytes) = try stream(from: source, size: size, to: destination)
            return ImportedFile(displayName: name, byteCount: bytes, sha256: sha256)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func stream(from source: URL, size: Int64?, to destination: URL) throws -> (String, Int64) {
        let input: FileHandle
        do { input = try FileHandle(forReadingFrom: source) } catch { throw FileImportError.cannotOpen }
        defer { try? input.close() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let output = try? FileHandle(forWritingTo: destination) else { throw lowSpace(size, 0) ?? FileImportError.cannotOpen }
        defer { try? output.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        var nextSpaceCheck = CoordinatedFileImporter.spaceCheckBytes
        while true {
            if cancel.isCancelled { throw CancellationError() }
            let chunk: Data
            do { chunk = try input.read(upToCount: CoordinatedFileImporter.bufferBytes) ?? Data() } catch {
                throw lowSpace(size, total) ?? FileImportError.cannotOpen
            }
            guard !chunk.isEmpty else { break }
            total += Int64(chunk.count)
            if total > maxBytes { throw FileImportError.tooLarge }
            if total >= nextSpaceCheck {
                nextSpaceCheck += CoordinatedFileImporter.spaceCheckBytes
                if let low = lowSpace(size, total) { throw low }
            }
            hasher.update(data: chunk)
            do { try output.write(contentsOf: chunk) } catch { throw lowSpace(size, total) ?? FileImportError.cannotOpen }
        }
        do { try output.synchronize() } catch { throw lowSpace(size, total) ?? FileImportError.cannotOpen }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), total)
    }

    /// `noSpace` when less than the reserve is left. The copied part is deleted, so a retry needs the whole file plus
    /// the reserve, as the check before the copy.
    private func lowSpace(_ size: Int64?, _ copied: Int64) -> FileImportError? {
        guard storage.availableBytes(at: folder) < reserveBytes else { return nil }
        return .noSpace(bytesNeeded: max(size ?? copied, copied) + reserveBytes)
    }
}

/// Whether the task that asked for the copy was cancelled, and the coordinator to stop when it is.
private final class Cancellation: Sendable {
    private struct State {
        var cancelled = false
        nonisolated(unsafe) var coordinator: NSFileCoordinator?
    }

    private let state = Mutex(State())

    var isCancelled: Bool { state.withLock { $0.cancelled } }

    func cancel() {
        let coordinator = state.withLock { state -> NSFileCoordinator? in
            state.cancelled = true
            return state.coordinator
        }
        coordinator?.cancel()
    }

    /// Remembers `coordinator` for `cancel()`; false when the task is already cancelled.
    func watch(_ coordinator: NSFileCoordinator) -> Bool {
        state.withLock { state in
            state.coordinator = coordinator
            return !state.cancelled
        }
    }
}
