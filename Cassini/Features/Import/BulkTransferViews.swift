import SwiftUI
import Observation
import CassiniEngine
import CassiniNotebook

struct ImportBatchesView: View {
    @Environment(ImportStore.self) private var imports
    var body: some View {
        ForEach(imports.batches) { batch in
            VStack(alignment: .leading, spacing: 8) {
                if let report = batch.report {
                    if report.cancelled { Text(BulkTransferCopy.cancelled) }
                    let summary = BulkTransferCopy.summary(report.summary)
                    if !summary.isEmpty { Text(summary).accessibilityIdentifier("bulkImportSummary") }
                    ForEach(Array(report.archiveFailures.enumerated()), id: \.offset) { _, failure in Text(BulkTransferCopy.archive(failure)) }
                    Button(BulkTransferCopy.done) { imports.batches.removeAll { $0.id == batch.id } }
                    #if DEBUG
                    UITestStateMarker(identifier: "bulkImportCompleted", value: batch.id.uuidString)
                    #endif
                } else {
                    ProgressView(BulkTransferCopy.importing(batch.progress))
                    Button(BulkTransferCopy.cancel, role: .cancel) { batch.cancel() }
                        .accessibilityIdentifier("cancelBulkImport")
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.neutralTint, in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

@MainActor @Observable final class ArchiveExportModel {
    var progress: TransferProgress?
    var completedCount: Int?
    var shareItem: ShareItem?
    @ObservationIgnored private var task: Task<Void, Never>?
    func start(_ ids: [UUID], exports: ExportStore, errors: ErrorPresenter) {
        guard task == nil, !ids.isEmpty else { return }
        completedCount = nil
        progress = .init(done: 1, total: ids.count)
        task = Task { [self] in
            var pending: URL?
            do {
                let url = try await exports.exportArchive(ids) { value in await MainActor.run { self.progress = value } }
                pending = url
                try Task.checkCancellation()
                shareItem = exports.shareItem(url)
                pending = nil
                completedCount = ids.count
            } catch is CancellationError {} catch { errors.present(ExportCopy.notSaved) }
            if let pending { exports.discard(pending); await exports.waitForDiscards() }
            progress = nil; task = nil
        }
    }
    func cancel() { task?.cancel() }
}

struct ArchiveExportProgressView: View {
    @Bindable var model: ArchiveExportModel
    var body: some View {
        if let progress = model.progress {
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(BulkTransferCopy.exporting(progress))
                Button(BulkTransferCopy.cancel, role: .cancel) { model.cancel() }.accessibilityIdentifier("cancelZIPExport")
            }.padding(14)
        } else if let count = model.completedCount {
            HStack {
                Text(BulkTransferCopy.exported(count)).accessibilityIdentifier("zipExportCompleted")
                Spacer()
                Button(BulkTransferCopy.done) { model.completedCount = nil }
            }.padding(14)
        }
    }
}
