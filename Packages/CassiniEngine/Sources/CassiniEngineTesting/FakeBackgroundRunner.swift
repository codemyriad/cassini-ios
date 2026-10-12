#if DEBUG
import Foundation
import CassiniEngine

@MainActor public final class FakeBackgroundRunner: BackgroundRunner {
    private var active: [BackgroundToken: @MainActor () -> Void] = [:]
    public private(set) var endedCount = 0

    public init() {}

    public var activeCount: Int { active.count }

    public func begin(title: String, progress: Progress, onExpire: @escaping @MainActor () -> Void) -> BackgroundToken {
        let token = BackgroundToken()
        active[token] = onExpire
        return token
    }

    public func end(_ token: BackgroundToken) {
        if active.removeValue(forKey: token) != nil { endedCount += 1 }
    }

    /// Takes the background time back, as iOS does.
    public func expireAll() {
        for (token, onExpire) in active {
            onExpire()
            end(token)
        }
    }
}
#endif
