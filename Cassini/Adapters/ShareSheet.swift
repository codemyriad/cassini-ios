import SwiftUI

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

/// A file offered through the share sheet.
struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
