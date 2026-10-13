import Foundation

/// A file offered through the share sheet. A file made only for sharing (an export) is removed in `onComplete`,
/// which runs once the sheet is gone.
public struct ShareItem: Identifiable {
    public let id = UUID()
    public let url: URL
    public var onComplete: (@MainActor () -> Void)?

    public init(url: URL, onComplete: (@MainActor () -> Void)? = nil) {
        self.url = url
        self.onComplete = onComplete
    }
}
