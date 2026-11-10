import Foundation
import Testing

/// CPU consumed on the calling thread, excluding scheduler delays and concurrent tests on other threads.
/// Only use for synchronous, single-threaded work: CPU consumed by worker threads is intentionally excluded.
func measureThreadCPU<Value>(_ operation: () throws -> Value) throws -> (value: Value, elapsed: Duration) {
    func now() throws -> Duration {
        var time = timespec()
        try #require(clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0, "thread CPU clock unavailable")
        return .seconds(time.tv_sec) + .nanoseconds(time.tv_nsec)
    }

    let started = try now()
    let value = try operation()
    return (value, try now() - started)
}
