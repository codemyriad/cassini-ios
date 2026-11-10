import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniNotebook
import CassiniEngineTesting

/// `NetworkModelFetcher` against a loopback model host (Android's ModelFetcherNetworkTest): the manifest decides where
/// each pinned file is, the host's notices come with the model, and each file comes as its own compressed object,
/// verified before and after decompression. The compression is `InvertedBytes`; CassiniInferenceTests runs the same
/// path with real seekable Zstandard.
@Suite struct NetworkModelFetcherTests {
    private static let base = "http://127.0.0.1:8080"
    private let encoder = Data((0..<200_000).map { UInt8($0 * 13 % 241) })
    private let tokens = Data(String(repeating: "a 0\nb 1\n", count: 500).utf8)
    private let notice = Data("Test model\n==========\nMIT\n".utf8)

    private var files: [String: Data] { ["encoder.onnx": encoder, "tokens.txt": tokens] }

    private func pinned(_ name: String) -> Artifact {
        let body = files[name]!, packed = InvertedBytes.compress(body)
        return Artifact(name, Int64(body.count), sha256(body),
                        download: Artifact("\(name).zst", Int64(packed.count), sha256(packed),
                                           "\(Self.base)/models/files/\(sha256(packed))/\(name).zst"))
    }

    private var model: ModelDescriptor {
        ModelDescriptor("test-model", String(repeating: "f", count: 64), [pinned("encoder.onnx"), pinned("tokens.txt")])
    }

    /// Plain HTTP to the loopback server, as the test host is not HTTPS.
    private let loopback = RedirectPolicy(hosts: ["127.0.0.1"], httpsOnly: false)

    /// A schema 2 manifest that lists `model` with its files on the loopback host.
    private func manifest(sourceSha256: String? = nil) -> Data {
        let files = model.artifacts.map { artifact -> [String: Any] in
            ["path": artifact.name, "artifact": "models/files/\(artifact.download!.sha256)/\(artifact.name).zst",
             "required": true]
        }
        let artifacts = model.artifacts.map { artifact -> [String: Any] in
            let download = artifact.download!
            let key = "models/files/\(download.sha256)/\(artifact.name).zst"
            return ["key": key, "url": "\(Self.base)/\(key)", "size": download.size, "sha256": download.sha256,
                    "uncompressed_size": artifact.size, "uncompressed_sha256": artifact.sha256,
                    "encoding": "zstd-seekable", "format_version": "0.1.0"]
        }
        let row: [String: Any] = ["id": model.id, "source_sha256": sourceSha256 ?? model.sourceSha256, "files": files]
        return try! JSONSerialization.data(withJSONObject: ["schema_version": 2, "base_url": Self.base,
                                                            "models": [row], "artifacts": artifacts])
    }

    /// The host: the manifest, the notices and each compressed file at its content-addressed path, with its entity
    /// tag; `answer` overrides a path.
    private func host(manifest: Data? = nil,
                      answer: @escaping @Sendable (String) -> FakeServer.Answer? = { _ in nil }) -> FakeServer {
        var paths: [String: FakeServer.Answer] = [
            "/manifest.json": FakeServer.Answer(200, manifest ?? self.manifest()),
            "/NOTICE.txt": FakeServer.Answer(200, notice),
        ]
        for artifact in model.artifacts {
            let packed = InvertedBytes.compress(files[artifact.name]!)
            paths[URL(string: artifact.download!.url)!.path] = FakeServer.Answer(200, packed,
                                                                                 headers: ["ETag": "\"\(sha256(packed))\""])
        }
        let served = paths
        return FakeServer { request in
            let path = request["path"] ?? ""
            return answer(path) ?? served[path] ?? FakeServer.Answer(404, Data())
        }
    }

    private func fetcher(_ server: FakeServer) -> NetworkModelFetcher {
        NetworkModelFetcher(fetcher: ArtifactFetcher(transport: server, storage: FakeStorage()), redirects: loopback,
                            decoder: InvertedBytes(), manifestURL: "\(Self.base)/manifest.json",
                            noticeURL: "\(Self.base)/NOTICE.txt", base: Self.base)
    }

