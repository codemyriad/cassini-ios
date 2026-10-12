import Foundation

/// Wall-clock time for dates the app stores and shows. Named `AppClock` because Swift's `Clock` is a different protocol.
public protocol AppClock: Sendable {
    var now: Date { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemClock: AppClock {
    public init() {}
    public var now: Date { Date() }
    public func sleep(for duration: Duration) async throws { try await Task.sleep(for: duration) }
}
