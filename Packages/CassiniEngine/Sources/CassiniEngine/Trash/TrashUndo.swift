import Foundation
import Observation
import CassiniNotebook

/// The hand-over of "moved to Recently Deleted" to the Library, and the Undo snackbar it shows there. Every move lands
/// on the Library: the mover `offer`s the note, and the Library shows the pending note's snackbar once (`showPending`),
/// taking it so it shows only once. Undo restores the note.
@MainActor @Observable public final class TrashUndo {
    public struct Snackbar: Identifiable, Hashable, Sendable {
        /// A new snackbar for the same note restarts the timer.
        public let id: Int
        public let note: TrashedNote
        public let duration: Duration
        /// When it goes: its time runs from when it was shown, also while the Library is covered.
        public let deadline: ContinuousClock.Instant
    }

    /// A note moved to Recently Deleted whose snackbar the Library has not shown yet.
    public private(set) var pending: TrashedNote?
    public private(set) var snackbar: Snackbar?
    /// Puts a note back; `TrashService` sets it.
    @ObservationIgnored var restore: (@MainActor (UUID) -> Bool)?
    @ObservationIgnored private var shown = 0
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant

    public init(now: @escaping @MainActor () -> ContinuousClock.Instant = { .now }) { self.now = now }

    public func offer(_ note: TrashedNote) { pending = note }

    /// Clears `note` when it is still the pending one. False when another took it first.
    @discardableResult public func take(_ note: TrashedNote) -> Bool {
        guard pending == note else { return false }
        pending = nil
        return true
    }

    /// The Library shows the pending note's snackbar for `duration`, once; it replaces any snackbar shown before.
    public func showPending(duration: Duration) {
        guard let note = pending, take(note) else { return }
        shown += 1
        snackbar = Snackbar(id: shown, note: note, duration: duration, deadline: now() + duration)
    }

    /// The note left Recently Deleted another way (Restore, Delete now, Empty, the purge): nothing offers Undo for it
    /// any more.
    public func forget(_ noteID: UUID) {
        if pending?.noteID == noteID { pending = nil }
        if snackbar?.note.noteID == noteID { snackbar = nil }
    }

    /// Undo: the snackbar goes and its note comes back.
    public func undo() {
        guard let snackbar else { return }
        self.snackbar = nil
        _ = restore?(snackbar.note.noteID)
    }

    /// The snackbar `id` stayed its time.
    public func timedOut(_ id: Snackbar.ID) {
        if snackbar?.id == id { snackbar = nil }
    }
}
