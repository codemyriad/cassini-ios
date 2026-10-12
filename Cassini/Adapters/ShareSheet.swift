import SwiftUI

/// The system share sheet for one file. `onComplete` runs once the sheet is done with the file, whether it was shared
/// or cancelled.
struct ShareSheet: UIViewControllerRepresentable {
    let item: ShareItem

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [item.url], applicationActivities: nil)
        let onComplete = item.onComplete
        controller.completionWithItemsHandler = { _, _, _, _ in MainActor.assumeIsolated { onComplete?() } }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// A file offered through the share sheet. A file made only for sharing (an export) is removed in `onComplete`; a
/// note's own audio has none.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
    var onComplete: (@MainActor () -> Void)?
}
