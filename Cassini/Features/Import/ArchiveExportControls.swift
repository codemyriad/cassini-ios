import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The native export menu observes selection/library/export state, independently of the capture clock.
/// Rebuilding its actions on every recording tick can invalidate a menu item while UIKit is dispatching its tap.
struct ArchiveExportControls: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ExportStore.self) private var exports
    @Environment(ErrorPresenter.self) private var errors
    @Binding var selectedNotes: Set<UUID>
    @Bindable var archiveExport: ArchiveExportModel

    var body: some View {
        if library.notes.contains(where: ArchiveSelection.isExportable) {
            EditButton().buttonStyle(ArchiveSelectionButtonStyle())
                .accessibilityIdentifier("selectNotesForExport")
            Menu {
                Button(BulkTransferCopy.all) { exportArchive(selected: false) }
                if !selectedNotes.isDisjoint(with: ArchiveSelection.ids(library.notes)) {
                    Button(BulkTransferCopy.selected) { exportArchive(selected: true) }
                }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .frame(minWidth: HitTarget.minimum, minHeight: HitTarget.minimum)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(BulkTransferCopy.all)
            .accessibilityIdentifier("libraryArchiveMenu")
            .disabled(archiveExport.progress != nil)
        }
    }

    private func exportArchive(selected: Bool) {
        let ids = library.notes.filter {
            ArchiveSelection.isExportable($0) && (!selected || selectedNotes.contains($0.id))
        }.map(\.id)
        archiveExport.start(ids, exports: exports, errors: errors)
    }
}

private struct ArchiveSelectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: HitTarget.minimum, minHeight: HitTarget.minimum)
            .contentShape(Rectangle()).opacity(configuration.isPressed ? 0.6 : 1)
    }
}
