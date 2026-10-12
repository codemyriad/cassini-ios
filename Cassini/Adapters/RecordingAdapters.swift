import Foundation
import CassiniAudio
import CassiniEngine
import CassiniNotebook

/// A recording's note rows go through the Library, so the screens show each change at once.
struct LibraryRecordingNotes: RecordingNotes {
    let library: LibraryStore

    func create(_ note: Note) async throws { try await library.insert(note) }
    func captureURL(for note: Note) async -> URL? { await library.audioURL(note) }
    func update(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) async throws -> Note? { await library.commit(id, change) }
    func discard(_ id: UUID) async throws { try await library.delete(id) }
    func showUnsaved(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) async { await library.showUnsaved(id, change) }
}

/// A finished recording is queued like any other note.
extension ProcessingStore: RecordingHandoff {
    func audioFinalizing(_ noteID: UUID) { beginFinalizing(noteID) }
    func audioReady(_ noteID: UUID) { endFinalizing(noteID) }
    func handOff(_ noteID: UUID) -> Bool {
        enqueue(noteID)
        return state.isQueued(noteID) || state.isRunning(noteID)
    }
}

/// Fixes the `data` chunk of a CAF capture that was not closed.
struct CAFCaptureRepairer: CaptureRepairing {
    func repairCapture(at url: URL) throws { _ = try CAFRepair.repair(url) }
}
