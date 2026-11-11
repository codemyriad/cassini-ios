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
        let worker = Task.detached(executorPreference: executor, priority: priority) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            do {
                let value = try await worker.value
                try Task.checkCancellation()
                return value
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: { worker.cancel() }
    }
}
