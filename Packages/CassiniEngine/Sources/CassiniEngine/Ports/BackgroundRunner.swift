import Foundation

public struct BackgroundToken: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

/// Time to finish work after the app leaves the screen.
@MainActor public protocol BackgroundRunner: AnyObject {
    /// `onExpire` runs synchronously when iOS takes the time back, so the work stops before iOS's handler returns. It
    /// returns what must still land before the time ends (a write that the work paused, a notification), or nil. The
    /// runner holds the time until that ends, for at most a short grace, and then ends the token itself.
    func begin(title: String, progress: Progress, onExpire: @escaping @MainActor () -> Task<Void, Never>?) -> BackgroundToken
    /// Gives the work of a token that has not ended a new title, as when the next job of a queue starts in it.
    func update(_ token: BackgroundToken, title: String)
    /// Ends the token; ending one twice, or after it expired, does nothing.
    func end(_ token: BackgroundToken)
}
