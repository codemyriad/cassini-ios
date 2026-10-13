#if DEBUG
import Foundation
import Synchronization
import CassiniEngine
import CassiniNotebook

/// Provenance records in memory.
public final class FakeProvenance: ProvenanceStoring {
    private let records: Mutex<[UUID: ProvenanceRecord]>
    public init(_ records: [UUID: ProvenanceRecord] = [:]) { self.records = Mutex(records) }
    public func load(_ noteID: UUID) -> ProvenanceRecord? { records.withLock { $0[noteID] } }
    public func save(_ record: ProvenanceRecord, for noteID: UUID) throws { records.withLock { $0[noteID] = record } }
}
#endif
