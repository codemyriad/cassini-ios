import Foundation

/// Runs main-actor sections one after another, in the order they asked, even across their suspension points.
@MainActor final class SerialLock {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Whether a section runs now, and how many wait for it: what a test waits on instead of sleeping.
    var isBusy: Bool { busy }
    var waiting: Int { waiters.count }

    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }
}

/// Something that happens once; waiting after it happened returns at once.
@MainActor final class OneShot {
    private(set) var happened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        guard !happened else { return }
        happened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait() async {
        if happened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
