import SwiftUI
import UIKit
import CassiniEngine
import CassiniNotebook

/// Pure selection rules for the Library: derives candidates from the currently visible (filtered) content,
/// reconciles active selection and cached row frames when filters change, and filters export/delete targets
/// and two-finger pan hit-testing so hidden notes can never be selected, exported, or deleted.
enum LibrarySelection {
    /// Selectable note IDs from the current filtered `LibraryContent` (flat search results or day sections),
    /// excluding live recordings and trashed notes.
    static func selectableIDs(from content: LibraryContent, notes: [Note]) -> [UUID] {
        let eligibleNotes = Set(notes.lazy.filter { $0.trashedAt == nil && !$0.isRecording }.map(\.id))
        let rows: [LibraryRow]
        if content.loading && content.emptyState != .unavailable {
            rows = []
        } else if let results = content.results {
            rows = results
        } else {
            rows = content.sections.flatMap(\.rows)
        }
        return rows.compactMap { row in
            (!row.isRecording && eligibleNotes.contains(row.id)) ? row.id : nil
        }
    }

    /// Reconciles the current selection against the currently visible selectable IDs,
    /// dropping any note hidden by a filter, trashed, or removed.
    static func reconcile(_ selected: Set<UUID>, selectable: Set<UUID>) -> Set<UUID> {
        selected.intersection(selectable)
    }

    /// Selects all currently visible selectable IDs while dropping any hidden IDs.
    static func selectAll(_ selected: Set<UUID>, selectableIDs: [UUID]) -> Set<UUID> {
        reconcile(selected, selectable: Set(selectableIDs)).union(selectableIDs)
    }

    /// Prunes cached row frames to only the currently visible selectable IDs,
    /// discarding stale frames left behind when filtering hides rows.
    static func pruneFrames(_ frames: [UUID: CGRect], selectable: Set<UUID>) -> [UUID: CGRect] {
        frames.filter { selectable.contains($0.key) }
    }

    /// Returns the IDs hit by a two-finger swipe point, restricted to currently visible selectable rows.
    static func hitRowIDs(at point: CGPoint, frames: [UUID: CGRect], selectable: Set<UUID>) -> [UUID] {
        frames.compactMap { id, rect in
            (selectable.contains(id) && rect.contains(point)) ? id : nil
        }
    }

    /// Exportable IDs for the current selection, restricted to currently visible selectable notes.
    static func exportableIDs(selected: Set<UUID>, selectableIDs: [UUID], notes: [Note]) -> [UUID] {
        let allowed = selected.intersection(selectableIDs)
        return notes.filter { allowed.contains($0.id) && ArchiveSelection.isExportable($0) }.map(\.id)
    }

    /// Deletable IDs for the current selection, restricted to currently visible selectable notes.
    static func deletableIDs(selected: Set<UUID>, selectableIDs: [UUID], notes: [Note]) -> [UUID] {
        let allowed = selected.intersection(selectableIDs)
        return notes.filter { allowed.contains($0.id) && $0.trashedAt == nil && !$0.isRecording }.map(\.id)
    }
}

/// The Select button on the Library filter row: enters selection mode in the normal text colour.
struct ArchiveExportControls: View {
    let hasSelectable: Bool
    @Binding var editMode: EditMode

    var body: some View {
        if hasSelectable {
            Button(LibraryCopy.select) {
                editMode = .active
            }
            .buttonStyle(ArchiveSelectionButtonStyle())
            .foregroundStyle(Color.ink)
            .font(.subheadline.weight(.medium))
            .accessibilityIdentifier("selectNotesForExport")
        }
    }
}

/// The selection header replacing the All / Starred tabs while selecting: "{n} selected" and accent "Done".
struct LibrarySelectionHeader: View {
    let selectedCount: Int
    let done: () -> Void

    var body: some View {
        HStack {
            Text(LibraryCopy.selectedCount(selectedCount))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.ink)
                .monospacedDigit()
                .accessibilityIdentifier("selectedCountLabel")
            Spacer(minLength: 8)
            Button(BulkTransferCopy.done, action: done)
                .buttonStyle(ArchiveSelectionButtonStyle())
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.accentInk)
                .accessibilityIdentifier("doneSelectingNotes")
        }
    }
}

