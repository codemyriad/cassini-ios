import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniEngineTesting

/// No network, clocks or polling: request failures and body events are supplied synchronously.
@Suite struct ArtifactRequestRetryTests {
    private let bytes = Data("English model fixture".utf8)
    private let url = "https://models.example/model"
    private let policy = RedirectPolicy(hosts: ["models.example"])

    private func artifact() -> Artifact { Artifact("model.onnx", Int64(bytes.count), sha256(bytes)) }
    private func fetch(_ transport: RequestRetryTransport, _ directory: URL,
                       policy: RedirectPolicy? = nil) async throws {
        try await ArtifactFetcher(transport: transport, storage: FakeStorage())
            .fetch(url, artifact(), into: directory, redirects: policy ?? self.policy) { _, _ in }
    }

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost])
    func aPreHeaderFailureRetriesOnceAndKeepsTheFreshTransportForRedirects(_ code: URLError.Code) async throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        let bytes = bytes
        let fresh = RequestRetryTransport { target, _ in
            target.path == "/model" ? Self.answer(status: 302, headers: ["Location": "/final"])
                : Self.answer(bytes)
        }
        let original = RequestRetryTransport(fresh: fresh) { _, _ in throw URLError(code) }
        try await fetch(original, folder.root)
        #expect(original.requests.count == 1)
        #expect(original.freshCalls == 1)
        #expect(fresh.requests.map(\.path) == ["/model", "/final"])
        #expect(fresh.freshCalls == 0)
        #expect(fresh.requests.allSatisfy { $0.headers == original.requests[0].headers })
        #expect(try Data(contentsOf: folder.file("model.onnx")) == bytes)
    }

    @Test func aPartialKeepsItsExactRangeAndIfRangeHeaders() async throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        let bytes = bytes, pin = artifact(), prefix = 5
        let partial = folder.file("\(pin.sha256).part")
        try bytes.prefix(prefix).write(to: partial)
        let fresh = RequestRetryTransport { _, _ in
            Self.answer(bytes.subdata(in: prefix..<bytes.count), status: 206,
                        headers: ["Content-Range": "bytes \(prefix)-\(bytes.count - 1)/\(bytes.count)",
                                  "ETag": ArtifactFetcher.entityTag(pin)])
        }
        let original = RequestRetryTransport(fresh: fresh) { _, _ in throw URLError(.timedOut) }
        try await fetch(original, folder.root)
        #expect(original.requests[0].headers == fresh.requests[0].headers)
        #expect(fresh.requests[0].headers["Range"] == "bytes=5-")
        #expect(fresh.requests[0].headers["If-Range"] == ArtifactFetcher.entityTag(pin))
        #expect(try Data(contentsOf: folder.file("model.onnx")) == bytes)
        #expect(!exists(partial))
    }

    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost])
    func aSecondPreHeaderFailureCannotCreateAThirdSession(_ code: URLError.Code) async {
        let folder = TemporaryFolder(); defer { folder.remove() }
        let third = RequestRetryTransport { _, _ in Self.answer() }
        let fresh = RequestRetryTransport(fresh: third) { _, _ in throw URLError(code) }
        let original = RequestRetryTransport(fresh: fresh) { _, _ in throw URLError(.timedOut) }
        await expectNetwork(code) { try await fetch(original, folder.root) }
        #expect(original.freshCalls == 1)
        #expect(fresh.requests.count == 1 && fresh.freshCalls == 0)
        #expect(third.requests.isEmpty)
    }

    @Test(arguments: [503, 416, 206])
    func anOriginalHTTPErrorDoesNotCreateAFreshSession(_ status: Int) async {
        let folder = TemporaryFolder(); defer { folder.remove() }
        let fresh = RequestRetryTransport { _, _ in Self.answer() }
        let original = RequestRetryTransport(fresh: fresh) { _, _ in Self.answer(status: status) }
        #expect(await failure { try await fetch(original, folder.root) } == .modelDownload)
        #expect(original.requests.count == 1 && original.freshCalls == 0)
        #expect(fresh.requests.isEmpty)
    }

    @Test func anOriginalDigestFailureDoesNotCreateAFreshSession() async {
        let folder = TemporaryFolder(); defer { folder.remove() }
        let wrong = Data(repeating: 120, count: bytes.count)
        let bytes = bytes
        let fresh = RequestRetryTransport { _, _ in Self.answer(bytes) }
        let original = RequestRetryTransport(fresh: fresh) { _, _ in Self.answer(wrong) }
        #expect(await failure { try await fetch(original, folder.root) } == .modelVerify)
        #expect(original.requests.count == 1 && original.freshCalls == 0)
        #expect(fresh.requests.isEmpty)
        #expect(!exists(folder.file("model.onnx")))
    }

    @Test func insufficientStorageDoesNotCreateAFreshSessionOrRequest() async {
        let folder = TemporaryFolder(); defer { folder.remove() }
        let bytes = bytes
        let fresh = RequestRetryTransport { _, _ in Self.answer(bytes) }
        let original = RequestRetryTransport(fresh: fresh) { _, _ in Self.answer(bytes) }
        #expect(await failure {
            try await ArtifactFetcher(transport: original, storage: FakeStorage(availableBytes: 0))
                .fetch(url, artifact(), into: folder.root, redirects: policy) { _, _ in }
        } == .space)
        #expect(original.requests.isEmpty && original.freshCalls == 0)
        #expect(fresh.requests.isEmpty)
    }

    @Test func aLocalOutputFailureAfterHeadersDoesNotRetryTheRequest() async {
        let folder = TemporaryFolder(); defer { folder.remove() }
        let partial = folder.file("\(artifact().sha256).part")
        let bytes = bytes
        let fresh = RequestRetryTransport { _, _ in Self.answer(bytes) }
        let original = RequestRetryTransport(fresh: fresh) { _, _ in
            // The preflight has completed. Make the output path unwritable before the real writer opens it.
            try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
            return Self.answer(bytes)
        }
        #expect(await failure { try await fetch(original, folder.root) } == .modelInstall)
        #expect(original.requests.count == 1 && original.freshCalls == 0)
        #expect(fresh.requests.isEmpty)
        #expect(!exists(folder.file("model.onnx")))
    }

    @Test func cancellationFollowedByALateTimeoutDoesNotCreateAFreshSession() async {
        let folder = TemporaryFolder(); defer { folder.remove() }
        let fresh = RequestRetryTransport { _, _ in Self.answer() }
        let original = RequestRetryTransport(fresh: fresh) { _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw URLError(.timedOut)
        }
        let operation = Task { await expectNetwork(.timedOut) { try await fetch(original, folder.root) } }
        await operation.value
        #expect(original.freshCalls == 0 && fresh.requests.isEmpty)
    }

    @Test func noFreshTransportPreservesTheOriginalFailureAndPartial() async throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        let partial = folder.file("\(artifact().sha256).part")
        let kept = bytes.prefix(5)
        try kept.write(to: partial)
        let original = RequestRetryTransport { _, _ in throw URLError(.networkConnectionLost) }
        await expectNetwork(.networkConnectionLost) { try await fetch(original, folder.root) }
        #expect(original.requests.count == 1 && original.freshCalls == 1)
        #expect(try Data(contentsOf: partial) == kept)
    }

    @Test func renewingTheTransportDoesNotResetTheRedirectBudget() async {
        let folder = TemporaryFolder(); defer { folder.remove() }
        let fresh = RequestRetryTransport { _, _ in Self.answer(status: 302, headers: ["Location": "/forbidden-extra-hop"]) }
        let original = RequestRetryTransport(fresh: fresh) { target, _ in
            if target.path == "/model" { return Self.answer(status: 302, headers: ["Location": "/one"]) }
            throw URLError(.timedOut)
        }
        #expect(await failure {
            try await fetch(original, folder.root, policy: RedirectPolicy(hosts: ["models.example"], maxRedirects: 1))
        } == .modelDownload)
        #expect(original.requests.map(\.path) == ["/model", "/one"])
        #expect(fresh.requests.map(\.path) == ["/one"])
    }

    @Test(arguments: [503, 416, 206])
    func aFreshSessionCannotBypassStatusValidation(_ status: Int) async {
        let folder = TemporaryFolder(); defer { folder.remove() }
        let fresh = RequestRetryTransport { _, _ in Self.answer(status: status) }
        let original = RequestRetryTransport(fresh: fresh) { _, _ in throw URLError(.timedOut) }
        #expect(await failure { try await fetch(original, folder.root) } == .modelDownload)
        #expect(fresh.requests.count == 1 && fresh.freshCalls == 0)
        #expect(!exists(folder.file("model.onnx")))
    }

    @Test func aFreshResponseStillHasToMatchThePinnedDigest() async {
        let folder = TemporaryFolder(); defer { folder.remove() }
        let wrong = Data(repeating: 120, count: bytes.count)
        let fresh = RequestRetryTransport { _, _ in Self.answer(wrong) }
        let original = RequestRetryTransport(fresh: fresh) { _, _ in throw URLError(.timedOut) }
        #expect(await failure { try await fetch(original, folder.root) } == .modelVerify)
        #expect(!exists(folder.file("model.onnx")))
    }

    @Test func aBodyTimeoutIsNotRetriedAndKeepsItsPartial() async throws {
        let folder = TemporaryFolder(); defer { folder.remove() }
        let count = Int64(bytes.count)
        let fresh = RequestRetryTransport { _, _ in Self.answer() }
        let original = RequestRetryTransport(fresh: fresh) { _, _ in
            HTTPAnswer(status: 200, headers: [:], expectedLength: count, body: AsyncThrowingStream { continuation in
                continuation.yield(Data([1]))
                continuation.finish(throwing: URLError(.timedOut))
            })
        }
        await expectNetwork(.timedOut) { try await fetch(original, folder.root) }
        #expect(original.requests.count == 1 && original.freshCalls == 0)
        #expect(fresh.requests.isEmpty)
        #expect(try Data(contentsOf: folder.file("\(artifact().sha256).part")) == Data([1]))
    }

    @Test func metadataReadsDoNotUseTheArtifactRetryPolicy() async {
        let fresh = RequestRetryTransport { _, _ in Self.answer() }
        let original = RequestRetryTransport(fresh: fresh) { _, _ in throw URLError(.timedOut) }
        await expectNetwork(.timedOut) {
            _ = try await ArtifactFetcher(transport: original, storage: FakeStorage()).read(url, limit: 100, redirects: policy)
        }
        #expect(original.freshCalls == 0 && fresh.requests.isEmpty)
    }

    private static func answer(_ bytes: Data = Data(), status: Int = 200, headers: [String: String] = [:]) -> HTTPAnswer {
        HTTPAnswer(status: status, headers: headers, expectedLength: Int64(bytes.count), body: AsyncThrowingStream {
            $0.yield(bytes); $0.finish()
        })
    }

    private func expectNetwork(_ expected: URLError.Code, _ operation: () async throws -> Void) async {
        do { try await operation(); Issue.record("Expected network error") }
        catch let error as URLError { #expect(error.code == expected) }
        catch { Issue.record("Expected URLError, got \(error)") }
    }
}

private final class RequestRetryTransport: HTTPTransport, Sendable {
    struct Request: Sendable { let path: String; let headers: [String: String] }
    private struct State { var requests: [Request] = []; var freshCalls = 0 }
    private let state = Mutex(State())
    private let fresh: RequestRetryTransport?
    private let respond: @Sendable (URL, [String: String]) async throws -> HTTPAnswer
    var requests: [Request] { state.withLock { $0.requests } }
    var freshCalls: Int { state.withLock { $0.freshCalls } }

    init(fresh: RequestRetryTransport? = nil, respond: @escaping @Sendable (URL, [String: String]) async throws -> HTTPAnswer) {
        self.fresh = fresh; self.respond = respond
    }
    func freshForRetry() -> (any HTTPTransport)? {
        state.withLock { $0.freshCalls += 1 }
        return fresh
    }
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPAnswer {
        state.withLock { $0.requests.append(Request(path: url.path, headers: headers)) }
        return try await respond(url, headers)
    }
}
