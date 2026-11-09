import Foundation
import Testing
@testable import CassiniEngine
import CassiniEngineTesting

/// Android #109 ArtifactFetcherCompletionTest, plus iOS AsyncThrowingStream completion/cancellation edges.
/// Every response is in-memory; suspended EOF tests have an upper-bound limit, never a fixed delay.
@Suite struct ArtifactFetcherCompletionTests: Sendable {
    private let bytes = Data("Pinned model bytes for completion tests".utf8)
    private let url = "https://dist.gocassini.com/test-model"
    private func artifact(_ data: Data) -> Artifact { Artifact("model.onnx", Int64(data.count), sha256(data)) }
    private func fetch(_ transport: any HTTPTransport, _ directory: URL,
                       progress: (Int64, Bool) -> Void = { _, _ in }) async throws {
        try await ArtifactFetcher(transport: transport, storage: FakeStorage())
            .fetch(url, artifact(bytes), into: directory, progress: progress)
    }
    private func partial(_ directory: URL) -> URL { ArtifactFetcher.partial(artifact(bytes), in: directory) }

    @Test(.timeLimit(.minutes(1))) func knownLengthCompletesWithoutWaitingForEOF() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let closed = Counter()
        let pair = AsyncThrowingStream<Data, any Error>.makeStream()
        pair.continuation.yield(bytes) // Deliberately never finish until the fetcher closes its response.
        let transport = CompletionTransport { [bytes] _, _ in
            HTTPAnswer(status: 200, headers: [:], expectedLength: Int64(bytes.count), body: pair.stream,
                       close: { _ = closed.next(); pair.continuation.finish() })
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        let completed = try await withThrowingTaskGroup(of: Bool.self) { group in
            defer { group.cancelAll(); pair.continuation.finish() }
            group.addTask { try await fetch(transport, folder.root); return true }
            group.addTask { try await Task.sleep(until: deadline, clock: .continuous); return false }
            return try await group.next() ?? false
        }
        #expect(completed, "Pinned body completion must not wait for the EOF released only during cleanup")
        guard completed else { return }
        #expect(closed.value == 1)
        #expect(try Data(contentsOf: folder.root.appendingPathComponent("model.onnx")) == bytes)
        #expect(!exists(partial(folder.root)))
    }

