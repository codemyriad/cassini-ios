import Foundation
import XCTest
import CassiniCore
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
@testable import Cassini

@MainActor final class BulkStoreTests: XCTestCase {
    func testPickerBatchAdoptsNotesCountsDuplicatesAndSharesOriginalAudioZIP() async throws {
        let test = TestGraph(audio: FakeAudioProcessing(duration: 1))
        defer { test.tearDown() }
        let graph = test.graph
        await graph.start()
        graph.settings.autoTranscribe = false
        let inputs = test.root.appendingPathComponent("test-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let first = inputs.appendingPathComponent("First English.wav")
        let second = inputs.appendingPathComponent("Second English.wav")
        let duplicate = inputs.appendingPathComponent("Duplicate English.wav")
        let unsupported = inputs.appendingPathComponent("Ignored.txt")
        let firstBytes = Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVEfmt ".utf8) + [1, 2, 3])
        let secondBytes = firstBytes + Data([4])
        try firstBytes.write(to: first)
        try secondBytes.write(to: second)
        try firstBytes.write(to: duplicate)
        try Data("English text, not audio".utf8).write(to: unsupported)
        let selectedArchive = inputs.appendingPathComponent("English collection.zip")
        try ZipArchive.write([ZipSource(url: first, name: "Archived English.wav"),
                              ZipSource(url: unsupported, name: "Ignored.txt")], to: selectedArchive)
        graph.imports.start([first, second, duplicate, selectedArchive])
        await graph.imports.settleBatch()
        let summary = try XCTUnwrap(graph.imports.batchSummary)
        XCTAssertEqual(summary.imported, 2)
        XCTAssertEqual(summary.duplicates, 2)
        XCTAssertEqual(summary.unsupported, 1)
        XCTAssertEqual(summary.failed, 0)
        XCTAssertNil(graph.imports.batchProgress)
        XCTAssertFalse(graph.imports.batchCancelled)
        XCTAssertTrue(graph.imports.batchArchiveFailures.isEmpty)
        let staging = test.root.appendingPathComponent(".bulk-imports", isDirectory: true)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).isEmpty,
                      "Only this run's UUID work directory is removed; the reusable staging parent stays")
        XCTAssertEqual(graph.library.notes.count, 2, "Batch outcomes must reach the real Library mirror")
        XCTAssertTrue(graph.router.path.isEmpty, "Picker imports do not open each note")

