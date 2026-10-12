import Foundation
import CassiniNotebook

/// The note rows of a recording. `NoteStore` is one; the app passes its `LibraryStore`, so the screens show each change
/// at once.
public protocol RecordingNotes: Sendable {
    /// Writes a new note.
    func create(_ note: Note) async throws
    /// Where the note's audio file is; nil when the library is not open.
    func captureURL(for note: Note) async -> URL?
    /// Applies `change` and writes the note; nil when there is no such note or the write failed.
    func update(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) async throws -> Note?
    /// Removes the note and its directory: a recording that did not start or captured nothing.
    func discard(_ id: UUID) async throws
    /// Shows `change` on screen without writing it, until the next launch: a finished recording whose seal could not be
    /// written still opens as a plain note.
    func showUnsaved(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) async
}

extension NoteStore: RecordingNotes {
    public func create(_ note: Note) throws { try save(note) }
    public nonisolated func captureURL(for note: Note) -> URL? { audioURL(for: note) }
    public func update(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) throws -> Note? { try mutate(id, change) }
    public func discard(_ id: UUID) throws { try delete(id) }
    /// The store is what the screens show; there is nothing to change beside it.
    public func showUnsaved(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) {}
}

/// Hands a finished recording to transcription.
@MainActor public protocol RecordingHandoff: AnyObject {
    /// The note's audio is being sealed and compressed; it cannot be queued until `audioReady`.
    func audioFinalizing(_ noteID: UUID)
    func audioReady(_ noteID: UUID)
    /// Queues the note's transcription; false when it could not be queued.
    func handOff(_ noteID: UUID) -> Bool
}

public enum MicrophoneAccess: Hashable, Sendable {
    case undetermined, denied, granted
}

/// Microphone access for recording.
@MainActor public protocol MicrophonePermission: AnyObject {
    var access: MicrophoneAccess { get }
    /// Shows the system question when access is undetermined; true when access is granted.
    func request() async -> Bool
}

/// Makes a capture that was not closed (a crash, a kill) readable again.
public protocol CaptureRepairing: Sendable {
    func repairCapture(at url: URL) throws
}
