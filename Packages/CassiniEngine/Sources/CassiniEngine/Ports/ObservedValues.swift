import Observation
import Synchronization

/// The values of an observed expression, for `for await`: the current value first, then the value again after each
/// change of what it read, with the changes made in one main-actor turn coalesced into one value. It ends when the
/// iterating task is cancelled; the observed objects are held only while it is iterated.
///
/// On iOS 26 and macOS 26 it is the system's `Observations`, unchanged. Below that it is `withObservationTracking`,
/// tracked again after each read: the change is noticed when it starts, and the value is read on the main actor
/// after the change has been made.
struct ObservedValues<Element: Sendable>: AsyncSequence {
    typealias Failure = Never

    private let source: ObservationSource
    private let value: @MainActor @Sendable () -> Element

    init(using source: ObservationSource = .system, _ value: @escaping @MainActor @Sendable () -> Element) {
        self.source = source
        self.value = value
    }

    func makeAsyncIterator() -> Iterator {
        if source == .observations, #available(iOS 26.0, macOS 26.0, *) {
            return Iterator(base: Observations(value).makeAsyncIterator())
        }
        return Iterator(base: TrackingIterator(value: value))
    }

    struct Iterator: AsyncIteratorProtocol {
        fileprivate var base: any AsyncIteratorProtocol<Element, Never>

        mutating func next(isolation actor: isolated (any Actor)? = #isolation) async -> Element? {
            await base.next(isolation: actor)
        }

        mutating func next() async -> Element? { await next(isolation: nil) }
    }
}

/// Which implementation delivers `ObservedValues`; tests run both on the macOS host.
enum ObservationSource: Sendable, CaseIterable {
    case observations, tracking

    static var system: ObservationSource {
        if #available(iOS 26.0, macOS 26.0, *) { .observations } else { .tracking }
    }
}

/// The iOS 18 values: each read is tracked, and the next one waits for a change of what it read.
private struct TrackingIterator<Element: Sendable>: AsyncIteratorProtocol {
    let value: @MainActor @Sendable () -> Element
    private let signal = ChangeSignal()
    private var started = false

    init(value: @escaping @MainActor @Sendable () -> Element) { self.value = value }

    mutating func next(isolation actor: isolated (any Actor)? = #isolation) async -> Element? {
        if started {
            guard await signal.changed() else { return nil }
        } else {
            guard !Task.isCancelled else { return nil }
            started = true
        }
        return await MainActor.run { [value, signal] in
            // Weak: a registration whose change never comes keeps nothing of an ended iteration alive.
            withObservationTracking { value() } onChange: { [weak signal] in signal?.fire() }
        }
    }

    mutating func next() async -> Element? { await next(isolation: nil) }
}

/// A change noticed by the tracking, waited for by the next read.
private final class ChangeSignal: Sendable {
    private struct State {
        var pending = false
        var cancelled = false
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let state = Mutex(State())

    func fire() {
        let waiter = state.withLock { state in
            guard let waiter = state.waiter else { state.pending = true; return nil as CheckedContinuation<Bool, Never>? }
            state.waiter = nil
            return waiter
        }
        waiter?.resume(returning: true)
    }

    /// True once what the last read read has changed; false when the task is cancelled.
    func changed() async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let now: Bool? = state.withLock { state in
                    if state.cancelled { return false }
                    if state.pending { state.pending = false; return true }
                    state.waiter = continuation
                    return nil
                }
                if let now { continuation.resume(returning: now) }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.cancelled = true
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(returning: false)
        }
    }
}
