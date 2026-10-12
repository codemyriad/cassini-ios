import Foundation
import CassiniNotebook

/// The queue's view of the notes' `work/` folders: the checkpoints `TranscriptionJob` writes through `CheckpointFiles`,
/// read as numbers for the queue, discarded for Start over and found on disk for the launch repair.
public struct NoteWorkFolders: JobCheckpoints {
    public let files: CheckpointFiles
    private let root: URL

    /// The work folders of `notes`' notes.
    public init(notes: NoteStore) {
        files = CheckpointFiles(notes: notes)
        root = notes.root
    }

    /// The numbers of the note's checkpoint. One that cannot be read, or that no longer fits the note's audio file
    /// (its name or `length:mtime`), is a mismatch; the job checks the language when it runs.
    public func status(of noteID: UUID) async -> CheckpointStatus {
        let checkpoint: CheckpointState?
        do { checkpoint = try files.load(noteID) } catch { return .mismatch }
        guard let checkpoint else { return .missing }
        let audio = root.appendingPathComponent(noteID.uuidString, isDirectory: true)
            .appendingPathComponent(checkpoint.source)
        guard CheckpointState.signature(of: audio) == checkpoint.signature else { return .mismatch }
        return .saved(doneMs: checkpoint.doneMs, totalMs: checkpoint.totalMs, words: checkpoint.draftWords.count)
    }

    public func discard(_ noteID: UUID) async throws { try files.discard(noteID) }

    /// Every note folder under the root with a `work/` folder, whether or not its note can be read.
    public func notesWithWork() async -> Set<UUID> {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return Set(folders.compactMap(UUID.init(uuidString:)).filter { id in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: files.directory(for: id).path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        })
    }
}
