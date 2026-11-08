import Foundation
import Synchronization

/// The signed bundle is immutable for this process. Concurrent callers share one utility-queue verification.
public final class WhistleBundleVerification: Sendable {
    private struct State {
        var tasks: [URL: Task<Bool, Never>] = [:]
        var results: [URL: Bool] = [:]
    }
    private let state = Mutex(State())
    private let check: @Sendable (URL) -> Bool
    public init(check: @escaping @Sendable (URL) -> Bool) { self.check = check }

    /// Lookup only: no resource reads, hashing or native loading.
    public func cached(_ url: URL) -> Bool? { state.withLock { $0.results[url] } }

    public func verify(_ url: URL) async -> Bool {
        let task = state.withLock { value -> Task<Bool, Never> in
            if let task = value.tasks[url] { return task }
            let task = Task { [self] in
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async { [self] in
                        let result = check(url)
                        state.withLock { $0.results[url] = result }
                        continuation.resume(returning: result)
                    }
                }
            }
            value.tasks[url] = task
            return task
        }
        return await task.value
    }
}
