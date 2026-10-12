import Foundation

public struct BackgroundToken: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

/// Time to finish work after the app leaves the screen.
@MainActor public protocol BackgroundRunner: AnyObject {
    /// `onExpire` runs synchronously when iOS takes the time back; the runner ends the token right after it.
    func begin(title: String, progress: Progress, onExpire: @escaping @MainActor () -> Void) -> BackgroundToken
    /// Ends the token; ending one twice, or after it expired, does nothing.
    func end(_ token: BackgroundToken)
}
