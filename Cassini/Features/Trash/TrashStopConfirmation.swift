import SwiftUI
import CassiniEngine

extension View {
    /// "Stop transcription and move to Recently Deleted?" for a note whose transcription runs, from any screen.
    func trashStopConfirmation() -> some View { modifier(TrashStopConfirmation()) }
}

private struct TrashStopConfirmation: ViewModifier {
    @Environment(TrashService.self) private var trash

    func body(content: Content) -> some View {
        content.alert(TrashCopy.stopAndTrash,
                      isPresented: Binding(get: { trash.stopConfirmation != nil }, set: { if !$0 { trash.cancelStop() } }),
                      presenting: trash.stopConfirmation) { note in
            Button(TrashCopy.cancel, role: .cancel) {}
            Button(TrashCopy.moveToTrash, role: .destructive) { Task { await trash.confirmStop(note) } }
        } message: { _ in
            Text(TrashCopy.keptFor30Days)
        }
    }
}
