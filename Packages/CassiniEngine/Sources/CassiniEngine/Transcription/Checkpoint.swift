import Foundation
import CassiniNotebook

/// Where a job keeps its checkpoint between runs.
public protocol CheckpointStoring: Sendable {
    /// The note's checkpoint, nil when it has none. Throws when one is there but cannot be read.
    func load(_ noteID: UUID) throws -> CheckpointState?
    /// Writes the checkpoint so that a crash at any point leaves this one or the previous one readable.
    func save(_ state: CheckpointState, for noteID: UUID) throws
    /// Removes the note's job work (`work/`); nothing when there is none.
    func discard(_ noteID: UUID) throws
    func exists(_ noteID: UUID) -> Bool
}

/// `<root>/<note id>/work/checkpoint.json`, with the previous checkpoint kept as `checkpoint.json.bak`. A save writes a
/// temporary file, flushes it to disk, moves the current checkpoint to the backup and renames the new one into place;
/// a load falls back to the backup when the current file is missing or damaged.
public struct CheckpointFiles: CheckpointStoring {
    public static let directoryName = "work"
    public static let filename = "checkpoint.json"
    public static let backupFilename = "checkpoint.json.bak"

    public let root: URL

    public init(root: URL) { self.root = root }

    public func directory(for noteID: UUID) -> URL {
        root.appendingPathComponent(noteID.uuidString, isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public func load(_ noteID: UUID) throws -> CheckpointState? {
        let folder = directory(for: noteID)
        let main = folder.appendingPathComponent(Self.filename)
        let backup = folder.appendingPathComponent(Self.backupFilename)
        var firstError: (any Error)?
        for url in [main, backup] where FileManager.default.fileExists(atPath: url.path) {
            do { return try CheckpointState.decode(Data(contentsOf: url)) } catch { firstError = firstError ?? error }
        }
        if let firstError { throw firstError }
        return nil
    }

    public func save(_ state: CheckpointState, for noteID: UUID) throws {
        let folder = directory(for: noteID)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let main = folder.appendingPathComponent(Self.filename)
        let backup = folder.appendingPathComponent(Self.backupFilename)
        let temporary = folder.appendingPathComponent(Self.filename + ".tmp")
        try Self.writeSynced(state.encoded(), to: temporary)
        if FileManager.default.fileExists(atPath: main.path) { try Self.rename(main, to: backup) }
        try Self.rename(temporary, to: main)
        Self.syncDirectory(folder)
    }

    public func discard(_ noteID: UUID) throws {
        let folder = directory(for: noteID)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.removeItem(at: folder)
    }

    public func exists(_ noteID: UUID) -> Bool {
        let folder = directory(for: noteID)
        return [Self.filename, Self.backupFilename].contains {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    /// Writes `data` and flushes it to the disk before returning.
    private static func writeSynced(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }

    /// `rename(2)`: replaces `destination` atomically.
    private static func rename(_ source: URL, to destination: URL) throws {
        guard Darwin.rename(source.path, destination.path) == 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)])
        }
    }

    /// Flushes the renames; best effort.
    private static func syncDirectory(_ folder: URL) {
        let descriptor = open(folder.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        fsync(descriptor)
        close(descriptor)
    }
}
