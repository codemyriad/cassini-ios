#if DEBUG
import Foundation
import CassiniEngine

@MainActor public final class FakeBackgroundRunner: BackgroundRunner {
    private var active: [BackgroundToken: @MainActor () -> Void] = [:]
    public private(set) var endedCount = 0
    /// Every token begun so far.
    public private(set) var begunCount = 0
    /// The title of each token that has not ended.
    public private(set) var titles: [BackgroundToken: String] = [:]

    public init() {}

    public var activeCount: Int { active.count }

    public func begin(title: String, progress: Progress, onExpire: @escaping @MainActor () -> Void) -> BackgroundToken {
        let token = BackgroundToken()
        active[token] = onExpire
        titles[token] = title
        begunCount += 1
        return token
    }

    public func update(_ token: BackgroundToken, title: String) {
        if active[token] != nil { titles[token] = title }
    }

    public func end(_ token: BackgroundToken) {
        titles[token] = nil
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
