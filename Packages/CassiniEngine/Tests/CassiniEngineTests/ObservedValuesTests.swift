import Observation
import Testing
@testable import CassiniEngine

/// Both implementations of `ObservedValues` behave as the followers of `ModelInstalls` and `NoticeCenter` rely on:
/// the system's `Observations` (iOS 26) and the `withObservationTracking` loop (iOS 18), which the macOS host would
/// otherwise never run.
@MainActor @Suite(.timeLimit(.minutes(1))) struct ObservedValuesTests {
    @MainActor @Observable final class Counter {
        var count = 0
        var other = 0
        @ObservationIgnored var reads = 0
    }

    /// A follower that reports each value it receives, as the app's followers act on each one.
    private func follow(_ counter: Counter, using source: ObservationSource)
        -> (values: AsyncStream<Int>.Iterator, task: Task<Void, Never>) {
        let (values, report) = AsyncStream.makeStream(of: Int.self)
        let task = Task { @MainActor in
            for await value in ObservedValues(using: source, { counter.reads += 1; return counter.count }) {
                report.yield(value)
            }
            report.finish()
        }
        return (values.makeAsyncIterator(), task)
    }

    @Test(arguments: ObservationSource.allCases)
    func theFirstValueIsTheCurrentOneWithoutAnyChange(source: ObservationSource) async {
        let counter = Counter()
        counter.count = 7
        var values = ObservedValues(using: source) { counter.count }.makeAsyncIterator()
        #expect(await values.next(isolation: #isolation) == 7)
    }

    @Test(arguments: ObservationSource.allCases)
    func eachChangeArrivesOnceInOrderAndNothingArrivesWithoutOne(source: ObservationSource) async {
        let counter = Counter()
        var (values, task) = follow(counter, using: source)
        #expect(await values.next(isolation: #isolation) == 0)
        for count in 1...3 {
            // The follower gets main-actor turns without a change: a busy loop would read again in each.
            for _ in 0..<10 { await Task.yield() }
            #expect(counter.reads == count, "one read per value, none without a change")
            counter.count = count
            #expect(await values.next(isolation: #isolation) == count)
        }
        task.cancel()
        #expect(await followerEnded(&values, task))
    }

    @Test(arguments: ObservationSource.allCases)
    func changesMadeInOneTurnArriveAsTheLatestValue(source: ObservationSource) async {
        let counter = Counter()
        var (values, task) = follow(counter, using: source)
        #expect(await values.next(isolation: #isolation) == 0)
        counter.count = 1
        counter.count = 2
        counter.count = 3
        #expect(await values.next(isolation: #isolation) == 3)
        counter.count = 4
        #expect(await values.next(isolation: #isolation) == 4)
        task.cancel()
        #expect(await followerEnded(&values, task))
    }

    /// As the install followers do, which await work in their loop body: a change made after a value arrives and
    /// before the follower asks for the next one is delivered at that next one. The follower makes the change itself,
    /// on the main actor, so it always lands before the wait.
    @Test(arguments: ObservationSource.allCases)
    func aChangeMadeBeforeTheNextWaitIsDeliveredThen(source: ObservationSource) async {
        let counter = Counter()
        let (stream, report) = AsyncStream.makeStream(of: Int.self)
        let task = Task { @MainActor in
            for await value in ObservedValues(using: source, { counter.count }) {
                if value == 0 { counter.count = 1 }
                report.yield(value)
            }
            report.finish()
        }
        var values = stream.makeAsyncIterator()
        #expect(await values.next(isolation: #isolation) == 0)
        #expect(await values.next(isolation: #isolation) == 1)
        task.cancel()
        #expect(await followerEnded(&values, task))
    }

    @Test(arguments: ObservationSource.allCases)
    func aChangeOfSomethingNotReadDeliversNothing(source: ObservationSource) async {
        let counter = Counter()
        var (values, task) = follow(counter, using: source)
        #expect(await values.next(isolation: #isolation) == 0)
        counter.other = 1
        counter.count = 1
        #expect(await values.next(isolation: #isolation) == 1)
        task.cancel()
        #expect(await followerEnded(&values, task))
    }

    /// Waits for `events` to end, the end of the follower that feeds it. A follower that never ends fails at the
    /// suite's time limit, which cancels the wait, rather than hanging the run.
    private func followerEnded<T>(_ events: inout AsyncStream<T>.Iterator, _ task: Task<Void, Never>) async -> Bool {
        while await events.next(isolation: #isolation) != nil {}
        guard !Task.isCancelled else { return false }
        await task.value // already ended: the stream finishes as the follower returns
        return true
    }

    @Test(arguments: ObservationSource.allCases)
    func cancellingTheFollowerEndsTheValuesAndReleasesTheObservedObject(source: ObservationSource) async {
        weak var released: Counter?
        var values: AsyncStream<Int>.Iterator
        var task: Task<Void, Never>
        do {
            let counter = Counter()
            released = counter
            (values, task) = follow(counter, using: source)
            #expect(await values.next(isolation: #isolation) == 0) // the follower now waits for a change
        }
        task.cancel()
        #expect(await followerEnded(&values, task))
        #expect(released == nil)
    }

    /// As the app's followers are owned: `[weak self]`, cancelled in the owner's isolated deinit. `events` has an
    /// element once the follower has its first value, and ends when the follower does.
    @MainActor final class Owner {
        private(set) var follower: Task<Void, Never>!
        private(set) var changes = 0
        let events: AsyncStream<Void>

        init(observing counter: Counter, using source: ObservationSource) {
            let (events, event) = AsyncStream.makeStream(of: Void.self)
            self.events = events
            follower = Task { [weak self] in
                var previous: Int?
                for await count in ObservedValues(using: source, { counter.count }) {
                    defer { previous = count }
                    guard previous != nil else { event.yield(); continue }
                    guard let self else { break }
                    self.changes += 1
                }
                event.finish()
            }
        }

        isolated deinit { follower.cancel() }
    }

    @Test(arguments: ObservationSource.allCases)
    func droppingTheOwnerEndsItsFollowerAndReleasesBothObjects(source: ObservationSource) async {
        weak var releasedCounter: Counter?
        weak var releasedOwner: Owner?
        var events: AsyncStream<Void>.Iterator
        var follower: Task<Void, Never>
        do {
            let counter = Counter()
            let owner = Owner(observing: counter, using: source)
            releasedCounter = counter
            releasedOwner = owner
            follower = owner.follower
            events = owner.events.makeAsyncIterator()
            #expect(await events.next(isolation: #isolation) != nil)
        }
        #expect(releasedOwner == nil)
        #expect(await followerEnded(&events, follower))
        #expect(releasedCounter == nil)
    }
}
