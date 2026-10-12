import Foundation
import CassiniAudio
import CassiniEngine
import CassiniNotebook

/// A recording's note rows go through the Library, so the screens show each change at once.
struct LibraryRecordingNotes: RecordingNotes {
    let library: LibraryStore

    func create(_ note: Note) async throws { try await library.insert(note) }
    func note(_ id: UUID) async -> Note? { await library.note(id) }
    func captureURL(for note: Note) async -> URL? { await library.audioURL(note) }
    func update(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) async throws -> Note? { await library.commit(id, change) }
    func discard(_ id: UUID) async throws { try await library.delete(id) }
    func showUnsaved(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) async { await library.showUnsaved(id, change) }
}

/// A finished recording is queued like any other note, as an automatic request that clears no hold.
@MainActor final class ProcessingHandoff: RecordingHandoff {
    private let processing: ProcessingStore

    init(_ processing: ProcessingStore) { self.processing = processing }

    func audioFinalizing(_ noteID: UUID) { processing.beginFinalizing(noteID) }
    func audioReady(_ noteID: UUID) { processing.endFinalizing(noteID) }

    func handOff(_ noteID: UUID) async -> Bool {
        if case .queued = await processing.transcribe(noteID, origin: .automatic) { return true }
        return false
    }
}

/// Fixes the `data` chunk of a CAF capture that was not closed.
struct CAFCaptureRepairer: CaptureRepairing {
    func repairCapture(at url: URL) throws { _ = try CAFRepair.repair(url) }
}
