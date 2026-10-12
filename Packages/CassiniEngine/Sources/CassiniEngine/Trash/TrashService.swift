import Foundation
import Observation
import CassiniNotebook

/// Recently Deleted: moving notes there and back, and deleting them for good (Android's trash in `NoteRepository`
/// with the Library's and the Trash screen's view models).
///
/// A note deleted for good goes in this order: its job (a running one is stopped and awaited), its voiceprints, its
/// directory with its `note.json`, then the note in memory. A delete cut short leaves a note still in Recently Deleted
/// that the next purge finishes; a note whose `note.json` is gone cannot come back (`NoteRepository.delete`).
///
/// The notes to delete are listed before any of them goes, and Restore can run in between. So each note is claimed on
/// its own first: it must still be in Recently Deleted with a deletion time the operation accepts. Restore refuses a
/// claimed note. The claim ends with its delete, so a delete that failed leaves a note that Restore can bring back.
@MainActor @Observable public final class TrashService {
    public struct Parts {
        public var notes: any TrashNotes
        public var queue: any TrashQueue
        public var voices: any VoiceEvidence
        public var host: any TrashHost
        public var undo: TrashUndo
        public var clock: any AppClock
        public var calendar: Calendar

        public init(notes: any TrashNotes, queue: any TrashQueue, voices: any VoiceEvidence, host: any TrashHost,
                    undo: TrashUndo, clock: any AppClock, calendar: Calendar) {
            self.notes = notes; self.queue = queue; self.voices = voices; self.host = host; self.undo = undo
            self.clock = clock; self.calendar = calendar
        }
    }

    /// A running note waiting for "Stop transcription and move to Recently Deleted?".
    public private(set) var stopConfirmation: TrashedNote?
    /// The last purge found the saved voices unreadable and deleted nothing. Shown as one lasting notice, never as an
    /// alert each time the purge runs.
    public private(set) var voicesUnavailable = false
    @ObservationIgnored private let parts: Parts
    /// Notes being deleted for good.
    @ObservationIgnored private var purging: Set<UUID> = []

    public init(_ parts: Parts) {
        self.parts = parts
        parts.undo.restore = { [weak self] in self?.restore($0) ?? false }
    }

    public var undo: TrashUndo { parts.undo }

    /// The cards of Recently Deleted, oldest deletion first.
    public var items: [TrashItem] { TrashLabels.items(parts.notes.notes, now: parts.clock.now, calendar: parts.calendar) }

    /// Adds what Recently Deleted knows to the facts the banners are built from.
    public func contribute(to facts: inout NoticeFacts) {
        if voicesUnavailable { facts.voicesUnavailable = true }
    }

    // MARK: Moving

    /// Move to Recently Deleted from a row, a menu or a note: a note whose transcription runs asks first
    /// (`stopConfirmation`); any other moves at once. True when it moved.
    @discardableResult
    public func requestTrash(_ id: UUID) async -> Bool {
        guard let note = parts.notes.note(id), note.trashedAt == nil else { return false }
        if parts.queue.isRunning(id) {
            stopConfirmation = TrashedNote(noteID: id, title: note.title)
            return false
        }
        return await moveToTrash(id)
    }

    /// "Move to Recently Deleted" in the confirmation for `note`: the transcription stops and keeps its progress,
    /// then the note moves. The confirmation may already be closed.
    @discardableResult
    public func confirmStop(_ note: TrashedNote) async -> Bool {
        if stopConfirmation == note { stopConfirmation = nil }
        return await moveToTrash(note.noteID)
    }

    public func cancelStop() { stopConfirmation = nil }

