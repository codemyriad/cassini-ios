import Foundation
import CoreFoundation
import Darwin
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

    /// Positive harness control: the same held protocol must successfully deliver an ordinary response first.
    @Test(.timeLimit(.minutes(1))) func heldProtocolControlDeliversOnItsOriginatingRunLoop() async throws {
        let gate = HeldRequestGate()
        let transport = heldTransport(gate)
        let operation = Task { try await transport.get(URL(string: "https://cassini.invalid/control")!, headers: [:], timeout: 30) }
        defer { gate.reportDiagnostics(); operation.cancel(); gate.failForCleanup() }
        await gate.waitUntilStarted()
        gate.sendHeadersAndPrefix(Data("control".utf8), total: 7)
        gate.finish()
        let answer = try await operation.value
        defer { answer.close() }
        #expect(try await read(answer) == Data("control".utf8))
        #expect(gate.starts == 1)
        #expect(gate.clientCallbacksOnOriginThread, "\(gate.callbackTrace)")
        #expect(gate.callbackTrace.map(\.name) == ["headers", "body", "finish"])
    }

    @Test(.timeLimit(.minutes(1))) func heldProtocolStreamsALargePrefixBeforeEOF() async throws {
        let gate = HeldRequestGate()
        let transport = ObservedTransport(base: heldTransport(gate), gate: gate)
        let prefix = Data(repeating: 0x53, count: 128 << 10)
        let operation = Task { try await transport.get(URL(string: "https://cassini.invalid/stream-control")!, headers: [:], timeout: 30) }
        defer { gate.reportDiagnostics(); operation.cancel(); gate.failForCleanup() }
        await gate.waitUntilStarted()
        gate.sendHeadersAndPrefix(prefix, total: 256 << 10)
        let answer = try await operation.value
        defer { answer.close() }
        var received = Data()
        for try await block in answer.body {
            received.append(block)
            gate.note("stream-control-received-\(received.count)")
            if received.count >= prefix.count { break }
        }
        #expect(received == prefix, "Control must stream the entire sent prefix while EOF is still held")
        answer.close()
        await gate.waitUntilStopped()
        #expect(gate.starts == 1 && gate.stops == 1)
        #expect(gate.clientCallbacksOnOriginThread, "\(gate.callbackTrace)")
        #expect(!gate.callbackTrace.contains { $0.name == "finish" }, "The streaming control never supplies EOF")
    }

    @Test(.timeLimit(.minutes(1))) func cancellingBeforeHeadersStopsTheProtocolAndReturnsCancellation() async throws {
        let gate = HeldRequestGate()
        let transport = heldTransport(gate)
        let operation = Task { try await transport.get(URL(string: "https://cassini.invalid/pre-head")!, headers: [:], timeout: 30) }
        defer { gate.reportDiagnostics(); operation.cancel(); gate.failForCleanup() }
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
        let transport = ObservedTransport(base: heldTransport(gate), gate: gate)
        let operation = Task { try await transport.get(URL(string: "https://cassini.invalid/held")!, headers: [:], timeout: 30) }
        defer { gate.reportDiagnostics(); operation.cancel(); gate.failForCleanup() }
        await gate.waitUntilStarted()
        gate.sendHeadersAndPrefix(Data(repeating: 0x53, count: 128 << 10), total: 256 << 10)
        let answer = try await operation.value
        answer.close()
        await gate.waitUntilStopped()
        #expect(gate.starts == 1 && gate.stops == 1)
        #expect(gate.clientCallbacksOnOriginThread, "\(gate.callbackTrace)")
        // A second independently gated request must still run on this same session.
        let nextGate = HeldRequestGate()
        HeldProtocol.use(nextGate)
        let nextOperation = Task { try await transport.get(URL(string: "https://cassini.invalid/next")!, headers: [:], timeout: 30) }
        defer { nextGate.reportDiagnostics(); nextOperation.cancel(); nextGate.failForCleanup() }
        await nextGate.waitUntilStarted()
        nextGate.sendHeadersAndPrefix(Data("ok".utf8), total: 2)
        nextGate.finish()
        let next = try await nextOperation.value
        defer { next.close() }
        #expect(try await read(next) == Data("ok".utf8))
        #expect(nextGate.clientCallbacksOnOriginThread, "\(nextGate.callbackTrace)")
    }

    @Test(.timeLimit(.minutes(1))) func cancellingAfterTheArtifactPrefixKeepsItAndDoesNotRetryOrPublish() async throws {
        let gate = HeldRequestGate()
        let transport = ObservedTransport(base: heldTransport(gate), gate: gate)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transport-cancel-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let bytes = Data((0..<(256 << 10)).map { UInt8($0 % 251) })
        let prefix = Data(bytes.prefix(128 << 10))
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let artifact = Artifact("model.onnx", Int64(bytes.count), hash)
        let consumed = AsyncStream<Int64>.makeStream()
        let operation = Task {
            try await ArtifactFetcher(transport: transport, storage: FakeStorage())
                .fetch("https://cassini.invalid/model", artifact, into: directory) { count, checking in
                    gate.note("writer-progress-\(count)-checking-\(checking)")
                    if !checking && count > 0 {
                        consumed.continuation.yield(count); consumed.continuation.finish()
                    }
                }
        }
        defer { gate.reportDiagnostics(); operation.cancel(); gate.failForCleanup(); consumed.continuation.finish() }
        await gate.waitUntilStarted()
        gate.sendHeadersAndPrefix(prefix, total: bytes.count)
        var firstWritten: Int64 = 0
        for await count in consumed.stream { firstWritten = count; break } // First positive write, independent of URLSession chunk sizes.
        gate.note("cancel-after-written-\(firstWritten)")
        #expect(firstWritten > 0 && firstWritten <= Int64(prefix.count))
        operation.cancel()
        do { try await operation.value; Issue.record("Cancelled artifact request published") }
        catch { #expect(ModelInstaller.isCancellation(error)) }
        await gate.waitUntilStopped()
        #expect(gate.starts == 1 && gate.stops == 1, "Body cancellation must not renew the session; \(gate.callbackTrace)")
        #expect(gate.freshRequests == 0)
        #expect(gate.clientCallbacksOnOriginThread, "\(gate.callbackTrace)")
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.onnx").path))
        let kept = try Data(contentsOf: directory.appendingPathComponent("\(hash).part"))
        #expect(Int64(kept.count) >= firstWritten && kept.count <= prefix.count, "Every observed write must survive cancellation")
        #expect(!kept.isEmpty && kept == Data(prefix.prefix(kept.count)), "Retained bytes must exactly match the sent model prefix")
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

/// Deliver held fixture callbacks on the loading run loop, rather than the task driving the test.
/// The positive response control verifies this fixture independently of cancellation; delivery is never polled.
private final class HeldClientLoop: @unchecked Sendable {
    let runLoop = CFRunLoopGetCurrent()!
    let threadID = pthread_mach_thread_np(pthread_self())
    let mode: CFRunLoopMode
    init() { mode = CFRunLoopCopyCurrentMode(runLoop) ?? .defaultMode }
    func perform(_ body: @escaping @Sendable () -> Void) {
        CFRunLoopPerformBlock(runLoop, mode.rawValue, body)
        CFRunLoopWakeUp(runLoop)
    }
}

private final class HeldRequestGate: Sendable {
    struct Callback: Sendable {
        let name: String
        let onOriginThread: Bool
    }
    private struct State {
        var loader: HeldProtocol?
        var clientLoop: HeldClientLoop?
        var starts = 0
        var stops = 0
        var callbacks: [Callback] = []
        var milestones: [String] = []
    }
    private let state = Mutex(State())
    private let entered = AsyncStream<Void>.makeStream()
    private let ended = AsyncStream<Void>.makeStream()
    var starts: Int { state.withLock { $0.starts } }
    var stops: Int { state.withLock { $0.stops } }
    var callbackTrace: [Callback] { state.withLock { $0.callbacks } }
    var freshRequests: Int { state.withLock { $0.milestones.filter { $0 == "fresh-session-requested" }.count } }
    var clientCallbacksOnOriginThread: Bool {
        state.withLock { !$0.callbacks.isEmpty && $0.callbacks.allSatisfy(\.onOriginThread) }
    }
    func started(_ loader: HeldProtocol) {
        let clientLoop = HeldClientLoop()
        state.withLock { $0.loader = loader; $0.clientLoop = clientLoop; $0.starts += 1 }
        entered.continuation.yield(()); entered.continuation.finish()
    }
    func stopped() {
        state.withLock { $0.loader = nil; $0.stops += 1 }
        ended.continuation.yield(()); ended.continuation.finish()
    }
    func note(_ milestone: String) { state.withLock { $0.milestones.append(milestone) } }
    func reportDiagnostics() {
        let milestones = state.withLock { $0.milestones }
        print("HeldProtocol lifecycle starts=\(starts) stops=\(stops) callbacks=\(callbackTrace) milestones=\(milestones)")
    }
    func waitUntilStarted() async { for await _ in entered.stream { break } }
    func waitUntilStopped() async { for await _ in ended.stream { break } }

    private func deliver(_ name: String, terminal: Bool = false, _ callback: @escaping @Sendable (HeldProtocol) -> Void) {
        guard let loop = state.withLock({ $0.clientLoop }) else { return }
        loop.perform { [self] in
            let loader = state.withLock { value -> HeldProtocol? in
                guard let loader = value.loader else { return nil } // A stop may beat queued delivery.
                value.callbacks.append(Callback(name: name, onOriginThread: pthread_mach_thread_np(pthread_self()) == loop.threadID))
                if terminal { value.loader = nil }
                return loader
            }
            if let loader { callback(loader) }
        }
    }

    func sendHeadersAndPrefix(_ prefix: Data, total: Int) {
        deliver("headers") { loader in
            let response = HTTPURLResponse(url: loader.request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Length": String(total), "Content-Type": "application/octet-stream"])!
            loader.client?.urlProtocol(loader, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        deliver("body") { loader in loader.client?.urlProtocol(loader, didLoad: prefix) }
    }
    func finish() {
        deliver("finish", terminal: true) { loader in loader.client?.urlProtocolDidFinishLoading(loader) }
    }
    func failForCleanup() {
        deliver("cleanup-cancellation", terminal: true) { loader in
            loader.client?.urlProtocol(loader, didFailWithError: URLError(.cancelled))
        }
    }
}


/// Observes the real adapter without changing its responses, renewal or cancellation behavior.
private struct ObservedTransport: HTTPTransport {
    let base: any HTTPTransport
    let gate: HeldRequestGate
    func freshForRetry() -> (any HTTPTransport)? {
        gate.note("fresh-session-requested")
        guard let fresh = base.freshForRetry() else { return nil }
        return ObservedTransport(base: fresh, gate: gate)
    }
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPAnswer {
        gate.note("get-entered")
        do {
            let answer = try await base.get(url, headers: headers, timeout: timeout)
            gate.note("head-returned-status-\(answer.status)")
            return answer
        } catch {
            gate.note("get-failed-code-\((error as NSError).code)")
            throw error
        }
    }
}