        let ids = graph.library.notes.map(\.id)
        graph.exports.exportZIP(ids)
        await graph.exports.settleZIP()
        XCTAssertNil(graph.exports.zipFailure)
        XCTAssertNil(graph.exports.zipProgress)
        XCTAssertEqual(graph.exports.zipExported, 2)
        let item = try XCTUnwrap(graph.exports.zipShareItem)
        let archive = try ZipArchive(url: item.url)
        XCTAssertEqual(archive.entries.count, 2)
        XCTAssertTrue(archive.entries.allSatisfy { $0.name.hasSuffix(".wav") })
        var exported: Set<Data> = []
        for (index, entry) in archive.entries.enumerated() {
            let destination = inputs.appendingPathComponent("extracted-\(index).wav")
            _ = try archive.extract(entry, to: destination, maxBytes: 65_536)
            exported.insert(try Data(contentsOf: destination))
        }
        XCTAssertEqual(exported, Set([firstBytes, secondBytes]))
        XCTAssertEqual(try Data(contentsOf: first), firstBytes)
        XCTAssertEqual(try Data(contentsOf: second), secondBytes)
        item.onComplete?()
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.url.path), "Share dismissal owns ZIP cleanup")
        XCTAssertEqual(graph.library.notes.count, 2)
    }

    func testASelectionMadeAfterCancellationSurvivesThePreviousTaskUnwinding() async throws {
        let test = TestGraph(audio: FakeAudioProcessing(duration: 1))
        defer { test.tearDown() }
        await test.graph.start()
        test.graph.settings.autoTranscribe = false
        let notes = try XCTUnwrap(test.graph.library.noteStore)
        let entered = expectation(description: "first batch entered its copy gate")
        let storage = FakeStorage()
        let files = FirstBatchCopyGate(base: CoordinatedFileImporter(storage: storage), entered: entered)
        let service = ImportService(notes: notes, files: files,
                                    audio: FakeAudioProcessing(duration: 1),
                                    storage: storage, clock: test.clock)
        let imports = ImportStore(service: service, library: test.graph.library, processing: test.graph.processing,
                                  settings: test.graph.settings, router: test.graph.router, clock: test.clock, ready: {})
        let inputs = test.root.appendingPathComponent("cancellation-inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let first = inputs.appendingPathComponent("First English.wav")
        let queuedBeforeCancel = inputs.appendingPathComponent("Old queued English.wav")
        let second = inputs.appendingPathComponent("Second English.wav")
        let bytes = Data(Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVEfmt ".utf8) + [1, 2, 3])
        for url in [first, queuedBeforeCancel, second] { try bytes.write(to: url) }
        imports.start([first])
        await fulfillment(of: [entered], timeout: 30)
        imports.start([queuedBeforeCancel])
        imports.cancelBatch()
        imports.start([second])
        await files.releaseFirstCopy()
        await imports.settleBatch()

        let requests = await files.requests
        XCTAssertEqual(requests, [first.lastPathComponent, second.lastPathComponent])
        XCTAssertEqual(imports.batchSummary?.imported, 1)
        XCTAssertEqual(imports.batchSummary?.failed, 0)
        XCTAssertFalse(imports.batchCancelled, "The new selection has its own successful summary")
        XCTAssertNil(imports.batchProgress)
        XCTAssertEqual(test.graph.library.notes.map(\.title), ["Second English"])
        XCTAssertEqual(try Data(contentsOf: first), bytes)
        XCTAssertEqual(try Data(contentsOf: second), bytes)
    }

    func testLaunchSweepsInterruptedBatchStagingBeforeIncomingImportsCanStart() async throws {
        let test = TestGraph(audio: FakeAudioProcessing(duration: 1))
        defer { test.tearDown() }
        let staging = test.root.appendingPathComponent(".bulk-imports", isDirectory: true)
        let interrupted = staging.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: interrupted, withIntermediateDirectories: true)
        try Data("partial English test archive".utf8).write(to: interrupted.appendingPathComponent("archive.zip"))
        await test.graph.start()
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertTrue(test.graph.library.notes.isEmpty)
    }

    func testCancelWhileBatchWaitsForLaunchDoesNotStartAnImportOrInventAFailure() async throws {
        let test = TestGraph()
        defer { test.tearDown() }
        let entered = expectation(description: "batch reached startup readiness gate")
        let release = AsyncStream<Void>.makeStream()
        defer { release.continuation.finish() }
        let imports = ImportStore(service: nil, library: test.graph.library, processing: test.graph.processing,
                                  settings: test.graph.settings, router: test.graph.router, clock: test.clock,
                                  ready: {
            entered.fulfill()
            for await _ in release.stream { break }
        })
        imports.start([test.root.appendingPathComponent("English meeting.wav")])
        await fulfillment(of: [entered], timeout: 30)
        imports.cancelBatch()
        release.continuation.yield(())
        await imports.settleBatch()
        XCTAssertTrue(imports.batchCancelled)
        XCTAssertNil(imports.batchProgress)
        XCTAssertEqual(imports.batchSummary?.imported, 0)
        XCTAssertEqual(imports.batchSummary?.failed, 0)
        XCTAssertTrue(test.graph.library.notes.isEmpty)
    }
}

/// Deliberately holds the first copy until an explicit event, even after cancellation. This exposes the window
/// where a new picker selection arrives before the old task's catch/defer has run.
private actor FirstBatchCopyGate: FileImporting {
    let base: any FileImporting
    let entered: XCTestExpectation
    private var first = true
    private var gate: CheckedContinuation<Void, Never>?
    private(set) var requests: [String] = []

    init(base: any FileImporting, entered: XCTestExpectation) { self.base = base; self.entered = entered }

    func copy(from source: URL, to destination: URL, maxBytes: Int64, reserveBytes: Int64) async throws -> ImportedFile {
        requests.append(source.lastPathComponent)
        if first {
            first = false
            entered.fulfill()
            await withCheckedContinuation { gate = $0 }
        }
        try Task.checkCancellation()
        return try await base.copy(from: source, to: destination, maxBytes: maxBytes, reserveBytes: reserveBytes)
    }

    func releaseFirstCopy() {
        gate?.resume()
        gate = nil
    }
}
