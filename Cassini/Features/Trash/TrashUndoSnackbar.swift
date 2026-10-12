import SwiftUI
import CassiniEngine
import CassiniNotebook

extension View {
    /// The Library's "“title” moved to Recently Deleted" snackbar with Undo, 24 pt above whatever the screen insets
    /// at the bottom after it (the capture bar).
    func trashUndoSnackbar() -> some View { modifier(TrashUndoSnackbar()) }
}

/// Shows each note moved to Recently Deleted once, for 10 s (30 s with VoiceOver), and says it to VoiceOver.
private struct TrashUndoSnackbar: ViewModifier {
    @Environment(TrashUndo.self) private var undo
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let snackbar = undo.snackbar {
                    Snackbar(message: TrashCopy.moved(snackbar.note.title), actionTitle: TrashCopy.undo) { undo.undo() }
                        .padding(.horizontal, 16).padding(.bottom, 24)
                        .frame(maxWidth: ReadableWidth.library).frame(maxWidth: .infinity)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .task(id: snackbar.id) {
                            // A task cancelled as the screen changes starts again and waits only for the time left.
                            guard (try? await Task.sleep(until: snackbar.deadline, clock: .continuous)) != nil else { return }
                            undo.timedOut(snackbar.id)
                        }
                        .accessibilityIdentifier("trashUndoSnackbar")
                }
            }
            .animation(.snappy, value: undo.snackbar)
            // A move from the Note screen offers the note while the Library is still covered: it shows on arrival.
            .onAppear(perform: showPending)
            .onChange(of: undo.pending) { showPending() }
    }

    private func showPending() {
        guard undo.pending != nil else { return }
        undo.showPending(duration: TrashPolicy.undoDuration(voiceOverRunning: voiceOver))
        if let snackbar = undo.snackbar { AccessibilityNotification.Announcement(TrashCopy.moved(snackbar.note.title)).post() }
    }
}
