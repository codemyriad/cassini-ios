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

@Suite(.timeLimit(.minutes(1))) struct FileWorkCancellationTests {
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
