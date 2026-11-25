import SwiftUI
import UIKit
import CassiniEngine
import CassiniNotebook

/// The Select button on the Library filter row: enters selection mode in the normal text colour.
struct ArchiveExportControls: View {
    @Environment(LibraryStore.self) private var library
    @Binding var editMode: EditMode

    var body: some View {
        if library.notes.contains(where: { !$0.isRecording }) {
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
        library.notes.filter { ArchiveSelection.isExportable($0) && selectedNotes.contains($0.id) }.map(\.id)
    }

    private var deletableSelected: [UUID] {
        library.notes.filter { !$0.isRecording && selectedNotes.contains($0.id) }.map(\.id)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(LibraryCopy.selectAll) {
                selectedNotes.formUnion(selectableIDs)
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
            guard let view = referenceView else { return }
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

        private func hit(at point: CGPoint) {
            for (id, rect) in parent.frames where parent.selectable.contains(id) && rect.contains(point) {
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
