import Foundation
import CassiniNotebook

/// The queue's view of the notes' `work/` folders: the checkpoints `TranscriptionJob` writes through `CheckpointFiles`,
/// read as numbers for the queue, discarded for Start over and found on disk for the launch repair.
public struct NoteWorkFolders: JobCheckpoints {
    public let files: CheckpointFiles
    private let root: URL
    private let drafts: DraftNamesStore?

    /// The work folders of `notes`' notes; `drafts` forgets a note's draft names once its work is discarded.
    public init(notes: NoteStore, drafts: DraftNamesStore? = nil) {
        files = CheckpointFiles(notes: notes)
        root = notes.root
        self.drafts = drafts
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

    public func language(of noteID: UUID) async -> String? {
        (try? files.load(noteID))??.appleLanguage
    }

    public func recognizer(of noteID: UUID) async -> String? {
        guard let checkpoint = (try? files.load(noteID)) ?? nil else { return nil }
        return SpeechRecognizer.fromCheckpoint(model: checkpoint.model)?.rawValue
    }

    /// A checkpoint file, even one that cannot be read, or a `names.json` that says more than a fresh run's (which
    /// holds only the Forget everyone generation). Without a names store, any `names.json` counts.
    public func holdsDraft(_ noteID: UUID) async -> Bool {
        if files.exists(noteID) { return true }
        let names = files.directory(for: noteID).appendingPathComponent(DraftNamesStore.filename)
        guard FileManager.default.fileExists(atPath: names.path) else { return false }
        guard let drafts else { return true }
        var draft = drafts.current(noteID)
        draft.generation = 0
        return draft != .empty
    }

    public func discard(_ noteID: UUID) async throws {
        try files.discard(noteID)
        drafts?.release(noteID)
    }

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
