import Foundation
import Synchronization
import Testing
@testable import CassiniWhistle

@MainActor @Suite struct WhistleBundleVerificationTests {
    @Test(.timeLimit(.minutes(1))) func concurrentReadersHashOnceOffMainAndLookupsNeverHash() async {
        let started = AsyncStream<Void>.makeStream(), release = DispatchSemaphore(value: 0)
        defer { release.signal(); started.continuation.finish() }
        let counts = Mutex((calls: 0, onMain: false))
        let cache = WhistleBundleVerification { url in
            counts.withLock { $0.calls += 1; $0.onMain = $0.onMain || Thread.isMainThread }
            if url.lastPathComponent == "good" { started.continuation.yield(()); release.wait() }
            return url.lastPathComponent == "good"
        }
        let url = URL(fileURLWithPath: "/immutable/good")
        #expect(cache.cached(url) == nil)
        #expect(counts.withLock { $0.calls } == 0)
        async let first = cache.verify(url)
        async let second = cache.verify(url)
        for await _ in started.stream { break }
        #expect(cache.cached(url) == nil)
        #expect(counts.withLock { $0.calls } == 1)
        release.signal()
        let a = await first, b = await second
        #expect(a && b)
        #expect(cache.cached(url) == true)
        #expect(await cache.verify(url))
        #expect(counts.withLock { $0.calls } == 1)
        #expect(!counts.withLock { $0.onMain })
        let bad = URL(fileURLWithPath: "/immutable/bad")
        #expect(await !cache.verify(bad))
        #expect(cache.cached(bad) == false)
        #expect(counts.withLock { $0.calls } == 2)
    }
}
