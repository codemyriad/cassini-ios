import SwiftUI
import CassiniEngine

/// The system share sheet for one file. It closes once an activity has shared the file or the user closed it without
/// picking one; backing out of an activity (Mail, Messages, an extension) returns to the sheet with the file still
/// offered.
struct ShareSheet: UIViewControllerRepresentable {
    let item: ShareItem

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
        let dismiss = context.environment.dismiss
        controller.completionWithItemsHandler = { activity, completed, _, _ in
            MainActor.assumeIsolated { if Self.closes(activity: activity, completed: completed) { dismiss() } }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    /// Whether a call of the completion handler ends the sheet: an activity finished, or there was none. Since iOS 13
    /// the handler also runs, with an activity and `completed == false`, when the user backs out of that activity.
    static func closes(activity: UIActivity.ActivityType?, completed: Bool) -> Bool { completed || activity == nil }
}

/// The item on screen in a share sheet, so the sheet's dismissal knows which one it ended.
struct ShareSession {
    private(set) var shown: ShareItem?

    mutating func present(_ item: ShareItem) { shown = item }

    /// The item whose sheet was just dismissed, `current` being what the sheet is bound to now; nil when the shown
    /// item is still the one bound (a new sheet already replaced the old one).
    mutating func dismiss(current: ShareItem?) -> ShareItem? {
        guard let item = shown, item.id != current?.id else { return nil }
        shown = nil
        return item
    }
}

extension View {
    /// Presents `item` in the share sheet and runs its `onComplete` once the sheet is dismissed, however it closed.
    func shareSheet(item: Binding<ShareItem?>) -> some View { modifier(ShareSheetPresenter(item: item)) }
}

private struct ShareSheetPresenter: ViewModifier {
    @Binding var item: ShareItem?
    @State private var session = ShareSession()
    #if DEBUG
    @State private var completedDismissal: UUID?
    #endif

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) {
                #if DEBUG
                if let completedDismissal, item == nil {
                    UITestStateMarker(identifier: "shareDismissalCompleted", value: completedDismissal.uuidString)
                }
                #endif
            }
            .sheet(item: $item, onDismiss: {
                guard let dismissed = session.dismiss(current: item) else { return }
                dismissed.onComplete?()
                #if DEBUG
                completedDismissal = dismissed.id
                #endif
            }) { item in
                ShareSheet(item: item).onAppear {
                    session.present(item)
                    #if DEBUG
                    // A later export must await its own dismissal, never a previous sheet's event.
                    completedDismissal = nil
                    #endif
                }
            }
    }
}
