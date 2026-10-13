import Foundation

/// The durable write steps every metadata file goes through (Android's `NoteFiles`): the bytes go to `<name>.tmp`
/// beside the target, are flushed to the storage device with `F_FULLFSYNC`, are renamed over the target in one step,
/// and the directory is flushed so the rename survives a power cut. A crash at any point leaves the previous file or
/// the new one, never a torn one; a leftover `.tmp` is removed by the launch sweep.
public enum DurableFile {
    public static let temporarySuffix = ".tmp"

    /// Replaces the file at `url` with `data`, durably. The directory must exist.
    public static func write(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + temporarySuffix)
        do {
            try writeSynced(data, to: temporary)
            try rename(temporary, to: url)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
        syncDirectory(url.deletingLastPathComponent())
    }

    /// Writes `data` to a new file at `url` (replacing one that is there) and flushes it to the storage device.
    public static func writeSynced(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError()
                }
                offset += written
            }
        }
        try flush(descriptor)
    }

    /// `rename(2)`: replaces `destination` with `source` in one step.
    public static func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else { throw posixError() }
    }

    /// Flushes the entries of `folder`, so a rename inside it is on the disk. Best effort: the rename itself is atomic.
    public static func syncDirectory(_ folder: URL) {
        let descriptor = open(folder.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        _ = try? flush(descriptor)
    }

    /// `F_FULLFSYNC` asks the drive to write its cache out too; a file system that does not support it gets `fsync`.
    private static func flush(_ descriptor: Int32) throws {
        if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
        guard fsync(descriptor) == 0 else { throw posixError() }
    }

    /// The current `errno` as the error Foundation's own writes throw, so out-of-space checks recognise it.
    private static func posixError() -> CocoaError {
        let code = POSIXErrorCode(rawValue: errno) ?? .EIO
        let cocoaCode: CocoaError.Code = code == .ENOSPC || code == .EDQUOT ? .fileWriteOutOfSpace : .fileWriteUnknown
        return CocoaError(cocoaCode, userInfo: [NSUnderlyingErrorKey: POSIXError(code)])
    }
}
