import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Batch progress and its nonzero summary parts stay visible without obscuring the Library.
struct BulkTransferStatus: View {
    @Environment(ImportStore.self) private var imports
    @Environment(ExportStore.self) private var exports

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let progress = imports.batchProgress {
                progressRow(BulkCopy.progress("import.progress", progress), cancel: imports.cancelBatch)
                    .accessibilityIdentifier("bulkImportProgress")
            } else {
                if imports.batchCancelled { Text(BulkCopy.cancelled).accessibilityIdentifier("bulkImportCancelled") }
                if let summary = imports.batchSummary {
                    let text = BulkCopy.summary(summary)
                    if !text.isEmpty { Text(text).accessibilityIdentifier("bulkImportSummary") }
                }
                ForEach(Array(imports.batchArchiveFailures.enumerated()), id: \.offset) { _, failure in
                    Text(BulkCopy.archiveFailure(failure)).accessibilityIdentifier("bulkImportArchiveFailure")
                }
            }
            if let progress = exports.zipProgress {
                progressRow(BulkCopy.progress("export.zip.progress", progress), cancel: exports.cancelZIP)
                    .accessibilityIdentifier("bulkExportProgress")
            } else if exports.zipExported > 0 {
                Text(BulkCopy.count("export.zip.done", exports.zipExported))
                    .accessibilityIdentifier("bulkExportDone")
            }
        }
        .font(.subheadline).foregroundStyle(Color.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.gutter)
    }

    private func progressRow(_ text: String, cancel: @escaping () -> Void) -> some View {
        HStack {
            ProgressView().accessibilityHidden(true)
            Text(text)
            Spacer()
            Button(BulkCopy.cancel, action: cancel).frame(minHeight: HitTarget.minimum)
        }
    }
}

/// Selection stays separate from the transient share file. Nothing is omitted silently from Export All.
struct BulkExportPicker: View {
    let notes: [Note]
    let perform: ([UUID]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []

    var body: some View {
        NavigationStack {
            List {
                Button(BulkCopy.exportAll) { perform(notes.map(\.id)) }
                    .disabled(notes.isEmpty || notes.contains { $0.audio == .live })
                    .accessibilityIdentifier("bulkExportAll")
                ForEach(notes) { note in
                    Toggle(isOn: Binding(get: { selection.contains(note.id) }, set: { selected in
                        if selected { selection.insert(note.id) } else { selection.remove(note.id) }
                    })) { Text(verbatim: note.title) }
                    .disabled(note.audio == .live)
                    .accessibilityIdentifier("bulkExportChoice-\(note.id.uuidString)")
                }
            }
            .navigationTitle(LibraryCopy.export)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(BulkCopy.cancel) { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !selection.isEmpty {
                    Button(BulkCopy.exportSelected) {
                        perform(notes.filter { selection.contains($0.id) }.map(\.id))
                    }
                    .disabled(notes.contains { selection.contains($0.id) && $0.audio == .live })
                    .frame(minHeight: HitTarget.minimum).padding()
                    .accessibilityIdentifier("bulkExportSelected")
                }
            }
        }
    }
}
