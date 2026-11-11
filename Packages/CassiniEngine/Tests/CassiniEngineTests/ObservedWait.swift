import Foundation
@testable import CassiniEngine

private struct ObservedConditionTimeout: Error, CustomStringConvertible {
    let description: String
}

/// Reads immediately, then only when the condition's observed inputs change. The timer only fails a broken wait.
@MainActor func waitForObserved(_ what: String, _ condition: @escaping @MainActor @Sendable () -> Bool) async throws {
    let arrived = await withTaskGroup(of: Bool.self) { group in
        group.addTask { await observedConditionArrived(condition) }
        group.addTask {
            try? await Task.sleep(for: .seconds(30))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    guard arrived else { throw ObservedConditionTimeout(description: "No observed event for \(what)") }
}

@MainActor private func observedConditionArrived(_ condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
    for await satisfied in ObservedValues(condition) where satisfied { return true }
    return false
}
