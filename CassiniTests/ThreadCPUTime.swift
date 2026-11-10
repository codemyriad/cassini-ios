import Foundation

/// CPU consumed on the calling thread, excluding scheduler delays and the work of other threads: what a step costs
/// the thread it runs on (the main actor's part of a frame), however busy the machine is. Only for synchronous work
/// that stays on the calling thread. The XCTest twin of CassiniNotebookTests' `measureThreadCPU` (swift-testing),
/// copied rather than shared: neither test target can import the other, and a shared module for ten lines would
/// put a test framework into a package product.
struct ThreadCPUClockUnavailable: Error {}

func measureThreadCPU<Value>(_ operation: () throws -> Value) throws -> (value: Value, elapsed: Duration) {
    func now() throws -> Duration {
        var time = timespec()
        guard clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time) == 0 else { throw ThreadCPUClockUnavailable() }
        return .seconds(time.tv_sec) + .nanoseconds(time.tv_nsec)
    }

    let started = try now()
    let value = try operation()
    return (value, try now() - started)
}
