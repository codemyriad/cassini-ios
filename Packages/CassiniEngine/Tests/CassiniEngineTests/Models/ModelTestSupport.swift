import Foundation
import CryptoKit
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniNotebook

/// A scratch directory, removed by `remove()`.
struct TemporaryFolder {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-model-test-\(UUID().uuidString)",
                                                                             isDirectory: true)

    init() { try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }

    func newFolder(_ name: String) -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func file(_ name: String) -> URL { root.appendingPathComponent(name) }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

func length(_ url: URL) -> Int64 {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
}

func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

/// A sparse file of `size` bytes: a real length, no disk use.
func sparse(_ url: URL, size: Int64) {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try! FileHandle(forWritingTo: url)
    try! handle.truncate(atOffset: UInt64(size))
    try! handle.close()
}

/// Sparse files of `model`'s pinned sizes in `directory`, with the host's notices: what a fetch leaves there.
func sparse(_ model: ModelDescriptor, in directory: URL) {
    for artifact in model.artifacts { sparse(directory.appendingPathComponent(artifact.name), size: artifact.size) }
    try! Data("notices".utf8).write(to: directory.appendingPathComponent(ModelDescriptor.noticeFile))
}

/// The revision directory of `model` with sparse files of the pinned sizes and the notices, as a finished install
/// leaves it.
func install(_ model: ModelDescriptor, in root: URL) {
    let directory = model.directory(in: root)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    sparse(model, in: directory)
}

/// Polls `condition` until it holds; the 30 s bound is only a hang guard.
func waitUntil(_ message: String = "The condition never held", _ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record(Comment(rawValue: message))
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

/// The failure a `ModelError` thrown by `body` carries; nil (and a recorded issue) when it does not throw one.
func failure(_ body: () async throws -> Void) async -> JobFailure? {
    do {
        try await body()
        Issue.record("Expected a ModelError")
    } catch let error as ModelError {
        return error.failure
    } catch {
        Issue.record("Expected a ModelError, got \(error)")
    }
    return nil
}

/// A stand-in for Android's loopback test server: an `HTTPTransport` that answers requests to 127.0.0.1 and localhost
/// on `port` with `respond`, and records each request's headers (`host` included, as `<host>:<port>`). A request to any
/// other host is recorded too, and fails as an unknown host would: a test can check that it never happened.
final class FakeServer: HTTPTransport, Sendable {
    /// One HTTP answer. `sent` bytes of `body` are written, then the connection closes; `length` is what it announces.
    struct Answer: Sendable {
        var status: Int
        var body: Data
        var headers: [String: String] = [:]
        var sent: Int?
        var length: Int?

        init(_ status: Int, _ body: Data, headers: [String: String] = [:], sent: Int? = nil, length: Int? = nil) {
            self.status = status; self.body = body; self.headers = headers; self.sent = sent; self.length = length
        }
    }

    let port = 8_080
    private let respond: @Sendable ([String: String]) -> Answer
    private let recorded = Mutex<[[String: String]]>([])

    init(_ respond: @escaping @Sendable ([String: String]) -> Answer) { self.respond = respond }

    convenience init(_ body: Data, status: Int = 200) { self.init { _ in Answer(status, body) } }

    var url: String { "http://127.0.0.1:\(port)/model" }

    var requests: [[String: String]] { recorded.withLock { $0 } }

    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPAnswer {
        var request = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { $1 })
        let host = url.host(percentEncoded: false) ?? ""
        request["host"] = "\(host):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
        request["path"] = url.path
        recorded.withLock { $0.append(request) }
        guard ["127.0.0.1", "localhost"].contains(host), url.port == port else { throw URLError(.cannotFindHost) }
        let answer = respond(request)
        let bytes = answer.body.prefix(answer.sent ?? answer.body.count)
        let body = AsyncThrowingStream<Data, any Error> { continuation in
            var start = bytes.startIndex
            while start < bytes.endIndex {
                let end = min(start + 64 * 1024, bytes.endIndex)
                continuation.yield(Data(bytes[start..<end]))
                start = end
            }
            continuation.finish()
        }
        return HTTPAnswer(status: answer.status, headers: answer.headers,
                          expectedLength: Int64(answer.length ?? answer.body.count), body: body)
    }
}

/// A counter the fake servers' answers share between requests.
final class Counter: Sendable {
    private let count = Mutex(0)
    /// Adds one and returns the new count.
    func next() -> Int { count.withLock { $0 += 1; return $0 } }
    var value: Int { count.withLock { $0 } }
}
