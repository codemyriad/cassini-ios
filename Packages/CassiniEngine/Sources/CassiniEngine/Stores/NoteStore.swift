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

/// A change made to a copy of a note, kept so the store can run it again on a newer note. Ids and dates the change
/// stamps on the note should be made before the change, so that running it again gives the same values.
public struct NoteEdit: Sendable {
    /// The note the change was made to.
    public let before: Note
    /// `before` with the change applied.
    public let after: Note
    public let change: @Sendable (inout Note) -> Void

    public var id: UUID { before.id }
    public var changesNothing: Bool { after == before }

    public init(_ note: Note, _ change: @escaping @Sendable (inout Note) -> Void) {
        var copy = note
        change(&copy)
        before = note
        after = copy
        self.change = change
    }

    /// `after` when `current` is still the note the change was made to; otherwise the change applied to `current`, so
    /// that what another writer saved in between is kept.
    public func applied(to current: Note) -> Note {
        guard current != before else { return after }
        var copy = current
        change(&copy)
        return copy
    }
}

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

    /// Writes `edit` over the stored note: its result when nobody wrote the note since the edit was made, otherwise its
    /// change applied to the stored note. Writes nothing when that leaves the note as it is. Nil when there is no such
    /// note.
    @discardableResult
    public func apply(_ edit: NoteEdit) throws -> Note? {
        guard let current = notes[edit.id] else { return nil }
        let updated = edit.applied(to: current)
        if updated != current { try save(updated) }
        return updated
    }

    /// `apply(_:)` for several edits, in order; stops at the first write that fails. Returns the notes it wrote.
    @discardableResult
    public func applyAll(_ edits: [NoteEdit]) throws -> [Note] {
        var written: [Note] = []
        for edit in edits {
            guard let current = notes[edit.id] else { continue }
            let updated = edit.applied(to: current)
            guard updated != current else { continue }
            try save(updated)
            written.append(updated)
        }
        return written
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
