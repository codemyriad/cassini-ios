import Foundation
import Observation
import CassiniNotebook

@MainActor @Observable final class ImportBatch: Identifiable {
    let id = UUID()
    var progress: TransferProgress
    var report: BulkImportReport?
    var pendingConsent: UUID?
    @ObservationIgnored var task: Task<Void, Never>?
    init(total: Int) { progress = TransferProgress(done: 1, total: total) }
    func cancel() { task?.cancel() }
}
