import Foundation
import Synchronization
import CassiniEngine
import CassiniNotebook

/// A note repository that counts its writes, and can be told to fail them.
public final class CountingNotePersistence: NotePersisting {
    private let base: NoteRepository
    private let counts = Mutex((saves: 0, failSaves: false))

    public init(root: URL) throws { base = try NoteRepository(root: root) }

    public var root: URL { base.root }
    public var saveCount: Int { counts.withLock { $0.saves } }
    public func failSaves(_ fail: Bool) { counts.withLock { $0.failSaves = fail } }

    public func load() throws -> LoadReport { try base.load() }

    public func save(_ note: Note) throws {
        let fails = counts.withLock { state in
            if !state.failSaves { state.saves += 1 }
            return state.failSaves
        }
        if fails { throw CocoaError(.fileWriteUnknown) }
        try base.save(note)
    }

    public func delete(_ id: UUID) throws { try base.delete(id) }
}