    // ports: ModelFetcherNetworkTest#eachFileIsFetchedFromWhereTheManifestSaysAndDecompressed
    @Test func eachFileIsFetchedFromWhereTheManifestSaysAndDecompressed() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let server = host()
        let directory = folder.newFolder("staging")
        let seen = Mutex<[(Int64, Bool)]>([])
        try await fetcher(server).fetch(model, into: directory) { bytes, verifying in
            seen.withLock { $0.append((bytes, verifying)) }
        }
        for (name, bytes) in files { #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == bytes) }
        #expect(try Data(contentsOf: directory.appendingPathComponent("NOTICE.txt")) == notice)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
                == ["encoder.onnx", "tokens.txt", "NOTICE.txt"], "no compressed file or part is left")
        #expect(model.complete(directory))
        // The manifest first, then the notices, then the files in order; nothing else.
        #expect(server.requests.map { $0["path"] } == ["/manifest.json", "/NOTICE.txt"]
                + model.artifacts.map { URL(string: $0.download!.url)!.path })
        #expect(server.requests.allSatisfy { $0["accept-encoding"] == "identity" })
        // The progress counts the compressed bytes of both files, ends with all of them, and checks once at the end:
        // it never goes back from checking to downloading.
        let events = seen.withLock { $0 }
        #expect(events.last?.0 == model.downloadBytes && events.last?.1 == true)
        #expect(events.allSatisfy { (0...model.downloadBytes).contains($0.0) })
        let firstCheck = try #require(events.firstIndex { $0.1 })
        #expect(events[firstCheck...].allSatisfy { $0.1 })
        #expect(events[firstCheck].0 >= model.artifacts[0].download!.size, "the first file's check reads as downloading")
    }

    // ports: ModelFetcherNetworkTest#aManifestWithoutThePinnedPairFetchesNothing (iOS: PIN_UNAVAILABLE, not VERIFY)
    @Test func aManifestWithoutThePinnedPairFetchesNothing() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let server = host(manifest: manifest(sourceSha256: String(repeating: "0", count: 64)))
        let directory = folder.newFolder("staging")
        #expect(await failure { try await fetcher(server).fetch(model, into: directory) { _, _ in } }
                == .download(.pinUnavailable))
        #expect(server.requests.map { $0["path"] } == ["/manifest.json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    /// iOS only: a manifest longer than `DistManifest.maxBytes`, sent or announced, cannot be the host's. It is refused
    /// as a model the host does not offer (PIN_UNAVAILABLE, no Download again), not as a damaged download, and nothing
    /// else is fetched.
    @Test func aManifestTooLongToBeTheHostsIsAPinUnavailable() async throws {
        let long = Data(repeating: 0x20, count: Int(DistManifest.maxBytes) + 1)
        let answers = [FakeServer.Answer(200, long), FakeServer.Answer(200, manifest(), length: Int(DistManifest.maxBytes) + 1)]
        for answer in answers {
            let folder = TemporaryFolder()
            defer { folder.remove() }
            let server = host { $0 == "/manifest.json" ? answer : nil }
            let directory = folder.newFolder("staging")
            #expect(await failure { try await fetcher(server).fetch(model, into: directory) { _, _ in } }
                    == .download(.pinUnavailable))
            #expect(server.requests.map { $0["path"] } == ["/manifest.json"])
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    // ports: ModelFetcherNetworkTest#aFileUrlOffTheAllowedHostsFetchesNothing
    @Test func aFileUrlOffTheAllowedHostsFetchesNothing() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let server = host()
        // The download policy of the app: HTTPS to dist.gocassini.com only.
        let app = NetworkModelFetcher(fetcher: ArtifactFetcher(transport: server, storage: FakeStorage()),
                                      decoder: InvertedBytes(), manifestURL: "\(Self.base)/manifest.json",
                                      noticeURL: "\(Self.base)/NOTICE.txt", base: Self.base)
        #expect(await failure { try await app.fetch(model, into: folder.newFolder("staging")) { _, _ in } }
                == .download(.pinUnavailable))
        #expect(server.requests.map { $0["path"] } == ["/manifest.json"])
    }

    /// Offline, or with the host down, the manifest cannot be read: the download fails as one (NO_CONNECTION or
    /// INTERRUPTED with Retry), and every kept part stays for the next attempt.
    @Test func withoutTheManifestNothingIsFetchedAndThePartsStay() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let server = host { $0 == "/manifest.json" ? FakeServer.Answer(503, Data()) : nil }
        let directory = folder.newFolder("staging")
        let part = directory.appendingPathComponent("\(model.artifacts[0].download!.sha256).part")
        try Data(count: 1000).write(to: part)
        #expect(await failure { try await fetcher(server).fetch(model, into: directory) { _, _ in } } == .modelDownload)
        #expect(length(part) == 1000)
        #expect(server.requests.count == 1)
    }

    /// A model the host lists but whose notices cannot be read is not installed: no file is fetched.
    @Test func withoutTheNoticesNoFileIsFetched() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let server = host { $0 == "/NOTICE.txt" ? FakeServer.Answer(200, Data()) : nil }
        let directory = folder.newFolder("staging")
        #expect(await failure { try await fetcher(server).fetch(model, into: directory) { _, _ in } } == .modelVerify)
        #expect(server.requests.map { $0["path"] } == ["/manifest.json", "/NOTICE.txt"])
        #expect(!model.complete(directory))
    }

    /// An install through the repository: the files land in the staging directory and appear in the revision
    /// directory only once all of them and the notices are there; an install counts as this session's check.
    @Test func anInstallPublishesTheRevisionOnceEveryFileIsChecked() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        struct Consent: ModelConsentRecords {
            func consentAt() async -> Date? { nil }
            func recordConsent() async {}
            func recordDeclined() async {}
        }
        let verifier = ModelVerifier()
        let root = folder.newFolder("models")
        let repository = ModelRepository(root: root, consent: Consent(), fetcher: fetcher(host()), verifier: verifier)
        try await repository.installModel(model) { _, _ in }
        #expect(model.ready(in: root))
        #expect(!exists(model.staging(in: root)))
        #expect(verifier.isChecked(model, in: root))
        #expect(try verifier.verify(model, in: root), "the real digest agrees")
    }
    private func retryFetcher(_ transport: any HTTPTransport) -> NetworkModelFetcher {
        NetworkModelFetcher(fetcher: ArtifactFetcher(transport: transport, storage: FakeStorage()), redirects: loopback,
                            decoder: InvertedBytes(), manifestURL: "\(Self.base)/manifest.json",
                            noticeURL: "\(Self.base)/NOTICE.txt", base: Self.base)
    }

    @Test(arguments: ["/manifest.json", "/NOTICE.txt"], [URLError.Code.timedOut, .networkConnectionLost])
    func transientMetadataFailureUsesOneFreshTransportForTheRemainingInstall(_ path: String, _ code: URLError.Code) async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let fresh = MetadataRetryTransport(server: host())
        let original = MetadataRetryTransport(server: host(), failurePath: path, failureCode: code, fresh: fresh)
        let directory = folder.newFolder("staging")
        try await retryFetcher(original).fetch(model, into: directory) { _, _ in }
        #expect(original.paths == (path == "/manifest.json" ? [path] : ["/manifest.json", path]))
        #expect(original.freshCalls.value == 1)
        #expect(fresh.paths == ["/manifest.json", "/NOTICE.txt"] + model.artifacts.map { URL(string: $0.download!.url)!.path })
        #expect(fresh.freshCalls.value == 0)
        #expect(model.complete(directory))
        for (name, bytes) in files { #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == bytes) }
        #expect(try Data(contentsOf: directory.appendingPathComponent("NOTICE.txt")) == notice)
    }

    @Test func aMetadataTimeoutWithoutAnIndependentSessionKeepsTheOriginalFailure() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let original = MetadataRetryTransport(server: host(), failurePath: "/manifest.json")
        let directory = folder.newFolder("staging")
        await expectNetworkError(.timedOut) { try await retryFetcher(original).fetch(model, into: directory) { _, _ in } }
        #expect(original.freshCalls.value == 1)
        #expect(original.paths == ["/manifest.json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func aRetryRevalidatesTheManifestBeforeFetchingAnyArtifact() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let forbiddenThird = MetadataRetryTransport(server: host())
        let fresh = MetadataRetryTransport(
            server: host(manifest: manifest(sourceSha256: String(repeating: "0", count: 64))), fresh: forbiddenThird)
        // The original manifest was valid; a lost NOTICE response cannot authorize the new session's changed pins.
        let original = MetadataRetryTransport(server: host(), failurePath: "/NOTICE.txt",
                                             failureCode: .networkConnectionLost, fresh: fresh)
        let directory = folder.newFolder("staging")
        #expect(await failure {
            try await retryFetcher(original).fetch(model, into: directory) { _, _ in }
        } == .download(.pinUnavailable))
        #expect(original.paths == ["/manifest.json", "/NOTICE.txt"])
        #expect(original.freshCalls.value == 1)
        #expect(fresh.paths == ["/manifest.json"])
        #expect(fresh.freshCalls.value == 0)
        #expect(forbiddenThird.paths.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func aSecondMetadataTimeoutEndsTheInstallWithoutAThirdSession() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let forbiddenThird = MetadataRetryTransport(server: host())
        let fresh = MetadataRetryTransport(server: host(), failurePath: "/manifest.json", failureCode: .timedOut, fresh: forbiddenThird)
        let original = MetadataRetryTransport(server: host(), failurePath: "/manifest.json", failureCode: .timedOut, fresh: fresh)
        let directory = folder.newFolder("staging")
        await expectNetworkError(.timedOut) { try await retryFetcher(original).fetch(model, into: directory) { _, _ in } }
        #expect(original.paths == ["/manifest.json"])
        #expect(fresh.paths == ["/manifest.json"])
        #expect(original.freshCalls.value == 1)
        #expect(fresh.freshCalls.value == 0)
        #expect(forbiddenThird.paths.isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    @Test func cancellationWhileMetadataIsPendingCannotCreateAFreshSession() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let gate = MetadataRequestGate()
        let fresh = MetadataRetryTransport(server: host())
        let original = MetadataRetryTransport(server: host(), failurePath: "/manifest.json", failureCode: .timedOut,
                                             fresh: fresh, gate: gate)
        let directory = folder.newFolder("staging")
        let operation = Task { try await retryFetcher(original).fetch(model, into: directory) { _, _ in } }
        await gate.waitUntilEntered()
        operation.cancel()
        gate.release()
        // A late timeout after cancellation still belongs to the cancelled operation, not a retry.
        do { try await operation.value; Issue.record("Expected the cancelled request to fail") }
        catch is CancellationError { }
        catch let error as URLError { #expect(error.code == .timedOut || error.code == .cancelled) }
        catch { Issue.record("Unexpected cancellation failure: \(error)") }
        #expect(original.freshCalls.value == 0)
        #expect(fresh.paths.isEmpty)
        #expect(original.paths == ["/manifest.json"])
    }

    @Test(arguments: [URLError.Code.cancelled, .cannotFindHost, .notConnectedToInternet])
    func otherNetworkErrorsDoNotStartAFreshSession(_ code: URLError.Code) async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let fresh = MetadataRetryTransport(server: host())
        let original = MetadataRetryTransport(server: host(), failurePath: "/manifest.json", failureCode: code, fresh: fresh)
        await expectNetworkError(code) {
            try await retryFetcher(original).fetch(model, into: folder.newFolder("staging")) { _, _ in }
        }
        #expect(original.freshCalls.value == 0)
        #expect(fresh.paths.isEmpty)
    }

    @Test func badMetadataPinsHTTPAndIntegrityFailuresAreNeverRetried() async throws {
        let scenarios: [(FakeServer, JobFailure, [String])] = [
            (host(manifest: Data("not JSON".utf8)), .download(.pinUnavailable), ["/manifest.json"]),
            (host(manifest: manifest(sourceSha256: String(repeating: "0", count: 64))), .download(.pinUnavailable), ["/manifest.json"]),
            (host { $0 == "/manifest.json" ? FakeServer.Answer(503, Data()) : nil }, .modelDownload, ["/manifest.json"]),
            (host { $0 == "/manifest.json" ? FakeServer.Answer(302, Data(), headers: ["Location": "https://other.example/manifest.json"]) : nil }, .modelDownload, ["/manifest.json"]),
            (host { $0 == "/NOTICE.txt" ? FakeServer.Answer(200, Data()) : nil }, .modelVerify, ["/manifest.json", "/NOTICE.txt"])
        ]
        for (server, expected, paths) in scenarios {
            let folder = TemporaryFolder()
            defer { folder.remove() }
            let fresh = MetadataRetryTransport(server: host())
            let original = MetadataRetryTransport(server: server, fresh: fresh)
            #expect(await failure { try await retryFetcher(original).fetch(model, into: folder.newFolder("staging")) { _, _ in } } == expected)
            #expect(original.paths == paths)
            #expect(original.freshCalls.value == 0)
            #expect(fresh.paths.isEmpty)
        }
    }

    @Test func metadataBodyTimeoutAlsoUsesTheFreshTransport() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let fresh = MetadataRetryTransport(server: host())
        let original = MetadataRetryTransport(server: host(), bodyTimeoutPath: "/manifest.json", fresh: fresh)
        let directory = folder.newFolder("staging")
        try await retryFetcher(original).fetch(model, into: directory) { _, _ in }
        #expect(original.paths == ["/manifest.json"])
        #expect(original.freshCalls.value == 1)
        #expect(fresh.paths == ["/manifest.json", "/NOTICE.txt"] + model.artifacts.map { URL(string: $0.download!.url)!.path })
        #expect(model.complete(directory))
    }

    @Test func failurePublishingTheNoticeIsNotANetworkRetry() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let directory = folder.newFolder("staging")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("NOTICE.txt"), withIntermediateDirectories: false)
        let fresh = MetadataRetryTransport(server: host())
        let original = MetadataRetryTransport(server: host(), fresh: fresh)
        #expect(await failure { try await retryFetcher(original).fetch(model, into: directory) { _, _ in } } == .modelInstall)
        #expect(original.paths == ["/manifest.json", "/NOTICE.txt"])
        #expect(original.freshCalls.value == 0)
        #expect(fresh.paths.isEmpty)
    }

    @Test func anArtifactBodyTimeoutKeepsItsPartialWithoutMetadataRetry() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let artifact = model.artifacts[0].download!
        let path = URL(string: artifact.url)!.path
        let fresh = MetadataRetryTransport(server: host())
        let original = MetadataRetryTransport(server: host(), bodyTimeoutPath: path, fresh: fresh)
        let directory = folder.newFolder("staging")
        await expectNetworkError(.timedOut) { try await retryFetcher(original).fetch(model, into: directory) { _, _ in } }
        #expect(original.paths == ["/manifest.json", "/NOTICE.txt", path])
        #expect(original.freshCalls.value == 0)
        #expect(fresh.paths.isEmpty)
        #expect(length(directory.appendingPathComponent("\(artifact.sha256).part")) == 1)
        #expect(!model.complete(directory))
    }

    private func expectNetworkError(_ code: URLError.Code, _ operation: () async throws -> Void) async {
        do { try await operation(); Issue.record("Expected network error \(code)") }
        catch let error as URLError { #expect(error.code == code) }
        catch { Issue.record("Expected URLError, got \(error)") }
    }

}