    @Test(.timeLimit(.minutes(1))) func aSlowValidBodyCannotPublishFromHeadersAlone() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let entered = AsyncStream<Void>.makeStream()
        let permitted = AsyncStream<Data>.makeStream()
        let finished = Counter()
        let stream = AsyncThrowingStream<Data, any Error>(unfolding: {
            entered.continuation.yield(())
            entered.continuation.finish()
            var iterator = permitted.stream.makeAsyncIterator()
            return await iterator.next()
        })
        let transport = CompletionTransport { [bytes] _, _ in
            HTTPAnswer(status: 200, headers: [:], expectedLength: Int64(bytes.count), body: stream)
        }
        let operation = Task {
            try await fetch(transport, folder.root)
            _ = finished.next()
        }
        defer { operation.cancel(); permitted.continuation.finish() }
        for await _ in entered.stream { break }
        #expect(finished.value == 0)
        #expect(!exists(folder.root.appendingPathComponent("model.onnx")))
        permitted.continuation.yield(bytes)
        permitted.continuation.finish()
        try await operation.value
        #expect(finished.value == 1)
        #expect(try Data(contentsOf: folder.root.appendingPathComponent("model.onnx")) == bytes)
    }

    @Test func aLengthlessTruncated200KeepsItsPrefixAndResumes() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let prefix = Data(bytes.prefix(7))
        let attempts = Counter()
        let transport = CompletionTransport { [bytes] _, headers in
            if attempts.next() == 1 { return Self.answer(prefix, length: nil) }
            #expect(headers["Range"] == "bytes=7-")
            #expect(headers["If-Range"] == "\"\(sha256(bytes))\"")
            return Self.answer(Data(bytes.dropFirst(7)), status: 206,
                               headers: ["ETag": "\"\(sha256(bytes))\"", "Content-Range": "bytes 7-\(bytes.count - 1)/\(bytes.count)"],
                               length: Int64(bytes.count - 7))
        }
        #expect(await failure { try await fetch(transport, folder.root) } == .modelDownload)
        #expect(try Data(contentsOf: partial(folder.root)) == prefix)
        try await fetch(transport, folder.root)
        #expect(attempts.value == 2)
        #expect(try Data(contentsOf: folder.root.appendingPathComponent("model.onnx")) == bytes)
    }

    @Test func framingMismatchIsRejectedBeforeReadingTheBody() async throws {
        for resumed in [false, true] {
            let folder = TemporaryFolder()
            defer { folder.remove() }
            if resumed { try Data(bytes.prefix(7)).write(to: partial(folder.root)) }
            let reads = Counter()
            let stream = AsyncThrowingStream<Data, any Error>(unfolding: {
                _ = reads.next()
                throw URLError(.timedOut)
            })
            let transport = CompletionTransport { [bytes] _, _ in
                HTTPAnswer(status: resumed ? 206 : 200,
                           headers: resumed ? ["ETag": "\"\(sha256(bytes))\"", "Content-Range": "bytes 7-12/\(bytes.count)"] : [:],
                           expectedLength: resumed ? 7 : Int64(bytes.count + 1), body: stream)
            }
            #expect(await failure { try await fetch(transport, folder.root) } == .modelVerify)
            #expect(reads.value == 0)
            #expect(!exists(partial(folder.root)))
        }
    }

    @Test func lengthlessRangeCannotDeliverPastItsDeclaredEnd() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        try Data(bytes.prefix(7)).write(to: partial(folder.root))
        let transport = CompletionTransport { [bytes] _, _ in
            Self.answer(Data(bytes.dropFirst(7)), status: 206,
                        headers: ["ETag": "\"\(sha256(bytes))\"", "Content-Range": "bytes 7-12/\(bytes.count)"], length: nil)
        }
        #expect(await failure { try await fetch(transport, folder.root) } == .modelVerify)
        #expect(!exists(partial(folder.root)))
        #expect(!exists(folder.root.appendingPathComponent("model.onnx")))
    }

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost])
    func completeLengthlessBytesStillRequireSHAAfterALateTransportError(_ code: URLError.Code) async throws {
        for valid in [true, false] {
            let folder = TemporaryFolder()
            defer { folder.remove() }
            let body = valid ? bytes : Data(repeating: 0, count: bytes.count)
            let transport = CompletionTransport { _, _ in Self.answer(body, length: nil, error: URLError(code)) }
            if valid {
                try await fetch(transport, folder.root)
                #expect(try Data(contentsOf: folder.root.appendingPathComponent("model.onnx")) == bytes)
            } else {
                #expect(await failure { try await fetch(transport, folder.root) } == .modelVerify)
                #expect(!exists(folder.root.appendingPathComponent("model.onnx")))
            }
            #expect(!exists(partial(folder.root)))
        }
    }

    @Test func lateTransportCancellationCannotPublishEvenCompleteBytes() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let transport = CompletionTransport { [bytes] _, _ in Self.answer(bytes, length: nil, error: URLError(.cancelled)) }
        do { try await fetch(transport, folder.root); Issue.record("Expected cancellation") }
        catch let error as URLError { #expect(error.code == .cancelled) }
        #expect(!exists(folder.root.appendingPathComponent("model.onnx")))
        #expect(try Data(contentsOf: partial(folder.root)) == bytes)
    }

    @Test func taskCancellationAfterFinalBytesCannotPublish() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let transport = CompletionTransport { [bytes] _, _ in Self.answer(bytes, length: Int64(bytes.count)) }
        let result = await Task {
            await failure {
                try await fetch(transport, folder.root) { _, verifying in
                    if !verifying { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
        }.value
        #expect(result == .cancelled)
        #expect(!exists(folder.root.appendingPathComponent("model.onnx")))
    }

    @Test func localOutputAndFinalMoveFailuresAreInstallFailures() async throws {
        for obstructPartial in [true, false] {
            let folder = TemporaryFolder()
            defer { folder.remove() }
            let target = obstructPartial ? partial(folder.root) : folder.root.appendingPathComponent("model.onnx")
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
            let blocker = target.appendingPathComponent("occupied")
            try Data("Keep this".utf8).write(to: blocker)
            let transport = CompletionTransport { [bytes] _, _ in Self.answer(bytes, length: Int64(bytes.count)) }
            #expect(await failure { try await fetch(transport, folder.root) } == .modelInstall)
            #expect(try Data(contentsOf: blocker) == Data("Keep this".utf8))
            if !obstructPartial {
                #expect(try Data(contentsOf: partial(folder.root)) == bytes)
                try FileManager.default.removeItem(at: target)
                try await fetch(transport, folder.root)
                #expect(transport.calls.value == 1, "verified complete bytes retry without a second GET")
                #expect(try Data(contentsOf: target) == bytes)
            }
        }
    }

    @Test(arguments: [false, true]) func missingOrBlockedDirectoriesAreLocalForPlainAndCompressed(_ compressed: Bool) async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let packed = InvertedBytes.compress(bytes)
        let transport = CompletionTransport { [bytes] _, _ in
            Self.answer(compressed ? packed : bytes, length: Int64(compressed ? packed.count : bytes.count))
        }
        let fetcher = ArtifactFetcher(transport: transport, storage: FakeStorage())
        let blocker = folder.root.appendingPathComponent("occupied")
        try Data("Keep this".utf8).write(to: blocker)
        func install(_ target: URL) async throws {
            if compressed {
                try await fetcher.fetchCompressed(url, download: Artifact("model.zst", Int64(packed.count), sha256(packed)),
                                                  artifact: artifact(bytes), into: target, decoder: InvertedBytes()) { _, _ in }
            } else { try await fetch(transport, target) }
        }
        #expect(await failure { try await install(blocker.appendingPathComponent("models")) } == .modelInstall)
        #expect(transport.calls.value == 0)
        #expect(try Data(contentsOf: blocker) == Data("Keep this".utf8))
        let target = folder.root.appendingPathComponent("new/models")
        try await install(target)
        #expect(try Data(contentsOf: target.appendingPathComponent("model.onnx")) == bytes)
    }

    @Test func publicDigestKeepsRawIOFailuresAndInterruptedReadsRetry() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        do { _ = try ArtifactFetcher.digest(folder.root); Issue.record("A directory is not a model file") }
        catch { #expect(error is POSIXError) }
        var attempts = 0
        let count = try ArtifactFetcher.readRetryingInterruptions(cancelled: { false }) {
            attempts += 1
            if attempts < 3 { errno = EINTR; return -1 }
            return 4
        }
        #expect(count == 4)
        #expect(attempts == 3)
        var interrupted = false
        do {
            _ = try ArtifactFetcher.readRetryingInterruptions(cancelled: { interrupted }) {
                interrupted = true; errno = EINTR; return -1
            }
            Issue.record("Cancellation between interrupted reads must stop")
        } catch let error as ModelError { #expect(error.failure == .cancelled) }
    }

    @Test func cancellationAtTheFinalDecompressedHashCannotPublish() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let source = folder.root.appendingPathComponent("model.zst")
        let compressed = InvertedBytes.compress(bytes)
        try compressed.write(to: source)
        let result = await Task {
            await failure {
                try ArtifactFetcher.decompress(source, artifact(bytes), into: folder.root, decoder: InvertedBytes()) { checked in
                    if checked == 2 * Int64(bytes.count) { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
        }.value
        #expect(result == .cancelled)
        #expect(!exists(folder.root.appendingPathComponent("model.onnx")))
        #expect(!exists(partial(folder.root)))
        #expect(try Data(contentsOf: source) == compressed, "A cancelled check retains the verified input for retry")
    }

    @Test func compressedSourceReadErrorsAreLocalAndFormatErrorsStayVerificationFailures() async throws {
        struct BrokenSource: Decompressing {
            let error: NSError
            func decompress(_ source: URL, into sink: (Data) throws -> Void) throws { throw error }
        }
        struct BadFormat: Decompressing {
            struct InvalidFrame: Error { }
            func decompress(_ source: URL, into sink: (Data) throws -> Void) throws { throw InvalidFrame() }
        }
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let source = folder.root.appendingPathComponent("model.zst")
        let compressed = InvertedBytes.compress(bytes)
        try compressed.write(to: source)
        for error in [CocoaError(.fileReadNoPermission) as NSError, POSIXError(.EIO) as NSError,
                      CocoaError(.fileWriteOutOfSpace) as NSError] {
            #expect(await failure {
                try ArtifactFetcher.decompress(source, artifact(bytes), into: folder.root, decoder: BrokenSource(error: error))
            } == (error.code == CocoaError.Code.fileWriteOutOfSpace.rawValue ? .space : .modelInstall))
            #expect(!exists(folder.root.appendingPathComponent("model.onnx")))
        }
        #expect(await failure {
            try ArtifactFetcher.decompress(source, artifact(bytes), into: folder.root, decoder: BadFormat())
        } == .modelVerify)
        #expect(try Data(contentsOf: source) == compressed)
    }

    private static func answer(_ data: Data, status: Int = 200, headers: [String: String] = [:],
                               length: Int64?, error: (any Error)? = nil) -> HTTPAnswer {
        HTTPAnswer(status: status, headers: headers, expectedLength: length, body: AsyncThrowingStream { continuation in
            continuation.yield(data)
            continuation.finish(throwing: error)
        })
    }
}

private final class CompletionTransport: HTTPTransport, Sendable {
    let calls = Counter()
    private let response: @Sendable (URL, [String: String]) throws -> HTTPAnswer
    init(_ response: @escaping @Sendable (URL, [String: String]) throws -> HTTPAnswer) { self.response = response }
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPAnswer {
        _ = calls.next()
        return try response(url, headers)
    }
}
