import Foundation
import CassiniNotebook

/// The notes the queue does not take for now: a recording whose audio is still being written, and a note on its way
/// to Recently Deleted while its job ends.
///
/// Touches: `finalizing`, `trashing`.
extension TranscriptionCoordinator {
    /// The recorder began writing the note's audio (the compressed copy); until `endFinalizing`, a Transcribe is
    /// refused as `recording`, a hand-off leaves the note audio only, and Remove from queue sets a note the recorder
    /// marked queued back to audio only.
    public func beginFinalizing(_ noteID: UUID) { finalizing.insert(noteID) }
    public func endFinalizing(_ noteID: UUID) { finalizing.remove(noteID) }

    /// Why the queue does not take the note now, before any of its rules: nil when it may.
    func admissionRefusal(_ noteID: UUID) -> EnqueueRefusal? {
        if finalizing.contains(noteID) { return .recording }
        if trashing.contains(noteID) { return .trashed }
        return nil
    }

    /// Remove from queue on a recording whose audio is still being written: it has no job yet, so the status the
    /// recorder showed goes back to audio only.
    func leaveQueuedWhileFinalizing(_ noteID: UUID) async {
        guard finalizing.contains(noteID) else { return }
        _ = try? await parts.notes.mutate(noteID) { if $0.status == .queued { $0.status = .audioOnly } }
    }

    /// Moving to Recently Deleted: a running job stops and keeps its progress and a queued one leaves the queue (its
    /// `work/` stays for Restore), as `moveToTrash`. Once the job has ended, `move` writes the trash with the job the
    /// note keeps for Restore, as Android trashes a note only once its job has finished; until then the note cannot be
    /// queued. When `move` fails the note stays where it was, and so does its job. Returns what `move` returned.
    public func trash(_ noteID: UUID, then move: (TrashedJob?) -> Bool) async -> Bool {
        trashing.insert(noteID)
        defer { trashing.remove(noteID) }
        let job = moveToTrash(noteID)
        await waitForJob(of: noteID)
        guard move(job) else {
            await restore(noteID, trashedJob: job)
            return false
        }
        return true
    }
}