/// Bottom action bar while selecting meetings: Select All, Export, and Delete.
struct LibrarySelectionBar: View {
    @Environment(LibraryStore.self) private var library
    @Environment(ExportStore.self) private var exports
    @Environment(ErrorPresenter.self) private var errors
    let selectableIDs: [UUID]
    @Binding var selectedNotes: Set<UUID>
    @Bindable var archiveExport: ArchiveExportModel
    let deleteSelected: ([UUID]) -> Void

    private var exportableSelected: [UUID] {
        LibrarySelection.exportableIDs(selected: selectedNotes, selectableIDs: selectableIDs, notes: library.notes)
    }

    private var deletableSelected: [UUID] {
        LibrarySelection.deletableIDs(selected: selectedNotes, selectableIDs: selectableIDs, notes: library.notes)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(LibraryCopy.selectAll) {
                selectedNotes = LibrarySelection.selectAll(selectedNotes, selectableIDs: selectableIDs)
            }
            .buttonStyle(ArchiveSelectionButtonStyle())
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.ink)
            .disabled(selectableIDs.isEmpty)
            .accessibilityIdentifier("selectAllNotes")

            Spacer(minLength: 8)

            Button(LibraryCopy.export) {
                archiveExport.start(exportableSelected, exports: exports, errors: errors)
            }
            .buttonStyle(ArchiveSelectionButtonStyle())
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.ink)
            .disabled(exportableSelected.isEmpty || archiveExport.progress != nil)
            .accessibilityIdentifier("exportSelectedNotes")

            Spacer(minLength: 8)

            Button(TrashCopy.delete, role: .destructive) {
                deleteSelected(deletableSelected)
            }
            .buttonStyle(ArchiveSelectionButtonStyle())
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Color.toneError)
            .disabled(deletableSelected.isEmpty)
            .accessibilityIdentifier("deleteSelectedNotes")
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge).accessibilityShowsLargeContentViewer()
        .padding(.horizontal, 14).padding(.vertical, 10)
        .readableWidth()
        .selectionBarBackground()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("librarySelectionBar")
    }
}

/// Captures a two-finger vertical pan over the Library scroll view to enter selection mode and tick rows swept across.
struct TwoFingerSelectOverlay: UIViewRepresentable {
    let frames: [UUID: CGRect]
    let selectable: Set<UUID>
    let onBegin: () -> Void
    let onTouchRow: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> PassThroughView {
        let view = PassThroughView()
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.minimumNumberOfTouches = 2
        pan.maximumNumberOfTouches = 2
        pan.cancelsTouchesInView = false
        pan.delegate = context.coordinator
        view.gesture = pan
        return view
    }

    func updateUIView(_ uiView: PassThroughView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.referenceView = uiView
    }

    final class PassThroughView: UIView {
        var gesture: UIPanGestureRecognizer?

        override func willMove(toSuperview newSuperview: UIView?) {
            if let gesture, let superview { superview.removeGestureRecognizer(gesture) }
            super.willMove(toSuperview: newSuperview)
        }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            if let gesture, let superview { superview.addGestureRecognizer(gesture) }
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            nil
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TwoFingerSelectOverlay
        weak var referenceView: UIView?
        private var touched: Set<UUID> = []

        init(parent: TwoFingerSelectOverlay) { self.parent = parent }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            true
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            guard let view = referenceView, !parent.selectable.isEmpty else { return }
            switch gesture.state {
            case .began:
                touched.removeAll()
                parent.onBegin()
                hit(at: gesture.location(in: view))
            case .changed:
                hit(at: gesture.location(in: view))
            case .ended, .cancelled, .failed:
                touched.removeAll()
            default:
                break
            }
        }

        func hit(at point: CGPoint) {
            for id in LibrarySelection.hitRowIDs(at: point, frames: parent.frames, selectable: parent.selectable) {
                if touched.insert(id).inserted {
                    parent.onTouchRow(id)
                }
            }
        }
    }
}

private struct ArchiveSelectionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.frame(minWidth: HitTarget.minimum, minHeight: HitTarget.minimum)
            .contentShape(Rectangle()).opacity(configuration.isPressed ? 0.6 : 1)
    }
}

private extension View {
    @ViewBuilder func selectionBarBackground() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            background(Color.paper)
        }
    }
}
