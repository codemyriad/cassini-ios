#if DEBUG
import Foundation
import Synchronization
import CassiniEngine
import CassiniNotebook

/// A microphone whose clock, file size and failures the test sets. `start` writes a few bytes, so the capture file is
/// not empty.
@MainActor public final class ScriptedCapture: AudioCapture {
    public let events: AsyncStream<CaptureEvent>
    private let continuation: AsyncStream<CaptureEvent>.Continuation
    public var elapsed: TimeInterval = 0
    /// The capture file's size; by default what 48 kHz 16-bit mono PCM writes in `elapsed`.
    public var fileBytesOverride: Int64?
    public private(set) var url: URL?
    public private(set) var isPaused = false
    public private(set) var starts = 0
    public private(set) var stops = 0
    public var startError: (any Error)?
    public var resumeError: (any Error)?
    /// Bytes `start` writes to the file; 0 leaves it empty.
    public var capturedBytes = 100

    public init() { (events, continuation) = AsyncStream.makeStream(of: CaptureEvent.self) }

    public var fileBytes: Int64 { fileBytesOverride ?? Int64(elapsed * Double(RecordingPolicy.pcmBytesPerSecond)) }

    public func start(url: URL) async throws -> CaptureFormat {
        if let startError { throw startError }
        starts += 1
        self.url = url
        isPaused = false
        if capturedBytes > 0 { try Data(repeating: 1, count: capturedBytes).write(to: url) }
        return .pcm48kMono
    }

    public func pause() { isPaused = true }

    public func resume() throws {
        if let resumeError { throw resumeError }
        isPaused = false
    }

    public func stop() async throws -> CaptureResult {
        stops += 1
        url = nil
        return CaptureResult(duration: elapsed)
    }

    /// Sends a capture event as the system would.
    public func send(_ event: CaptureEvent) { continuation.yield(event) }
}

/// Records what the Live Activity was asked to show.
@MainActor public final class FakeLiveActivity: LiveActivityPort {
    public private(set) var started: [(noteID: UUID, state: RecordingActivityState)] = []
    public private(set) var updates: [RecordingActivityState] = []
    public private(set) var ends = 0
    public init() {}
    public var isRunning: Bool { started.count > ends }
    public var current: RecordingActivityState? { isRunning ? updates.last ?? started.last?.state : nil }
    public func start(noteID: UUID, _ state: RecordingActivityState) { started.append((noteID, state)) }
    public func update(_ state: RecordingActivityState) { updates.append(state) }
    public func end() { ends += 1 }
}

/// Microphone access the test sets; `request` answers with `answer` when access is undetermined.
@MainActor public final class FakeMicrophonePermission: MicrophonePermission {
    public var access: MicrophoneAccess
    public var answer: Bool
    public private(set) var requests = 0
    public init(access: MicrophoneAccess = .granted, answer: Bool = true) { self.access = access; self.answer = answer }
    public func request() async -> Bool {
        requests += 1
        if access == .undetermined { access = answer ? .granted : .denied }
        return access == .granted
    }
}

/// Records the notes handed to transcription.
@MainActor public final class FakeRecordingHandoff: RecordingHandoff {
    public private(set) var handedOff: [UUID] = []
    public private(set) var finalizing: Set<UUID> = []
    public var accepts = true
    public init() {}
    public func audioFinalizing(_ noteID: UUID) { finalizing.insert(noteID) }
    public func audioReady(_ noteID: UUID) { finalizing.remove(noteID) }
    public func handOff(_ noteID: UUID) -> Bool {
        guard accepts else { return false }
        handedOff.append(noteID)
        return true
    }
}

/// Records the captures it was asked to repair.
public final class FakeCaptureRepairer: CaptureRepairing {
    private let repaired = Mutex<[URL]>([])
    public init() {}
    public var urls: [URL] { repaired.withLock { $0 } }
    public func repairCapture(at url: URL) throws { repaired.withLock { $0.append(url) } }
}

/// `RecordingNotes` over a `NoteStore` that counts the title writes, and whose updates can be made to fail.
public final class CountingRecordingNotes: RecordingNotes {
    public let store: NoteStore
    private let titles = Mutex(0)
    private let failing = Mutex(false)
    private let unsavedNotes = Mutex<[UUID: Note]>([:])
    public init(store: NoteStore) { self.store = store }
    public var titleWrites: Int { titles.withLock { $0 } }
    /// While true every update writes nothing and returns nil, as a failed write does.
    public var failUpdates: Bool {
        get { failing.withLock { $0 } }
        set { failing.withLock { $0 = newValue } }
    }
    /// The notes as shown after `showUnsaved`, by id.
    public var unsaved: [UUID: Note] { unsavedNotes.withLock { $0 } }
    public func create(_ note: Note) async throws { try await store.create(note) }
    public func note(_ id: UUID) async -> Note? {
        if let shown = unsaved[id] { return shown }
        return await store.note(id)
    }
    public func captureURL(for note: Note) async -> URL? { store.captureURL(for: note) }
    public func update(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) async throws -> Note? {
        guard !failUpdates else { return nil }
        let before = await store.note(id)
        let after = try await store.update(id, change)
        if let before, let after, before.title != after.title { titles.withLock { $0 += 1 } }
        return after
    }
    public func discard(_ id: UUID) async throws { try await store.discard(id) }
    public func showUnsaved(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) async {
        guard var note = await store.note(id) else { return }
        change(&note)
        unsavedNotes.withLock { $0[id] = note }
    }
}
#endif
