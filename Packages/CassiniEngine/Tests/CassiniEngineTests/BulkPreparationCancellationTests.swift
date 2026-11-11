import CassiniCore
import CassiniNotebook
import CassiniEngineTesting
import Foundation
import Synchronization
import Testing
@testable import CassiniEngine

struct BulkPreparationCancellationTests {
    @Test func cancellationDuringPortableScanningStopsBeforeTheNextSourceRead() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-scan-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("English synthetic.opus")
        let bytes = try ImportFixtures.opus(packets: 5_000)
        try Data(bytes).write(to: input)
        let firstRead = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let successfulReads = ReadCount()
        defer { release.signal(); firstRead.continuation.finish() }
        let work = Task {
            try await ImportService.blocking {
                let source = FirstReadGate(source: try FileSource(input), reads: successfulReads) {
                    firstRead.continuation.yield(())
                    release.wait()
                }
                _ = try OggOpus.scan(source)
            }
        }
        for await _ in firstRead.stream { break }
        work.cancel()
        release.signal()
        await #expect(throws: CancellationError.self) { try await work.value }
        #expect(successfulReads.count == 1, "Cancellation reaches the actual file scan, rather than waiting for EOF")
        #expect(try Data(contentsOf: input) == Data(bytes))
    }

    @Test func anUnrepresentableReportedArchiveSpaceRequirementIsRejectedBeforeReading() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-size-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("does-not-need-to-exist.zip")
        let destination = folder.appendingPathComponent("copied.zip")
        let files = CoordinatedFileImporter(storage: FakeStorage(availableBytes: Int64.max), sizeOf: { _ in Int64.max })
        await #expect(throws: FileImportError.noSpace(bytesNeeded: Int64.max)) {
            try await files.copy(from: source, to: destination, maxBytes: Int64.max, reserveBytes: Limits.minFreeImportBytes)
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }
}

private final class FirstReadGate: ByteSource {
    let source: FileSource
    let reads: ReadCount
    let first: @Sendable () -> Void
    init(source: FileSource, reads: ReadCount, first: @escaping @Sendable () -> Void) {
        self.source = source; self.reads = reads; self.first = first
    }
    func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) throws -> Int {
        let result = try source.read(into: buffer, count: count)
        let initial = reads.next()
        if initial { first() }
        return result
    }
}

private final class ReadCount: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func next() -> Bool { value.withLock { $0 += 1; return $0 == 1 } }
}
