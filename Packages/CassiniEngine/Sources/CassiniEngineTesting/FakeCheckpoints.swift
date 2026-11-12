#if DEBUG
import Foundation
import Synchronization
import CassiniEngine

/// Saved progress in memory: what each note's `work/` holds, set by the test.
public final class FakeCheckpoints: JobCheckpoints {
    private struct State {
        var statuses: [UUID: CheckpointStatus] = [:]
        var languages: [UUID: String] = [:]
        var recognizers: [UUID: String] = [:]
        var work: Set<UUID> = []
        var discarded: [UUID] = []
        var held: Set<UUID> = []
        var named: Set<UUID> = []
    }
    private let state = Mutex(State())

    public init() {}

    /// The note has a `work/` directory with `status` in it, begun in `language` (Apple Speech's).
    public func save(_ noteID: UUID, _ status: CheckpointStatus, language: String? = nil, recognizer: String? = nil) {
        state.withLock { $0.statuses[noteID] = status; $0.languages[noteID] = language; $0.recognizers[noteID] = recognizer; $0.work.insert(noteID) }
    }

    public func recognizer(of noteID: UUID) async -> String? { state.withLock { $0.recognizers[noteID] } }

    public func language(of noteID: UUID) async -> String? { state.withLock { $0.languages[noteID] } }

    /// The note has a `work/` directory without saved progress.
    public func addWork(_ noteID: UUID) { state.withLock { _ = $0.work.insert(noteID) } }

    public func hasWork(_ noteID: UUID) -> Bool { state.withLock { $0.work.contains(noteID) } }
    public var discarded: [UUID] { state.withLock { $0.discarded } }

    /// Reads of the note's status wait until `release`, so a test can keep the queue's serial section busy.
    public func hold(_ noteID: UUID) { state.withLock { _ = $0.held.insert(noteID) } }
    public func release(_ noteID: UUID) { state.withLock { _ = $0.held.remove(noteID) } }

    public func status(of noteID: UUID) async -> CheckpointStatus {
        while state.withLock({ $0.held.contains(noteID) }) { try? await Task.sleep(for: .milliseconds(2)) }
        return state.withLock { $0.statuses[noteID] ?? .missing }
    }

    /// The note's `work/` holds draft speaker names without saved progress.
    public func addNames(_ noteID: UUID) { state.withLock { $0.named.insert(noteID); $0.work.insert(noteID) } }

    public func holdsDraft(_ noteID: UUID) async -> Bool {
        state.withLock { $0.statuses[noteID] != nil || $0.named.contains(noteID) }
    }

    public func discard(_ noteID: UUID) async throws {
        state.withLock {
            $0.named.remove(noteID)
            $0.statuses[noteID] = nil
            $0.languages[noteID] = nil
            $0.recognizers[noteID] = nil
            $0.work.remove(noteID)
            $0.discarded.append(noteID)
        }
    }

    public func notesWithWork() async -> Set<UUID> { state.withLock { $0.work } }
}
#endif
