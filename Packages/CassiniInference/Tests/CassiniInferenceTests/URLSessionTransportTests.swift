import Foundation
import CryptoKit
import Synchronization
import Testing
import CassiniEngine
import CassiniEngineTesting
@testable import CassiniInference

/// `URLSessionTransport` over a `URLProtocol` stub: the session never reaches the network, and every request it makes
/// is recorded, so a followed redirect would show.
@Suite(.serialized) struct URLSessionTransportTests {
    private let transport: URLSessionTransport = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSessionTransport(userAgent: "CassiniTalk/0.1.0 (iOS 26.1; build 2)", configuration: configuration)
    }()

    private func read(_ answer: HTTPAnswer) async throws -> Data {
        var data = Data()
        for try await block in answer.body { data.append(block) }
        return data
    }

    /// The redirect is the answer; `RedirectPolicy` decides whether to follow it (ArtifactFetcherTest's
    /// aRedirectToAHostOffTheListIsNeverFollowed, against the platform's URL loading).
    @Test func aRedirectComesBackAsItIsAndIsNotFollowed() async throws {
        StubProtocol.reset { request in
            if request.url?.host() == "dist.gocassini.com" {
                return .redirect(to: "https://example.com/elsewhere")
            }
            return .answer(200, [:], [Data("followed".utf8)])
        }
        let answer = try await transport.get(URL(string: "https://dist.gocassini.com/model")!, headers: [:], timeout: 30)
        #expect(answer.status == 302)
        #expect(answer.header("Location") == "https://example.com/elsewhere")
        answer.close()
        #expect(StubProtocol.hosts == ["dist.gocassini.com"])
    }

    @Test func theRangeIsSentAndThePartialBodyStreams() async throws {
        StubProtocol.reset { request in
            let range = request.value(forHTTPHeaderField: "Range") ?? ""
            return .answer(206, ["Content-Range": "bytes 3-8/9", "Content-Length": "6", "X-Range": range],
                           [Data("abc".utf8), Data("def".utf8)])
        }
        let answer = try await transport.get(URL(string: "https://dist.gocassini.com/model")!,
                                               headers: ["Range": "bytes=3-"], timeout: 30)
        #expect(answer.status == 206)
        #expect(answer.header("x-range") == "bytes=3-")
        #expect(answer.header("Content-Range") == "bytes 3-8/9")
        #expect(answer.expectedLength == 6)
        #expect(try await read(answer) == Data("abcdef".utf8))
        #expect(StubProtocol.encodings == ["identity"], "Content-Length counts the bytes of the file")
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .networkConnectionLost])
    func noAnswerPreservesTheURLErrorCode(_ code: URLError.Code) async {
        StubProtocol.reset { _ in .fail(URLError(code)) }
        do {
            _ = try await transport.get(URL(string: "https://dist.gocassini.com/model")!, headers: [:], timeout: 30)
            Issue.record("Expected the original transport failure")
        } catch let error as URLError { #expect(error.code == code) }
        catch { Issue.record("Expected URLError, got \(error)") }
    }

    @Test func aFreshRetrySessionKeepsItsConfigurationAndDoesNotInvalidateTheOriginal() async throws {
        StubProtocol.reset { request in
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "CassiniTalk/0.1.0 (iOS 26.1; build 2)")
            #expect(request.value(forHTTPHeaderField: "Accept-Encoding") == "identity")
            return .answer(200, ["Content-Length": "3"], [Data("abc".utf8)])
        }
        let original = try await transport.get(URL(string: "https://cassini.invalid/original")!, headers: [:], timeout: 30)
        defer { original.close() }
        let fresh = try #require(transport.freshForRetry())
        let retried = try await fresh.get(URL(string: "https://cassini.invalid/retried")!, headers: [:], timeout: 30)
        defer { retried.close() }
        #expect(try await read(retried) == Data("abc".utf8))
        #expect(try await read(original) == Data("abc".utf8))
        let next = try await transport.get(URL(string: "https://cassini.invalid/next")!, headers: [:], timeout: 30)
        defer { next.close() }
        #expect(try await read(next) == Data("abc".utf8))
        #expect(StubProtocol.hosts == ["cassini.invalid", "cassini.invalid", "cassini.invalid"])
    }

    /// A model download redirected off the allow-list stops at the redirect with HOST_NOT_ALLOWED, and the foreign host
    /// is never asked.
    @Test func aForcedBadRedirectIsRefusedAsHostNotAllowed() async throws {
        StubProtocol.reset { request in
            request.url?.host() == "dist.gocassini.com" ? .redirect(to: "https://example.com/tokens.txt")
                : .answer(200, [:], [Data("tokens".utf8)])
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let tokens = try #require(ModelCatalog.parakeetArtifacts[3].download)
        do {
            try await ArtifactFetcher(transport: transport, storage: FakeStorage()).fetch(tokens.url, tokens, into: directory) { _, _ in }
            Issue.record("The redirect must be refused")
        } catch {
            #expect(ModelInstaller.downloadError(error, online: { true }) == .hostNotAllowed)
        }
        #expect(StubProtocol.hosts == ["dist.gocassini.com"])
    }

    /// The error comes from `get` when URL loading ends the task before it hands over the head, else from the body.
    @Test(arguments: [URLError.Code.timedOut, .networkConnectionLost])
    func aTransferThatBreaksOffPreservesItsURLErrorCode(_ code: URLError.Code) async throws {
        StubProtocol.reset { _ in .answer(200, ["Content-Length": "100"], [Data("abc".utf8)], then: URLError(code)) }
        do {
            let answer = try await transport.get(URL(string: "https://dist.gocassini.com/model")!, headers: [:], timeout: 30)
            defer { answer.close() }
            _ = try await read(answer)
            Issue.record("Expected the original transport failure")
        } catch let error as URLError { #expect(error.code == code) }
        catch { Issue.record("Expected URLError, got \(error)") }
    }

    @Test(.timeLimit(.minutes(1))) func cancellingBeforeHeadersStopsTheProtocolAndReturnsCancellation() async throws {
        let gate = HeldRequestGate()
        let transport = heldTransport(gate)
        let operation = Task { try await transport.get(URL(string: "https://cassini.invalid/pre-head")!, headers: [:], timeout: 30) }
        defer { operation.cancel(); gate.failForCleanup() }
        await gate.waitUntilStarted()
        operation.cancel()
        do {
            let answer = try await operation.value
            answer.close()
            Issue.record("Cancelled pre-header request returned an answer")
        } catch let error as URLError { #expect(error.code == .cancelled) }
        catch { Issue.record("Expected URLSession cancellation, got \(error)") }
        await gate.waitUntilStopped()
        #expect(gate.starts == 1 && gate.stops == 1)
    }

    @Test(.timeLimit(.minutes(1))) func closingAnAnswerStopsItsHeldBodyWithoutInvalidatingTheSession() async throws {
        let gate = HeldRequestGate()
        let transport = heldTransport(gate)
        let operation = Task { try await transport.get(URL(string: "https://cassini.invalid/held")!, headers: [:], timeout: 30) }
        defer { operation.cancel(); gate.failForCleanup() }
        await gate.waitUntilStarted()
        gate.sendHeadersAndPrefix(Data("abc".utf8), total: 100)
        let answer = try await operation.value
        answer.close()
        await gate.waitUntilStopped()
        #expect(gate.starts == 1 && gate.stops == 1)
        // A second independently gated request must still run on this same session.
        let nextGate = HeldRequestGate()
        HeldProtocol.use(nextGate)
        let nextOperation = Task { try await transport.get(URL(string: "https://cassini.invalid/next")!, headers: [:], timeout: 30) }
        defer { nextOperation.cancel(); nextGate.failForCleanup() }
        await nextGate.waitUntilStarted()
        nextGate.sendHeadersAndPrefix(Data("ok".utf8), total: 2)
        nextGate.finish()
        let next = try await nextOperation.value
        defer { next.close() }
        #expect(try await read(next) == Data("ok".utf8))
    }

    @Test(.timeLimit(.minutes(1))) func cancellingAfterTheArtifactPrefixKeepsItAndDoesNotRetryOrPublish() async throws {
        let gate = HeldRequestGate()
        let transport = heldTransport(gate)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transport-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data("Pinned complete model".utf8), prefix = Data("Pinned".utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let artifact = Artifact("model.onnx", Int64(bytes.count), hash)
        let consumed = AsyncStream<Void>.makeStream()
        let operation = Task {
            try await ArtifactFetcher(transport: transport, storage: FakeStorage())
                .fetch("https://cassini.invalid/model", artifact, into: directory) { count, checking in
                    if !checking && count == Int64(prefix.count) {
                        consumed.continuation.yield(()); consumed.continuation.finish()
                    }
                }
        }
        defer { operation.cancel(); gate.failForCleanup(); consumed.continuation.finish() }
        await gate.waitUntilStarted()
        gate.sendHeadersAndPrefix(prefix, total: bytes.count)
        for await _ in consumed.stream { break } // Bytes have reached the file writer before cancellation.
        operation.cancel()
        do { try await operation.value; Issue.record("Cancelled artifact request published") }
        catch { #expect(ModelInstaller.isCancellation(error)) }
        await gate.waitUntilStopped()
        #expect(gate.starts == 1 && gate.stops == 1, "Body cancellation must not renew the session")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.onnx").path))
        #expect(try Data(contentsOf: directory.appendingPathComponent("\(hash).part")) == prefix)
    }

    private func heldTransport(_ gate: HeldRequestGate) -> URLSessionTransport {
        HeldProtocol.use(gate)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HeldProtocol.self]
        return URLSessionTransport(userAgent: "Cassini cancellation event tests", configuration: configuration)
    }

}

/// Answers every request of the session with `handler`, recording each request.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case answer(Int, [String: String], [Data], then: URLError? = nil)
        case redirect(to: String)
        case fail(URLError)
    }

    private struct State {
        var handler: @Sendable (URLRequest) -> Reply = { _ in .fail(URLError(.unsupportedURL)) }
        var requests: [URLRequest] = []
    }

    private static let state = Mutex(State())

    static func reset(_ handler: @escaping @Sendable (URLRequest) -> Reply) {
        state.withLock { $0 = State(handler: handler) }
    }

    static var hosts: [String] { state.withLock { $0.requests.compactMap { $0.url?.host() } } }
    static var encodings: [String] { state.withLock { $0.requests.compactMap { $0.value(forHTTPHeaderField: "Accept-Encoding") } } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let handler = Self.state.withLock { state in
            state.requests.append(request)
            return state.handler
        }
        let url = request.url!
        switch handler(request) {
        case .fail(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .redirect(let location):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": location])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: location)!), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .answer(let status, let headers, let blocks, let error):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for block in blocks { client?.urlProtocol(self, didLoad: block) }
            if let error { client?.urlProtocol(self, didFailWithError: error) } else { client?.urlProtocolDidFinishLoading(self) }
        }
    }

    override func stopLoading() {}
}


/// A held URL loading operation. No worker is blocked: the test explicitly delivers each callback.
/// Suite serialization protects the next-request selector; each protocol instance retains its own gate.
private final class HeldProtocol: URLProtocol, @unchecked Sendable {
    private static let next = Mutex<HeldRequestGate?>(nil)
    private let active = Mutex<HeldRequestGate?>(nil)
    static func use(_ gate: HeldRequestGate) { next.withLock { $0 = gate } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let gate = Self.next.withLock({ $0 }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        active.withLock { $0 = gate }
        gate.started(self)
    }
    override func stopLoading() { active.withLock { $0 }?.stopped() }
}

private final class HeldRequestGate: Sendable {
    private struct State { var loader: HeldProtocol?; var starts = 0; var stops = 0 }
    private let state = Mutex(State())
    private let entered = AsyncStream<Void>.makeStream()
    private let ended = AsyncStream<Void>.makeStream()
    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }
    func started(_ loader: HeldProtocol) {
        state.withLock { $0.loader = loader; $0.starts += 1 }
        entered.continuation.yield(()); entered.continuation.finish()
    }
    func stopped() {
        state.withLock { $0.loader = nil; $0.stops += 1 }
        ended.continuation.yield(()); ended.continuation.finish()
    }
    func waitUntilStarted() async { for await _ in entered.stream { break } }
    func waitUntilStopped() async { for await _ in ended.stream { break } }
    func sendHeadersAndPrefix(_ prefix: Data, total: Int) {
        guard let loader = state.withLock({ $0.loader }) else { Issue.record("Held request not active"); return }
        let response = HTTPURLResponse(url: loader.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Length": String(total)])!
        loader.client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
        loader.client?.urlProtocol(loader, didLoad: prefix)
    }
    func finish() {
        let loader = state.withLock { value -> HeldProtocol? in
            let loader = value.loader; value.loader = nil; return loader
        }
        if let loader { loader.client?.urlProtocolDidFinishLoading(loader) }
    }
    func failForCleanup() {
        let loader = state.withLock { value -> HeldProtocol? in
            let loader = value.loader; value.loader = nil; return loader
        }
        if let loader { loader.client?.urlProtocol(loader, didFailWithError: URLError(.cancelled)) }
    }
}
