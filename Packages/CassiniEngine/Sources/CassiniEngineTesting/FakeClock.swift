#if DEBUG
import Foundation
import Synchronization
import CassiniEngine

/// A clock that moves only when told to; `sleep` moves it forward and returns at once.
public final class FakeClock: AppClock {
    private let current: Mutex<Date>

    public init(now: Date = Date(timeIntervalSince1970: 1_791_366_060)) { current = Mutex(now) }

    public var now: Date { current.withLock { $0 } }

    public func advance(by duration: Duration) {
        current.withLock { $0 += TimeInterval(duration.components.seconds) + TimeInterval(duration.components.attoseconds) / 1e18 }
    }

    public func set(_ date: Date) { current.withLock { $0 = date } }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        advance(by: duration)
    }
}

/// A clock whose `now` stands still while `sleep` takes real time, so UI-test launches show the same dates every run.
public struct FixedClock: AppClock {
    public let now: Date
    public init(now: Date) { self.now = now }
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
#endif
