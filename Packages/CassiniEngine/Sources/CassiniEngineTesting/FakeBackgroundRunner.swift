#if DEBUG
import Foundation
import CassiniEngine

@MainActor public final class FakeBackgroundRunner: BackgroundRunner {
    private var active: [BackgroundToken: @MainActor () -> Void] = [:]
    public private(set) var endedCount = 0
    /// The token finished: an event for tests that must wait for its owner to release background time.
    public var onEnd: @MainActor (BackgroundToken) -> Void = { _ in }
    /// Every token begun so far.
    public private(set) var begunCount = 0
    /// The title of each token that has not ended.
    public private(set) var titles: [BackgroundToken: String] = [:]
    /// The subtitle of each token that has not ended.
    public private(set) var subtitles: [BackgroundToken: String] = [:]
    /// The progress of each token that has not ended, as iOS would show it.
    public private(set) var progresses: [BackgroundToken: Progress] = [:]

    public init() {}

    public var activeCount: Int { active.count }

    public func begin(title: String, subtitle: String, progress: Progress,
                      onExpire: @escaping @MainActor () -> Void) -> BackgroundToken {
        let token = BackgroundToken()
        active[token] = onExpire
        titles[token] = title
        subtitles[token] = subtitle
        progresses[token] = progress
        begunCount += 1
        return token
    }

    public func update(_ token: BackgroundToken, title: String) {
        if active[token] != nil { titles[token] = title }
    }

    public func end(_ token: BackgroundToken) {
        titles[token] = nil
        subtitles[token] = nil
        progresses[token] = nil
        if active.removeValue(forKey: token) != nil {
            endedCount += 1
            onEnd(token)
        }
    }

    /// Takes the background time back, as iOS does: each token's work learns of it and the token ends right after,
    /// before this returns. Nothing the work started from its handler has run yet, as when iOS suspends or kills the
    /// app at that point.
    public func expireAll() {
        for (token, onExpire) in active {
            onExpire()
            end(token)
        }
    }
}
#endif
