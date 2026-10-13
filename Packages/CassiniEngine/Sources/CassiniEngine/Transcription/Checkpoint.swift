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

/// A checkpoint could not be written because the volume is (nearly) full: the job fails with `SPACE`, not `SAVE`.
public struct CheckpointSpaceError: Error, Hashable, Sendable {
    public init() {}
}

/// `<note folder>/work/checkpoint.json`, with the previous checkpoint kept as `checkpoint.json.bak`. A save writes a
/// temporary file, flushes it to disk, moves the current checkpoint to the backup and renames the new one into place;
/// a load falls back to the backup when the current file is missing or damaged. The note folder is `NoteStore`'s, so the
/// work goes with the note.
public struct CheckpointFiles: CheckpointStoring {
    public static let directoryName = "work"
    public static let filename = "checkpoint.json"
    public static let backupFilename = "checkpoint.json.bak"
    /// A failed write with less free space than this is a full volume (Android's `Limits.MIN_FREE_BYTES`).
    public static let minFreeBytes: Int64 = 64 << 20

    private let noteDirectory: @Sendable (UUID) -> URL
    private let availableBytes: @Sendable (URL) -> Int64

    /// `noteDirectory` gives a note's folder; `availableBytes` the free space of the volume a folder is on.
    public init(noteDirectory: @escaping @Sendable (UUID) -> URL,
                availableBytes: @escaping @Sendable (URL) -> Int64 = CheckpointFiles.availableBytes) {
        self.noteDirectory = noteDirectory
        self.availableBytes = availableBytes
    }

    /// The work folders of `notes`' notes.
    public init(notes: NoteStore) {
        self.init(noteDirectory: { notes.directory(for: $0) })
    }

    public func directory(for noteID: UUID) -> URL {
        noteDirectory(noteID).appendingPathComponent(Self.directoryName, isDirectory: true)
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

    /// Throws `CheckpointSpaceError` when the write failed on a full volume. Creates only the `work/` folder: once the
    /// note's folder is gone (the note was deleted for good while its job was stopping), the save fails instead of
    /// leaving a folder with no note in it.
    public func save(_ state: CheckpointState, for noteID: UUID) throws {
        let folder = directory(for: noteID)
        do {
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            let main = folder.appendingPathComponent(Self.filename)
            let backup = folder.appendingPathComponent(Self.backupFilename)
            let temporary = folder.appendingPathComponent(Self.filename + ".tmp")
            try DurableFile.writeSynced(state.encoded(), to: temporary)
            if FileManager.default.fileExists(atPath: main.path) { try DurableFile.rename(main, to: backup) }
            try DurableFile.rename(temporary, to: main)
            DurableFile.syncDirectory(folder)
        } catch {
            if Self.isOutOfSpace(error) || availableBytes(noteDirectory(noteID)) < Self.minFreeBytes {
                throw CheckpointSpaceError()
            }
            throw error
        }
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

    /// Free bytes for important use on the volume of `url`, or of its nearest existing parent; `Int64.max` when unknown.
    @Sendable public static func availableBytes(_ url: URL) -> Int64 {
        var candidate = url
        while !FileManager.default.fileExists(atPath: candidate.path), candidate.pathComponents.count > 1 {
            candidate.deleteLastPathComponent()
        }
        let values = try? candidate.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                             .volumeAvailableCapacityKey])
        // Some volumes (a Mac's temporary folder, say) report 0 for important use; the plain figure is then the answer.
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init) ?? .max
    }

    static func isOutOfSpace(_ error: any Error) -> Bool {
        if let cocoa = error as? CocoaError, cocoa.code == .fileWriteOutOfSpace { return true }
        if let posix = error as? POSIXError, posix.code == .ENOSPC || posix.code == .EDQUOT { return true }
        let underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? any Error
        return underlying.map(isOutOfSpace) ?? false
    }
}
