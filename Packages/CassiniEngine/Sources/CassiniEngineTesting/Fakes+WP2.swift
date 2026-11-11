#if DEBUG
import Foundation
import CassiniEngine
import CassiniNotebook

/// What the Recently Deleted fakes were asked, in order, across all of them.
@MainActor public final class TrashLog {
    public private(set) var events: [String] = []
    public init() {}
    public func record(_ event: String) { events.append(event) }
    public func clear() { events.removeAll() }
}

/// Notes in memory. `delete` can fail, for every note or for some, and runs `onDelete` first.
@MainActor public final class FakeTrashNotes: TrashNotes {
    public private(set) var stored: [UUID: Note] = [:]
    public var deleteError: (any Error)?
    /// Notes whose delete fails every time.
    public var undeletable: Set<UUID> = []
    public var onDelete: @MainActor (UUID) -> Void = { _ in }
    private let log: TrashLog

    public init(_ notes: [Note] = [], log: TrashLog = TrashLog()) {
        self.log = log
        for note in notes { stored[note.id] = note }
    }

    public var notes: [Note] { stored.values.sorted { $0.sortDate > $1.sortDate } }

    public func note(_ id: UUID) -> Note? { stored[id] }

    public func add(_ note: Note) { stored[note.id] = note }

    @discardableResult
    public func update(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) -> Bool {
        guard var note = stored[id] else { return false }
        change(&note)
        stored[id] = note
        return true
    }

    public func delete(_ id: UUID) async throws {
        log.record("files \(stored[id]?.title ?? "?")")
        onDelete(id)
        if let deleteError { throw deleteError }
        if undeletable.contains(id) { throw CocoaError(.fileWriteNoPermission) }
        stored[id] = nil
    }
}

/// A queue that keeps one job per note. Moving a note takes a queued job out and keeps any other, as the coordinator
/// does; `onCancel` runs inside the first step of a permanent delete, where other calls can come in between.
@MainActor public final class FakeTrashQueue: TrashQueue {
    public var jobs: [UUID: TrashedJob] = [:]
    public var running: Set<UUID> = []
    public var onCancel: @MainActor (UUID) async -> Void = { _ in }
    private let log: TrashLog
    private let title: (UUID) -> String

    public init(log: TrashLog = TrashLog(), title: @escaping (UUID) -> String = { $0.uuidString }) {
        self.log = log; self.title = title
    }

    public func isRunning(_ noteID: UUID) -> Bool { running.contains(noteID) }

    public func trash(_ noteID: UUID, then move: (TrashedJob?) -> Bool) async -> Bool {
        log.record("trash \(title(noteID))")
        var job = jobs[noteID]
        if running.remove(noteID) != nil, let kind = job?.kind { job = TrashedJob(state: .paused, kind: kind) }
        if job?.state == .queued { jobs[noteID] = nil } else { jobs[noteID] = job }
        return move(job)
    }

    public func restore(_ noteID: UUID, trashedJob: TrashedJob?) {
        log.record("restore \(title(noteID))")
        guard let trashedJob, trashedJob.state == .queued else { return }
        jobs[noteID] = trashedJob
        log.record("requeue \(title(noteID)) \(trashedJob.kind.rawValue)")
    }

    public func cancelAndRemove(_ noteID: UUID) async {
        log.record("job \(title(noteID))")
        await onCancel(noteID)
        running.remove(noteID)
        jobs[noteID] = nil
    }
}

/// Voiceprints by note. Removing them can fail after they went, as Cassini closing right there would.
@MainActor public final class FakeVoiceEvidence: VoiceEvidence {
    public var isReadable = true
    public var prints: Set<UUID> = []
    /// Thrown after the note's prints were removed.
    public var errorAfterRemoving: (any Error)?
    private let log: TrashLog
    private let title: (UUID) -> String

    public init(prints: Set<UUID> = [], log: TrashLog = TrashLog(), title: @escaping (UUID) -> String = { $0.uuidString }) {
        self.prints = prints; self.log = log; self.title = title
    }

    public func removeEvidence(noteID: UUID) async throws {
        log.record("voices \(title(noteID))")
        prints.remove(noteID)
        if let errorAfterRemoving { throw errorAfterRemoving }
    }
}

/// The recording, the player and the navigation around a move.
@MainActor public final class FakeTrashHost: TrashHost {
    public var recording: Set<UUID> = []
    public private(set) var stoppedPlayback: [UUID] = []
    public private(set) var closed: [UUID] = []
    public private(set) var purges: [Date] = []

    public init() {}

    public func mayTrash(_ noteID: UUID) -> Bool { !recording.contains(noteID) }
    public func willTrash(_ noteID: UUID) { stoppedPlayback.append(noteID) }
    public func didTrash(_ noteID: UUID) { closed.append(noteID) }
    public func didPurge(at date: Date) { purges.append(date) }
}
#endif
