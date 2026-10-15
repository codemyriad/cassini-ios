import Foundation
import Synchronization

/// One dedicated thread at `.userInitiated` that runs native inference, one body at a time and never on the Swift
/// cooperative pool: a decode blocks its thread for seconds, and the native objects stay on the thread that made them.
final class InferenceThread: Sendable {
    /// The process's speech thread: one decode runs at a time, whatever job asks.
    static let speech = InferenceThread(name: "Cassini speech")

    /// The bodies waiting to run; the thread holds it, not the `InferenceThread`.
    private final class Queue: Sendable {
        let pending = Mutex<[@Sendable () -> Void]>([])
        let wake = DispatchSemaphore(value: 0)
    }

    private let queue = Queue()

    init(name: String) {
        let thread = Thread { [queue] in
            while true {
                queue.wake.wait()
                let body = queue.pending.withLock { $0.isEmpty ? nil : $0.removeFirst() }
                body?()
            }
        }
        thread.name = name
        thread.qualityOfService = .userInitiated
        // The decode rules recurse little, but the native runtime's own frames are deep.
        thread.stackSize = 8 << 20
        thread.start()
    }

    /// Runs `body` on the thread and returns what it returned or threw.
    func run<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.pending.withLock { $0.append { continuation.resume(with: Result { try body() }) } }
            queue.wake.signal()
        }
    }
}

/// A flag the thread reads between native calls; set from a task's cancellation handler.
final class CancelFlag: Sendable {
    private let state = Mutex(false)
    var isSet: Bool { state.withLock { $0 } }
    func set() { state.withLock { $0 = true } }

    /// Throws `CancellationError` once set.
    func check() throws { if isSet { throw CancellationError() } }
}
