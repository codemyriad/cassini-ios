import CryptoKit
import Foundation
import Network
import Synchronization
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniInference

/// D54 over the platform's real URL loading: a loopback HTTP server on 127.0.0.1 records the head of every request
/// `URLSessionTransport` sends, so the test sees the User-Agent as it went out, after CFNetwork had its say.
@Suite(.serialized) struct ModelUserAgentLoopbackTests {
    private static let agent = "CassiniTalk/0.1.0 (iOS 26.1; build 2)"

    /// The manifest, `NOTICE.txt`, and an artifact reached through a redirect hop each carry exactly the app's
    /// User-Agent, and no other.
    @Test func everyModelRequestAndRedirectHopNamesTheApp() async throws {
        let model = Data("model bytes".utf8)
        let server = try await LoopbackServer.start { path, base in
            switch path {
            case "/manifest.json": LoopbackServer.Reply(200, ["Content-Type": "application/json"], Data("{}".utf8))
            case "/NOTICE.txt": LoopbackServer.Reply(200, ["Content-Type": "text/plain"], Data("Notices".utf8))
            case "/hop/model.bin": LoopbackServer.Reply(302, ["Location": "\(base)/files/model.bin"], Data())
            case "/files/model.bin": LoopbackServer.Reply(200, [:], model)
            default: LoopbackServer.Reply(404, [:], Data())
            }
        }
        defer { server.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fetcher = ArtifactFetcher(transport: URLSessionTransport(userAgent: Self.agent), storage: FakeStorage())
        let loopback = RedirectPolicy(hosts: ["127.0.0.1"], httpsOnly: false)
        let sha = SHA256.hash(data: model).map { String(format: "%02x", $0) }.joined()

        #expect(try await fetcher.read("\(server.base)/manifest.json", limit: 1024, redirects: loopback) == Data("{}".utf8))
        try await fetcher.fetchNotice("\(server.base)/NOTICE.txt", into: directory, redirects: loopback)
        try await fetcher.fetch("\(server.base)/hop/model.bin", Artifact("model.bin", Int64(model.count), sha),
                                into: directory, redirects: loopback) { _, _ in }

        let requests = server.requests
        #expect(requests.map(\.path) == ["/manifest.json", "/NOTICE.txt", "/hop/model.bin", "/files/model.bin"])
        for request in requests {
            #expect(request.userAgents == [Self.agent], "\(request.path) sent \(request.userAgents)")
        }
        #expect(try Data(contentsOf: directory.appendingPathComponent("model.bin")) == model)
    }
}

/// A minimal HTTP/1.1 server on 127.0.0.1 (Network.framework): it reads each request's head, records it, sends the
/// route's answer and closes the connection.
final class LoopbackServer: @unchecked Sendable {
    struct Reply: Sendable {
        var status: Int
        var headers: [String: String]
        var body: Data
        init(_ status: Int, _ headers: [String: String], _ body: Data) {
            self.status = status; self.headers = headers; self.body = body
        }
    }

    /// One request as it arrived: its path and every `User-Agent` header line's value.
    struct Request: Sendable {
        var path: String
        var userAgents: [String]
    }

    typealias Route = @Sendable (_ path: String, _ base: String) -> Reply

    private let listener: NWListener
    private let queue = DispatchQueue(label: "cassini.loopback-server")
    private let route: Route
    private let recorded = Mutex<[Request]>([])
    private(set) var base = ""

    var requests: [Request] { recorded.withLock { $0 } }

    private init(route: @escaping Route) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.route = route
    }

    /// Starts listening on a free loopback port and returns once the port is known.
    static func start(_ route: @escaping Route) async throws -> LoopbackServer {
        let server = try LoopbackServer(route: route)
        let port: UInt16 = try await withCheckedThrowingContinuation { ready in
            let once = Mutex(Optional(ready))
            server.listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.withLock { $0.take() }?.resume(returning: server.listener.port?.rawValue ?? 0)
                case .failed(let error): once.withLock { $0.take() }?.resume(throwing: error)
                default: break
                }
            }
            server.listener.newConnectionHandler = { [weak server] connection in server?.serve(connection) }
            server.listener.start(queue: server.queue)
        }
        server.base = "http://127.0.0.1:\(port)"
        return server
    }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, Data())
    }

    private func receive(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, complete, error in
            let buffer = buffer + (data ?? Data())
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                if complete || error != nil { connection.cancel() } else { receive(connection, buffer) }
                return
            }
            let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            let path = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            let agents = lines.dropFirst().compactMap { line -> String? in
                guard let colon = line.firstIndex(of: ":"),
                      line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "user-agent" else { return nil }
                return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            recorded.withLock { $0.append(Request(path: path, userAgents: agents)) }
            let reply = route(path, base)
            var head = "HTTP/1.1 \(reply.status) \(HTTPURLResponse.localizedString(forStatusCode: reply.status))\r\n"
            for (name, value) in reply.headers { head += "\(name): \(value)\r\n" }
            head += "Content-Length: \(reply.body.count)\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + reply.body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
