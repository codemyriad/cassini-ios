import Foundation

/// Synchronous file/codec work on a GCD executor, with a real Swift task context. Cancellation therefore reaches
/// Task.checkCancellation() inside PCM/Ogg loops; blocking I/O does not occupy the cooperative executor.
public enum CancellableFileWork {
    private final class Executor: TaskExecutor, @unchecked Sendable {
        static let user = Executor(.userInitiated)
        static let utility = Executor(.utility)
        let queue: DispatchQueue
        init(_ qos: DispatchQoS.QoSClass) { queue = .global(qos: qos) }
        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
        }
    }

    public static func run<T: Sendable>(priority: TaskPriority = .userInitiated,
                                        _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        // A real, non-nil preference also avoids the iOS18 nil-executor runtime trap.
        let executor = priority == .utility || priority == .background ? Executor.utility : Executor.user
        return try await run(executor: executor, priority: priority, operation)
    }

    // Internal executor seam makes cancellation at enqueue deterministic in tests.
    static func run<T: Sendable>(executor: any TaskExecutor, priority: TaskPriority = .userInitiated,
                                 _ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        do {
            return try await withThrowingTaskGroup(of: T.self) { group in
                // Structured registration precedes enqueue, so cancellation cannot miss a fast worker.
                group.addTask(executorPreference: executor, priority: priority) {
                    try Task.checkCancellation()
                    return try operation()
                }
                guard let value = try await group.next() else { throw CancellationError() }
                try Task.checkCancellation()
                return value
            }
        } catch {
            try Task.checkCancellation()
            throw error
        }
    }
}