    /// Moves the note now, stopping its job and keeping its progress, and offers Undo on the Library. The note
    /// remembers its job for Restore. False while it is being recorded, or when it is not in the library.
    @discardableResult
    public func moveToTrash(_ id: UUID) async -> Bool {
        let host = parts.host, notes = parts.notes, clock = parts.clock
        guard let note = notes.note(id), note.trashedAt == nil, host.mayTrash(id) else { return false }
        host.willTrash(id)
        let moved = await parts.queue.trash(id) { job in
            guard host.mayTrash(id), notes.note(id)?.trashedAt == nil else { return false }
            let now = clock.now
            return notes.update(id) { $0.trashedAt = now; $0.trashedJob = job }
        }
        guard moved else { return false }
        if stopConfirmation?.noteID == id { stopConfirmation = nil }
        parts.undo.offer(TrashedNote(noteID: id, title: notes.note(id)?.title ?? note.title))
        host.didTrash(id)
        return true
    }

    /// Restore and Undo. A note whose job was queued when it moved goes back to the queue, at the back; a paused one
    /// stays paused. False when the note is not in Recently Deleted, or while it is being deleted for good.
    @discardableResult
    public func restore(_ id: UUID) -> Bool {
        guard !purging.contains(id), let note = parts.notes.note(id), note.trashedAt != nil else { return false }
        let job = note.trashedJob
        guard parts.notes.update(id, { $0.trashedAt = nil; $0.trashedJob = nil }) else { return false }
        parts.queue.restore(id, trashedJob: job)
        return true
    }

    // MARK: Deleting for good

    /// "Delete now" for one note in Recently Deleted. False for a note that is not there.
    @discardableResult
    public func deleteNow(_ id: UUID) async throws(TrashError) -> Bool {
        try checkVoices()
        return try await purge(id) { _ in true }
    }

    /// "Empty": deletes every note that was in Recently Deleted when it started. A note restored meanwhile stays, and
    /// so does one moved there again since (it has a new deletion time). Returns how many went.
    @discardableResult
    public func emptyTrash() async throws(TrashError) -> Int {
        try checkVoices()
        var deleted = 0
        for (id, deletedAt) in trashed() {
            if try await purge(id, eligible: { $0 == deletedAt }) { deleted += 1 }
        }
        return deleted
    }

    /// Deletes the notes whose 30 days are over. Runs at launch after the queue's repair, when Cassini comes back to
    /// the screen, and when Recently Deleted opens. Returns how many went.
    @discardableResult
    public func purgeExpired() async throws(TrashError) -> Int {
        try checkVoices()
        let now = parts.clock.now
        let cutoff = TrashPolicy.purgeCutoff(now: now, calendar: parts.calendar)
        var deleted = 0
        for (id, deletedAt) in trashed() where deletedAt < cutoff {
            if try await purge(id, eligible: { $0 < cutoff }) { deleted += 1 }
        }
        parts.host.didPurge(at: now)
        return deleted
    }

    /// The notes in Recently Deleted with their deletion time, oldest first.
    private func trashed() -> [(UUID, Date)] {
        parts.notes.notes.compactMap { note in note.trashedAt.map { (note.id, $0) } }
            .sorted { ($0.1, $0.0.uuidString) < ($1.1, $1.0.uuidString) }
    }

    private func checkVoices() throws(TrashError) {
        voicesUnavailable = !parts.voices.isReadable
        if voicesUnavailable { throw .voicesUnavailable }
    }

    /// Claims the note when it is still in Recently Deleted and `eligible` accepts its deletion time, then deletes it
    /// step by step. False when it was not claimed.
    private func purge(_ id: UUID, eligible: (Date) -> Bool) async throws(TrashError) -> Bool {
        guard let deletedAt = parts.notes.note(id)?.trashedAt, eligible(deletedAt), purging.insert(id).inserted else {
            return false
        }
        defer { purging.remove(id) }
        await parts.queue.cancelAndRemove(id)
        guard parts.voices.isReadable else {
            voicesUnavailable = true
            throw TrashError.voicesUnavailable
        }
        do {
            try await parts.voices.removeEvidence(noteID: id)
            try await parts.notes.delete(id)
        } catch {
            throw TrashError.deleteFailed(noteID: id)
        }
        return true
    }
}
