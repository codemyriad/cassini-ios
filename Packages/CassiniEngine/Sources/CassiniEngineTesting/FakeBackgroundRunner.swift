#if DEBUG
import Foundation
import CassiniEngine

@MainActor public final class FakeBackgroundRunner: BackgroundRunner {
    private var active: [BackgroundToken: @MainActor () -> Task<Void, Never>?] = [:]
    public private(set) var endedCount = 0
    /// Every token begun so far.
    public private(set) var begunCount = 0
    /// The title of each token that has not ended.
    public private(set) var titles: [BackgroundToken: String] = [:]

    public init() {}

    public var activeCount: Int { active.count }

    public func begin(title: String, progress: Progress,
                      onExpire: @escaping @MainActor () -> Task<Void, Never>?) -> BackgroundToken {
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

    /// Takes the background time back, as iOS does: every token's work learns of it before this suspends, and each
    /// token ends once what its work said must still land has landed. Nothing the work leaves to run after that is
    /// awaited, as iOS suspends the app then.
    public func expireAll() async {
        let expiring = active
        let landing = expiring.mapValues { $0() }
        for (token, work) in landing {
            await work?.value
            end(token)
        }
    }
}
#endif
