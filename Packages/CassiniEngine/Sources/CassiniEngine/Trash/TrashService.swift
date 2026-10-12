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

    /// The confirmation kept with the scene asks again after Cassini was closed, as Android keeps it in
    /// `SavedStateHandle`: while the note is in the library and outside Recently Deleted. False when it does not.
    @discardableResult
    public func askAgain(_ id: UUID) -> Bool {
        guard let note = parts.notes.note(id), note.trashedAt == nil, parts.host.mayTrash(id) else { return false }
        stopConfirmation = TrashedNote(noteID: id, title: note.title)
        return true
    }

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
        parts.undo.forget(id)
        return true
    }

    // MARK: Deleting for good

    /// "Delete now" for one note in Recently Deleted. False for a note that is not there.
    @discardableResult
    public func deleteNow(_ id: UUID) async throws(TrashError) -> Bool {
        try checkVoices()
        var tally = Tally()
        tally.add(try await purge(id) { _ in true }, id)
        return try tally.result() == 1
    }

    /// "Empty": deletes every note that was in Recently Deleted when it started. A note restored meanwhile stays, and
    /// so does one moved there again since (it has a new deletion time). A note that fails stays, and the others are
    /// still deleted (`TrashError.deleteFailed` names every one that stayed). Returns how many went.
    @discardableResult
    public func emptyTrash() async throws(TrashError) -> Int {
        try checkVoices()
        var tally = Tally()
        for (id, deletedAt) in trashed() {
            tally.add(try await purge(id, eligible: { $0 == deletedAt }), id)
        }
        return try tally.result()
    }

    /// Deletes the notes whose 30 days are over. Runs at launch after the queue's repair, when Cassini comes back to
    /// the screen, and when Recently Deleted opens. As with Empty, a note that fails stays for the next run and the
    /// others still go; the purge is recorded either way, as Android's `recordPurge` after `purgeExpired`. Returns how
    /// many went.
    @discardableResult
    public func purgeExpired() async throws(TrashError) -> Int {
        try checkVoices()
        let now = parts.clock.now
        let cutoff = TrashPolicy.purgeCutoff(now: now, calendar: parts.calendar)
        var tally = Tally()
        for (id, deletedAt) in trashed() where deletedAt < cutoff {
            tally.add(try await purge(id, eligible: { $0 < cutoff }), id)
        }
        parts.host.didPurge(at: now)
        return try tally.result()
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

    /// What became of one note asked to be deleted.
    private enum Outcome { case deleted, skipped, failed }

    /// The notes one operation deleted, and those whose delete failed.
    private struct Tally {
        var deleted = 0
        var failed: [UUID] = []

        mutating func add(_ outcome: Outcome, _ id: UUID) {
            switch outcome {
            case .deleted: deleted += 1
            case .skipped: break
            case .failed: failed.append(id)
            }
        }

        func result() throws(TrashError) -> Int {
            guard failed.isEmpty else { throw .deleteFailed(noteIDs: failed) }
            return deleted
        }
    }

    /// Claims the note when it is still in Recently Deleted and `eligible` accepts its deletion time, then deletes it
    /// step by step. Skipped when it was not claimed; failed when a step failed, and the note stays. Saved voices that
    /// cannot be read stop the whole run before the note's job is touched.
    private func purge(_ id: UUID, eligible: (Date) -> Bool) async throws(TrashError) -> Outcome {
        guard let deletedAt = parts.notes.note(id)?.trashedAt, eligible(deletedAt), purging.insert(id).inserted else {
            return .skipped
        }
        defer { purging.remove(id) }
        try checkVoices()
        await parts.queue.cancelAndRemove(id)
        try checkVoices() // They may have gone while the job stopped.
        do {
            try await parts.voices.removeEvidence(noteID: id)
            try await parts.notes.delete(id)
        } catch {
            return .failed
        }
        parts.undo.forget(id)
        return .deleted
    }
}
