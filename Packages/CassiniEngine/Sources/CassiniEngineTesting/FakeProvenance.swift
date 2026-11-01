#if DEBUG
import Foundation
import Synchronization
import CassiniEngine
import CassiniNotebook

/// Provenance records in memory.
public final class FakeProvenance: ProvenanceStoring {
    private let stored: Mutex<[UUID: [ProvenanceRecord]]>
    /// Each note with one run's record.
    public init(_ records: [UUID: ProvenanceRecord] = [:]) { stored = Mutex(records.mapValues { [$0] }) }
    /// Each note with its runs' records, oldest first.
    public init(runs: [UUID: [ProvenanceRecord]]) { stored = Mutex(runs) }
    public func records(_ noteID: UUID) -> [ProvenanceRecord] { stored.withLock { $0[noteID] ?? [] } }
    public func save(_ record: ProvenanceRecord, for noteID: UUID) throws {
        stored.withLock { $0[noteID] = ProvenanceRecord.keeping(record, in: $0[noteID] ?? []) }
    }
}
#endif
