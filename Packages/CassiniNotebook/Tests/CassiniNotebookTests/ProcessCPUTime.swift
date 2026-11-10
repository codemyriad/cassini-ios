import Foundation
import Testing

/// CPU consumed by this test process, excluding time descheduled behind a cold build or another host task.
/// Other tests running in this process still count, so the long-transcript budget remains conservative.
func measureProcessCPU<Value>(_ operation: () throws -> Value) throws -> (value: Value, elapsed: Duration) {
    func now() throws -> Duration {
        var time = timespec()
        try #require(clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &time) == 0, "process CPU clock unavailable")
        return .seconds(time.tv_sec) + .nanoseconds(time.tv_nsec)
    }

    let started = try now()
    let value = try operation()
    return (value, try now() - started)
}
