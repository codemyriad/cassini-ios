import Foundation
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

    @Test func noAnswerThrowsTheURLError() async {
        StubProtocol.reset { _ in .fail(URLError(.notConnectedToInternet)) }
        await #expect(throws: URLError.self) {
            _ = try await transport.get(URL(string: "https://dist.gocassini.com/model")!, headers: [:], timeout: 30)
        }
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
    @Test func aTransferThatBreaksOffThrows() async throws {
        StubProtocol.reset { _ in .answer(200, ["Content-Length": "100"], [Data("abc".utf8)], then: URLError(.networkConnectionLost)) }
        await #expect(throws: URLError.self) {
            let answer = try await transport.get(URL(string: "https://dist.gocassini.com/model")!, headers: [:], timeout: 30)
            _ = try await read(answer)
        }
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
