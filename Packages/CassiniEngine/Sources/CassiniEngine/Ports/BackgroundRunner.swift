import Foundation

public struct BackgroundToken: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID = UUID()) { self.id = id }
}

/// Time to finish work after the app leaves the screen.
@MainActor public protocol BackgroundRunner: AnyObject {
    /// `onExpire` runs synchronously when iOS takes the time back; the runner ends the token right after it, before
    /// iOS's handler returns. Anything `onExpire` starts may never run before the app is suspended or killed, so what
    /// must survive has to be stored before it returns.
    func begin(title: String, progress: Progress, onExpire: @escaping @MainActor () -> Void) -> BackgroundToken
    /// Gives the work of a token that has not ended a new title, as when the next job of a queue starts in it.
    func update(_ token: BackgroundToken, title: String)
    /// Ends the token; ending one twice, or after it expired, does nothing.
    func end(_ token: BackgroundToken)
}
