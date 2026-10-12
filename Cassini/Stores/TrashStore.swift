import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// Recently Deleted: moving notes there and back, and deleting them for good.
@MainActor @Observable final class TrashStore {
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let voices: VoicesStore
    @ObservationIgnored private let processing: ProcessingStore
    @ObservationIgnored private let playback: PlaybackStore
    @ObservationIgnored private let recording: RecordingStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let router: Router
    @ObservationIgnored private let errors: ErrorPresenter
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored private let calendar: Calendar

    init(library: LibraryStore, voices: VoicesStore, processing: ProcessingStore, playback: PlaybackStore,
         recording: RecordingStore, settings: SettingsStore, router: Router, errors: ErrorPresenter, clock: any AppClock,
         calendar: Calendar) {
        self.library = library; self.voices = voices; self.processing = processing; self.playback = playback
        self.recording = recording; self.settings = settings; self.router = router; self.errors = errors; self.clock = clock; self.calendar = calendar
    }

    /// Oldest deletion first.
    var notes: [Note] {
        library.notes.filter { $0.trashedAt != nil }.sorted { ($0.trashedAt!, $0.id.uuidString) < ($1.trashedAt!, $1.id.uuidString) }
    }

    func daysLeft(_ note: Note) -> Int {
        note.trashedAt.map { TrashPolicy.daysLeft(since: $0, now: clock.now, calendar: calendar) } ?? TrashPolicy.retentionDays
    }

    /// Closes the note wherever it is open. A queued or running transcription stops and keeps its progress, so a
    /// restored note resumes; the note moves once its job has ended, and remembers its job for Restore. False while
    /// the note is being recorded.
    @discardableResult func moveToTrash(_ id: UUID) async -> Bool {
        guard recording.state.noteID != id, library.note(id) != nil else { return false }
        if playback.state.noteID == id { playback.stop() }
        let moved = await processing.trash(id) { job in
            guard recording.state.noteID != id else { return false }
            let now = clock.now
            return library.update(id) { $0.trashedAt = now; $0.trashedJob = job }
        }
        guard moved else { return false }
        router.close(noteID: id)
        return true
    }

    func restore(_ id: UUID) {
        let job = library.note(id)?.trashedJob
        guard library.update(id, { $0.trashedAt = nil; $0.trashedJob = nil }) else { return }
        processing.restore(id, trashedJob: job)
    }

    /// Ends any job still running for the note, then removes its voice samples, then its files, then its job. Needs
    /// the saved voices to be readable; when a step fails the note stays in Recently Deleted with its job.
    func deletePermanently(_ id: UUID) async {
        guard library.note(id)?.trashedAt != nil else { return }
        await processing.stopForDelete(id)
        do {
            try await voices.removeEvidence(noteID: id)
            try await library.delete(id)
            await processing.forget(id)
        } catch let error as VoicesStore.Unavailable {
            errors.present(error.message)
        } catch {
            errors.present("Could not delete recording: \(error.localizedDescription)")
        }
    }

    func emptyTrash() async {
        for note in notes { await deletePermanently(note.id) }
    }

    func purgeExpired() async {
        for note in notes where daysLeft(note) == 0 { await deletePermanently(note.id) }
        settings.recordPurge()
    }
}
