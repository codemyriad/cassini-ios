import Foundation
import Synchronization
import Testing
@testable import CassiniCore

private final class FileReadGate: Sendable {
    let counts = Mutex(0)
    let ready: AsyncStream<Void>
    let signal: AsyncStream<Void>.Continuation
    let release = DispatchSemaphore(value: 0)
    init() { (ready, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
    func read() {
        let first = counts.withLock { $0 += 1; return $0 == 1 }
        if first { signal.yield(()); signal.finish(); release.wait() }
    }
}

/// A real FileSource with a test event after the first read. It deliberately adds no cancellation check of its own.
private final class GatedOggFile: ByteSource {
    let file: FileSource
    let gate: FileReadGate
    init(_ url: URL, _ gate: FileReadGate) throws { file = try FileSource(url); self.gate = gate }
    func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) throws -> Int {
        let n = try file.read(into: buffer, count: count)
        if n > 0 { gate.read() }
        return n
    }
}

/// Executes the submitted job before enqueue returns, reproducing a fast worker starting before the parent
/// can register a later cancellation handler. Production still uses its GCD task executor.
private final class CancelAtEnqueue: TaskExecutor, @unchecked Sendable {
    let cancel: @Sendable () -> Void
    init(_ cancel: @escaping @Sendable () -> Void) { self.cancel = cancel }
    func enqueue(_ job: consuming ExecutorJob) {
        cancel()
        UnownedJob(job).runSynchronously(on: asUnownedTaskExecutor())
    }
}

@Suite(.timeLimit(.minutes(1))) struct FileWorkCancellationTests {
    @Test func cancellationAtEnqueuePreventsTheOperationFromStarting() async throws {
        let parent = Mutex<Task<Int, any Error>?>(nil)
        let ran = Mutex(false)
        let start = AsyncStream<Void>.makeStream()
        let executor = CancelAtEnqueue { parent.withLock { $0 }?.cancel() }
        let task = Task {
            for await _ in start.stream { break }
            return try await CancellableFileWork.run(executor: executor) { ran.withLock { $0 = true }; return 1 }
        }
        parent.withLock { $0 = task }
        start.continuation.yield(()); start.continuation.finish()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!ran.withLock { $0 }, "Cancellation at submission must reach the child before its operation starts")
    }

    @Test func cancelStopsActualOggFileReadsBeforeASecondChunk() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("English silence.opus")
        try Data(silence()).write(to: url)
        let gate = FileReadGate()
        defer { gate.release.signal() }
        let task = Task { try await CancellableFileWork.run { try OggOpus.scan(GatedOggFile(url, gate)) } }
        for await _ in gate.ready { break }
        task.cancel(); gate.release.signal()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(gate.counts.withLock { $0 } == 1)
    }
}