/// No network, timers or polling: each attempted request and session renewal is observed directly.
private final class MetadataRetryTransport: HTTPTransport, Sendable {
    let server: FakeServer
    let failurePath: String?
    let failureCode: URLError.Code
    let bodyTimeoutPath: String?
    let fresh: (any HTTPTransport)?
    let gate: MetadataRequestGate?
    let freshCalls = Counter()
    private let requests = Mutex<[String]>([])
    var paths: [String] { requests.withLock { $0 } }

    init(server: FakeServer, failurePath: String? = nil, failureCode: URLError.Code = .timedOut,
         bodyTimeoutPath: String? = nil, fresh: (any HTTPTransport)? = nil, gate: MetadataRequestGate? = nil) {
        self.server = server; self.failurePath = failurePath; self.failureCode = failureCode
        self.bodyTimeoutPath = bodyTimeoutPath; self.fresh = fresh; self.gate = gate
    }
    func freshForRetry() -> (any HTTPTransport)? {
        _ = freshCalls.next()
        return fresh
    }
    func get(_ url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPAnswer {
        requests.withLock { $0.append(url.path) }
        if url.path == failurePath {
            if let gate { await gate.enterAndWait() }
            throw URLError(failureCode)
        }
        var answer = try await server.get(url, headers: headers, timeout: timeout)
        if url.path == bodyTimeoutPath {
            answer.body = AsyncThrowingStream { continuation in
                continuation.yield(Data([0]))
                continuation.finish(throwing: URLError(.timedOut))
            }
        }
        return answer
    }
}

private final class MetadataRequestGate: Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let permitted = AsyncStream<Void>.makeStream()
    func enterAndWait() async {
        entered.continuation.yield(())
        entered.continuation.finish()
        for await _ in permitted.stream { break }
    }
    func waitUntilEntered() async { for await _ in entered.stream { break } }
    func release() { permitted.continuation.yield(()); permitted.continuation.finish() }
}
