import Foundation
import CassiniNotebook

/// Where notes are kept. `NoteRepository` is the real one; tests wrap it to count writes.
public protocol NotePersisting: Sendable {
    var root: URL { get }
    func load() throws -> LoadReport
    func save(_ note: Note) throws
    func delete(_ id: UUID) throws
}

extension NoteRepository: NotePersisting {}

public enum NoteChange: Hashable, Sendable {
    case saved(Note)
    case deleted(UUID)
}

/// The notes in memory and on disk. Every write is encoded and written here, off the main actor, one at a time; the
/// screens mirror the notes from `changes()`.
public actor NoteStore {
    public nonisolated let root: URL
    private let persistence: any NotePersisting
    private var notes: [UUID: Note] = [:]
    private var observers: [UUID: AsyncStream<NoteChange>.Continuation] = [:]
    public private(set) var loadReport = LoadReport()

    public init(persistence: any NotePersisting) {
        self.persistence = persistence
        root = persistence.root
    }

    public init(root: URL) throws {
        self.init(persistence: try NoteRepository(root: root))
    }

    /// Reads every note from disk, replacing what is in memory.
    @discardableResult public func load() throws -> LoadReport {
        let report = try persistence.load()
        notes = Dictionary(report.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        loadReport = report
        return report
    }

    /// Newest first.
    public func all() -> [Note] { notes.values.sorted { $0.createdAt > $1.createdAt } }

    public func note(_ id: UUID) -> Note? { notes[id] }

    public func save(_ note: Note) throws {
        try persistence.save(note)
        notes[note.id] = note
        publish(.saved(note))
    }

    /// Applies `change` to the note and writes it, unless `change` left it as it was. Nil when there is no such note.
    @discardableResult
    public func mutate(_ id: UUID, _ change: @Sendable (inout Note) -> Void) throws -> Note? {
        guard let current = notes[id] else { return nil }
        var copy = current
        change(&copy)
        if copy != current { try save(copy) }
        return copy
    }

    /// Applies `change` to every note and writes the ones it changed. Returns those.
    @discardableResult
    public func mutateAll(_ change: @Sendable (inout Note) -> Void) throws -> [Note] {
        var changed: [Note] = []
        for current in all() {
            var copy = current
            change(&copy)
            guard copy != current else { continue }
            try save(copy)
            changed.append(copy)
        }
        return changed
    }

    /// Removes the note's directory, then the note.
    public func delete(_ id: UUID) throws {
        try persistence.delete(id)
        notes[id] = nil
        publish(.deleted(id))
    }

    /// Every change from now on, in the order it was written.
    public func changes() -> AsyncStream<NoteChange> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: NoteChange.self)
        continuation.onTermination = { [weak self] _ in Task { await self?.removeObserver(id) } }
        observers[id] = continuation
        return stream
    }

    public nonisolated func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    public nonisolated func audioURL(for note: Note) -> URL { directory(for: note.id).appendingPathComponent(note.audioFilename) }
    public nonisolated func originalAudioURL(for note: Note) -> URL {
        note.originalAudioFilename.map { directory(for: note.id).appendingPathComponent($0) } ?? audioURL(for: note)
    }

    private func publish(_ change: NoteChange) {
        for observer in observers.values { observer.yield(change) }
    }

    private func removeObserver(_ id: UUID) { observers[id] = nil }
}
