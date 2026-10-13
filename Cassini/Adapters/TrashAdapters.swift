import Foundation
import CassiniEngine
import CassiniNotebook

// What `TrashService` works over in the app: the Library's notes, the transcription queue, and the
// recording, player, navigation and settings around a move.

extension LibraryStore: TrashNotes {}

extension ProcessingStore: TrashQueue {
    func isRunning(_ noteID: UUID) -> Bool { state.isRunning(noteID) }

    func cancelAndRemove(_ noteID: UUID) async { await forget(noteID) }
}

@MainActor final class AppTrashHost: TrashHost {
    private let recording: RecordingStore
    private let playback: PlaybackStore
    private let router: Router
    private let settings: SettingsStore

    init(recording: RecordingStore, playback: PlaybackStore, router: Router, settings: SettingsStore) {
        self.recording = recording; self.playback = playback; self.router = router; self.settings = settings
    }

    func mayTrash(_ noteID: UUID) -> Bool { recording.state.noteID != noteID }

    func willTrash(_ noteID: UUID) {
        if playback.state.noteID == noteID { playback.stop() }
    }

    func didTrash(_ noteID: UUID) { router.close(noteID: noteID) }

    func didPurge(at date: Date) { settings.recordPurge() }
}
