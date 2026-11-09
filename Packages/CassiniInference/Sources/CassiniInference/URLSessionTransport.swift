import Foundation
import Network
import Synchronization
import CassiniEngine

/// `HTTPTransport` over a data-task `URLSession` whose delegate refuses every redirect, so a 3xx comes back as it is
/// and `RedirectPolicy` decides each hop (a background session follows redirects itself and hides Range answers, so
/// the model downloads use none). The answer returns once its head arrives; its body streams as the data arrives.
/// `URLRequest.timeoutInterval` is the time allowed without data, as Android's read timeout.
///
/// Requests ask for `Accept-Encoding: identity`, so `Content-Length` and `Content-Range` count the bytes of the file.
/// Every request, each redirect hop included (`ArtifactFetcher` asks for each hop itself), carries `userAgent` (D54,
/// `ModelUserAgent`), set last so that no caller header replaces it and CFNetwork's default never goes out.
public final class URLSessionTransport: HTTPTransport {
    private let delegate = Delegate()
    private let session: URLSession
    private let userAgent: String

    public init(userAgent: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.userAgent = userAgent
        let configuration = configuration
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "cassini.model-downloads"
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
    }

    deinit { session.invalidateAndCancel() }

    /// A separate session for one bounded metadata retry; existing transfers keep their own session and delegate.
    public func freshForRetry() -> (any HTTPTransport)? {
        URLSessionTransport(userAgent: userAgent, configuration: session.configuration)
    }

    public func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPAnswer {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let task = session.dataTask(with: request)
        let delegate = delegate
        var answer = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (head: CheckedContinuation<HTTPAnswer, any Error>) in
                delegate.register(task, head: head)
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
        // The session lives while an answer is read: releasing the transport cancels its tasks.
        let close = answer.close
        answer.close = { withExtendedLifetime(self) { close() } }
        return answer
    }

    /// The session's delegate: one entry per running task, from its start to its end.
    private final class Delegate: NSObject, URLSessionDataDelegate, Sendable {
        private struct Entry {
            var head: CheckedContinuation<HTTPAnswer, any Error>?
            var body: AsyncThrowingStream<Data, any Error>.Continuation
            var stream: AsyncThrowingStream<Data, any Error>
            /// The task was closed by its reader: its end is no failure.
            var closed = false
        }

        private let entries = Mutex<[Int: Entry]>([:])

        func register(_ task: URLSessionDataTask, head: CheckedContinuation<HTTPAnswer, any Error>) {
            let (stream, body) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
            let id = task.taskIdentifier
            body.onTermination = { [weak self] reason in
                // A reader that stops early (a redirect, a failed check) ends the transfer.
                if case .cancelled = reason { self?.close(id, task) }
            }
            entries.withLock { $0[id] = Entry(head: head, body: body, stream: stream) }
        }

        private func close(_ id: Int, _ task: URLSessionTask) {
            entries.withLock { $0[id]?.closed = true }
            task.cancel()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            let id = dataTask.taskIdentifier
            let found = entries.withLock { entries -> (CheckedContinuation<HTTPAnswer, any Error>, AsyncThrowingStream<Data, any Error>)? in
                guard let entry = entries[id], let head = entry.head else { return nil }
                entries[id]?.head = nil
                return (head, entry.stream)
            }
            guard let (head, stream) = found else { return completionHandler(.cancel) }
            guard let http = response as? HTTPURLResponse else {
                completionHandler(.cancel)
                return head.resume(throwing: URLError(.badServerResponse))
            }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
            }
            let length = http.expectedContentLength >= 0 ? http.expectedContentLength : nil
            completionHandler(.allow)
            head.resume(returning: HTTPAnswer(status: http.statusCode, headers: headers, expectedLength: length,
                                              body: stream, close: { [weak self] in self?.close(id, dataTask) }))
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            let body = entries.withLock { $0[dataTask.taskIdentifier]?.body }
            body?.yield(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            guard let entry = entries.withLock({ $0.removeValue(forKey: task.taskIdentifier) }) else { return }
            if let head = entry.head {
                head.resume(throwing: error ?? URLError(.badServerResponse))
                entry.body.finish()
            } else if let error, !entry.closed {
                entry.body.finish(throwing: error)
            } else {
                entry.body.finish()
            }
        }
    }
}

/// Whether the device has a network path, and whether it is expensive (mobile data, a personal hotspot) or
/// constrained (Low Data Mode), from `NWPathMonitor`. The installer skips the best-effort models without a path;
/// the consent screen notes mobile data.
public final class NetworkPath: Sendable {
    public struct Snapshot: Hashable, Sendable {
        public var online: Bool
        public var expensive: Bool
        public var constrained: Bool
        public init(online: Bool, expensive: Bool, constrained: Bool) {
            self.online = online; self.expensive = expensive; self.constrained = constrained
        }
    }

    public static let shared = NetworkPath()

    private let monitor = NWPathMonitor()
    // Until the first update the path is unknown: a download is tried, as Android does with a stale check.
    private let current = Mutex(Snapshot(online: true, expensive: false, constrained: false))

    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.current.withLock {
                $0 = Snapshot(online: path.status == .satisfied, expensive: path.isExpensive, constrained: path.isConstrained)
            }
        }
        monitor.start(queue: DispatchQueue(label: "cassini.network-path"))
    }

    deinit { monitor.cancel() }

    public var snapshot: Snapshot { current.withLock { $0 } }
    public var isOnline: Bool { snapshot.online }
    /// Mobile data or Low Data Mode: "You are on mobile data" on the consent screen.
    public var isExpensive: Bool { snapshot.expensive || snapshot.constrained }
}
