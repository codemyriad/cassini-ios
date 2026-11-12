import Foundation
import Synchronization
import Testing
@testable import CassiniEngine

/// A multicast change notification for mutex-protected fakes. Register before reading the predicate; the initial
/// notification covers changes before registration, and the buffered notification covers changes before next().
final class ModelInstallTestEvents: Sendable {
    struct Subscription: Sendable {
        let id: UUID
        let values: AsyncStream<Void>
    }
    private struct State {
        var finished = false
        var subscribers: [UUID: AsyncStream<Void>.Continuation] = [:]
    }
    private let state = Mutex(State())

    func subscribe() -> Subscription {
        let id = UUID()
        let (values, output) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        output.onTermination = { [weak self] _ in self?.remove(id) }
        let finished = state.withLock { state in
            guard !state.finished else { return true }
            state.subscribers[id] = output
            return false
        }
        if finished { output.finish() } else { output.yield(()) }
        return Subscription(id: id, values: values)
    }

    func signal() {
        let outputs = state.withLock { Array($0.subscribers.values) }
        for output in outputs { output.yield(()) }
    }

    func remove(_ id: UUID) {
        let output = state.withLock { $0.subscribers.removeValue(forKey: id) }
        output?.finish()
    }

    func finish() {
        let outputs = state.withLock { state in
            state.finished = true
            let outputs = Array(state.subscribers.values)
            state.subscribers.removeAll()
            return outputs
        }
        for output in outputs { output.finish() }
    }

    var subscribers: Int { state.withLock { $0.subscribers.count } }

    deinit { finish() }
}

/// Observes real ModelInstalls publications, including the diagnostic end/follower events. Reading the end counter
/// also wakes a wait on isInstalling, whose task handle deliberately remains observation-ignored in production.
@MainActor func until(_ installs: ModelInstalls, _ condition: @escaping @MainActor @Sendable () -> Bool) async throws {
    for await ready in ObservedValues({
        _ = installs.installsEnded
        _ = installs.downloadsFollowed
        return condition()
    }) {
        try Task.checkCancellation()
        if ready { return }
    }
    try Task.checkCancellation()
    throw ModelInstallWaitEnded()
}

@MainActor func until(_ events: ModelInstallTestEvents, _ condition: @MainActor () -> Bool) async throws {
    let subscription = events.subscribe()
    defer { events.remove(subscription.id) }
    for await _ in subscription.values {
        try Task.checkCancellation()
        if condition() { return }
    }
    try Task.checkCancellation()
    throw ModelInstallWaitEnded()
}

private struct ModelInstallWaitEnded: Error {}

@MainActor @Suite(.timeLimit(.minutes(1))) struct ModelInstallTestEventsTests {
    @Test func theCurrentStateNeedsNoLaterChangeAndSuccessfulWaitsUnsubscribe() async throws {
        let events = ModelInstallTestEvents()
        events.signal()
        try await until(events) { true }
        #expect(events.subscribers == 0)
    }

    @Test func aChangeBetweenRegistrationAndTheNextWaitIsBuffered() async throws {
        let events = ModelInstallTestEvents()
        let subscription = events.subscribe()
        defer { events.remove(subscription.id) }
        var iterator = subscription.values.makeAsyncIterator()
        #expect(await iterator.next() != nil, "registration has an initial value")
        events.signal()
        #expect(await iterator.next() != nil, "a change before next() is not lost")
    }

    @Test func cancellingAnActuallyWaitingTaskRemovesItsSubscription() async throws {
        let events = ModelInstallTestEvents()
        let (entered, entry) = AsyncStream<Void>.makeStream()
        let task = Task { try await until(events) { entry.yield(()); return false } }
        defer { task.cancel(); entry.finish() }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        #expect(events.subscribers == 1)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(events.subscribers == 0)
    }

    @Test func anEndedEventSourceFailsTheWaitInsteadOfHanging() async throws {
        let events = ModelInstallTestEvents()
        let (entered, entry) = AsyncStream<Void>.makeStream()
        let task = Task { try await until(events) { entry.yield(()); return false } }
        defer { task.cancel(); entry.finish() }
        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()
        events.finish()
        await #expect(throws: ModelInstallWaitEnded.self) { try await task.value }
        #expect(events.subscribers == 0)
    }
}
