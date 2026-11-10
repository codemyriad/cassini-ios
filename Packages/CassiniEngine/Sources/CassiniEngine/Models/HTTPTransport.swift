import Foundation

/// One answer of an `HTTPTransport`: its status, headers and body. The body is read once; `close()` ends the
/// connection early (a redirect, an answer that is not used).
public struct HTTPAnswer: Sendable {
    public var status: Int
    /// Header names in lower case.
    public var headers: [String: String]
    /// What `Content-Length` announces; nil when the answer does not say.
    public var expectedLength: Int64?
    public var body: AsyncThrowingStream<Data, any Error>
    public var close: @Sendable () -> Void

    public init(status: Int, headers: [String: String], expectedLength: Int64?,
                body: AsyncThrowingStream<Data, any Error>, close: @escaping @Sendable () -> Void = {}) {
        self.status = status
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.expectedLength = expectedLength
        self.body = body
        self.close = close
    }

    public func header(_ name: String) -> String? { headers[name.lowercased()] }
}

/// Sends one GET and hands back the answer as soon as its head arrives, without following a redirect: a 3xx comes
/// back as it is, so `RedirectPolicy` decides every hop (`ArtifactFetcher`). The app's adapter is
/// `URLSessionTransport` (CassiniInference); tests pass a fake, so no test touches the network.
public protocol HTTPTransport: Sendable {
    /// A transport with an independent session and the same request policy, for one explicit metadata retry.
    /// Transports without independent sessions can leave the default nil; callers then preserve the original failure.
    func freshForRetry() -> (any HTTPTransport)?

    /// Throws when no answer arrives (no connection, a timeout after `timeout` seconds without data).
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPAnswer
}

extension HTTPTransport {
    public func freshForRetry() -> (any HTTPTransport)? { nil }
}
