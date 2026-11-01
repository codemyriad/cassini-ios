import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// Android's ArtifactFetcherTest against `FakeServer`, an `HTTPTransport` that stands in for its loopback server: no
/// test touches the network.
@Suite struct ArtifactFetcherTests {
    private let weights = Data((0..<300_000).map { UInt8($0 * 7 % 253) })

    private func fetcher(_ server: FakeServer) -> ArtifactFetcher {
        ArtifactFetcher(transport: server, storage: FakeStorage())
    }

    private func artifact(_ body: Data) -> Artifact { Artifact("model.onnx", Int64(body.count), sha256(body)) }

    /// Runs `check` with a scratch directory, removed afterwards.
    private func withFolder(_ check: (URL) async throws -> Void) async rethrows {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        try await check(folder.root)
    }

    /// The entity tag the model host gives `body`: its quoted SHA-256.
    private static func tag(_ body: Data) -> String { "\"\(sha256(body))\"" }

    /// Answers a Range request with the requested suffix of `body`, announcing `total` as the full length, as the model
    /// host does: with `body`'s entity tag, and the whole file when `If-Range` names another one.
    private static func ranged(_ body: Data, total: Int? = nil) -> @Sendable ([String: String]) -> FakeServer.Answer {
        { headers in
            let etag = ["ETag": tag(body)]
            guard let range = headers["range"], headers["if-range"].map({ $0 == tag(body) }) ?? true else {
                return FakeServer.Answer(200, body, headers: etag)
            }
            let from = Int(range.dropFirst("bytes=".count).dropLast())!
            return FakeServer.Answer(206, body.subdata(in: from..<body.count), headers: etag.merging(
                ["Content-Range": "bytes \(from)-\(body.count - 1)/\(total ?? body.count)"]) { $1 })
        }
    }

    private func fetch(_ server: FakeServer, _ artifact: Artifact, _ directory: URL,
                       _ policy: RedirectPolicy = .downloads) async throws {
        try await fetcher(server).fetch(server.url, artifact, into: directory, redirects: policy) { _, _ in }
    }

    /// The `.part` of the artifact of `body`, named after its SHA-256.
    private func part(_ directory: URL, _ body: Data? = nil) -> URL {
        directory.appendingPathComponent("\(sha256(body ?? weights)).part")
    }
    private func model(_ directory: URL) -> URL { directory.appendingPathComponent("model.onnx") }

    // ports: ArtifactFetcherTest#bytesThatDoNotMatchTheVoiceprintPinAreNotKept
    @Test func bytesThatDoNotMatchTheVoiceprintPinAreNotKept() async {
        let server = FakeServer(Data("voiceprint weights".utf8))
        await withFolder { directory in
            #expect(await failure { try await fetch(server, ModelCatalog.voiceprintModel, directory) } == .modelVerify)
            #expect(!exists(directory.appendingPathComponent(ModelCatalog.voiceprintModel.name)))
            #expect(!exists(directory.appendingPathComponent("\(ModelCatalog.voiceprintModel.sha256).part")))
        }
    }

    // ports: ArtifactFetcherTest#verifiedBytesAreInstalledAndPartialFilesAreRemoved
    @Test func verifiedBytesAreInstalledAndPartialFilesAreRemoved() async throws {
        let bytes = Data("model weights".utf8)
        let server = FakeServer(bytes)
        try await withFolder { directory in
            try await fetch(server, artifact(bytes), directory)
            #expect(try Data(contentsOf: model(directory)) == bytes)
            #expect(!exists(part(directory, bytes)))
        }
    }

    // ports: ArtifactFetcherTest#aCorrectLengthWithWrongHashCannotReplaceAnExistingModel
    @Test func aCorrectLengthWithWrongHashCannotReplaceAnExistingModel() async throws {
        let bytes = Data("model weights".utf8)
        let server = FakeServer(Data("wrong weights".utf8))
        try await withFolder { directory in
            let original = Data("existing copy".utf8)
            try original.write(to: model(directory))
            #expect(await failure { try await fetch(server, artifact(bytes), directory) } == .modelVerify)
            #expect(try Data(contentsOf: model(directory)) == original)
            #expect(!exists(part(directory, bytes)))
        }
    }

    // ports: ArtifactFetcherTest#unavailableModelsReportDownloadFailureAndKeepNoPartial
    @Test func unavailableModelsReportDownloadFailureAndKeepNoPartial() async {
        let bytes = Data("missing model".utf8)
        let server = FakeServer(bytes, status: 404)
        await withFolder { directory in
            #expect(await failure { try await fetch(server, artifact(bytes), directory) } == .modelDownload)
            #expect(!exists(model(directory)))
            #expect(!exists(part(directory, bytes)))
        }
    }

    // ports: ArtifactFetcherTest#anInterruptedDownloadCannotInstallItsResult
    /// A cancelled task stands for Android's interrupted thread.
    @Test func anInterruptedDownloadCannotInstallItsResult() async {
        let bytes = Data("model weights".utf8)
        let server = FakeServer(bytes)
        await withFolder { directory in
            let attempt = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                return await failure { try await fetch(server, artifact(bytes), directory) }
            }
            #expect(await attempt.value == .cancelled)
            #expect(!exists(model(directory)))
        }
    }

    // ports: ArtifactFetcherTest#aBrokenTransferKeepsItsPartAndTheNextAttemptResumesIt
    @Test func aBrokenTransferKeepsItsPartAndTheNextAttemptResumesIt() async throws {
        let attempts = Counter()
        let respond = Self.ranged(weights)
        let server = FakeServer { [weights] headers in
            // The first answer announces every byte but the connection drops after 100 000 of them.
            attempts.next() == 1 ? FakeServer.Answer(200, weights, sent: 100_000) : respond(headers)
        }
        try await withFolder { directory in
            #expect(await failure { try await fetch(server, artifact(weights), directory) } == .modelDownload)
            #expect(!exists(model(directory)))
            #expect(length(part(directory)) == 100_000)
            var reported: [Int64] = []
            try await fetcher(server).fetch(server.url, artifact(weights), into: directory) { done, verifying in
                if !verifying { reported.append(done) }
            }
            #expect(server.requests.last?["range"] == "bytes=100000-")
            #expect(try Data(contentsOf: model(directory)) == weights)
            #expect(!exists(part(directory)))
            #expect(reported.allSatisfy { $0 > 100_000 }, "Progress continues from the resumed length")
        }
    }

    // ports: ArtifactFetcherTest#aPartialAnswerResumesFromThePartLength
    @Test func aPartialAnswerResumesFromThePartLength() async throws {
        let server = FakeServer(Self.ranged(weights))
        try await withFolder { directory in
            try weights.prefix(123_456).write(to: part(directory))
            try await fetch(server, artifact(weights), directory)
            #expect(server.requests.map { $0["range"] } == ["bytes=123456-"])
            #expect(try Data(contentsOf: model(directory)) == weights)
            #expect(!exists(part(directory)))
        }
    }

    // ports: ArtifactFetcherTest#aRangeThatEndsBeforeTheArtifactKeepsItsBytesAndTheNextAttemptGoesOn
    @Test func aRangeThatEndsBeforeTheArtifactKeepsItsBytesAndTheNextAttemptGoesOn() async throws {
        let cap = 100_000
        let server = FakeServer { [weights] headers in
            // A server that caps every open-ended range at 100 000 bytes.
            let from = Int(headers["range"]!.dropFirst("bytes=".count).dropLast())!
            let to = min(from + cap, weights.count)
            return FakeServer.Answer(206, weights.subdata(in: from..<to),
                                     headers: ["Content-Range": "bytes \(from)-\(to - 1)/\(weights.count)",
                                               "ETag": Self.tag(weights)])
        }
        try await withFolder { directory in
            try weights.prefix(1000).write(to: part(directory))
            #expect(await failure { try await fetch(server, artifact(weights), directory) } == .modelDownload)
            #expect(length(part(directory)) == 101_000)
            #expect(ArtifactFetcher.bytesToFetch(artifact(weights), in: directory) == Int64(weights.count) - 101_000)
            #expect(await failure { try await fetch(server, artifact(weights), directory) } == .modelDownload)
            #expect(length(part(directory)) == 201_000)
            try await fetch(server, artifact(weights), directory)
            #expect(server.requests.map { $0["range"] } == ["bytes=1000-", "bytes=101000-", "bytes=201000-"])
            #expect(try Data(contentsOf: model(directory)) == weights)
            #expect(!exists(part(directory)))
        }
    }

    // ports: ArtifactFetcherTest#aRangeThatEndsPastTheArtifactDeletesThePart
    @Test func aRangeThatEndsPastTheArtifactDeletesThePart() async throws {
        let server = FakeServer { [weights] _ in
            FakeServer.Answer(206, weights.subdata(in: 1000..<weights.count),
                              headers: ["Content-Range": "bytes 1000-\(weights.count)/\(weights.count)",
                                        "ETag": Self.tag(weights)])
        }
        try await withFolder { directory in
            try weights.prefix(1000).write(to: part(directory))
            #expect(await failure { try await fetch(server, artifact(weights), directory) } == .modelVerify)
            #expect(!exists(part(directory)))
        }
    }

    // ports: ArtifactFetcherTest#onlyAPartThatCanStillBeAPrefixReducesTheBytesToFetch
    @Test func onlyAPartThatCanStillBeAPrefixReducesTheBytesToFetch() async throws {
        try await withFolder { directory in
            let target = artifact(weights)
            #expect(ArtifactFetcher.bytesToFetch(target, in: directory) == Int64(weights.count))
            try weights.prefix(1000).write(to: part(directory))
            #expect(ArtifactFetcher.bytesToFetch(target, in: directory) == Int64(weights.count) - 1000)
            try Data(count: weights.count + 1).write(to: part(directory))
            #expect(ArtifactFetcher.bytesToFetch(target, in: directory) == Int64(weights.count))
        }
    }

    // ports: ArtifactFetcherTest#aFullAnswerToARangeRequestRestartsFromZero
    @Test func aFullAnswerToARangeRequestRestartsFromZero() async throws {
        let server = FakeServer { [weights] _ in FakeServer.Answer(200, weights) }
        try await withFolder { directory in
            // Not a prefix of the artifact: a restart must not keep any of it.
            try Data(repeating: 1, count: 50_000).write(to: part(directory))
            try await fetch(server, artifact(weights), directory)
            #expect(server.requests.map { $0["range"] } == ["bytes=50000-"])
            #expect(try Data(contentsOf: model(directory)) == weights)
        }
    }

    // ports: ArtifactFetcherTest#aWrongContentRangeTotalDeletesThePart
    @Test func aWrongContentRangeTotalDeletesThePart() async throws {
        let server = FakeServer(Self.ranged(weights, total: weights.count + 1))
        try await withFolder { directory in
            try weights.prefix(1000).write(to: part(directory))
            #expect(await failure { try await fetch(server, artifact(weights), directory) } == .modelVerify)
            #expect(!exists(part(directory)))
            #expect(!exists(model(directory)))
        }
    }

    // ports: ArtifactFetcherTest#aContentRangeForAnotherOffsetDeletesThePart
    @Test func aContentRangeForAnotherOffsetDeletesThePart() async throws {
        let server = FakeServer { [weights] _ in
            FakeServer.Answer(206, weights.subdata(in: 10..<weights.count),
                              headers: ["Content-Range": "bytes 10-\(weights.count - 1)/\(weights.count)",
                                        "ETag": Self.tag(weights)])
        }
        try await withFolder { directory in
            try weights.prefix(1000).write(to: part(directory))
            #expect(await failure { try await fetch(server, artifact(weights), directory) } == .modelVerify)
            #expect(!exists(part(directory)))
        }
    }

    // ports: ArtifactFetcherTest#aHashMismatchAfterResumingDeletesThePart
    @Test func aHashMismatchAfterResumingDeletesThePart() async throws {
        let server = FakeServer(Self.ranged(weights))
        try await withFolder { directory in
            // The right length, the wrong bytes: only the hash can tell.
            try Data(repeating: 9, count: 1000).write(to: part(directory))
            #expect(await failure { try await fetch(server, artifact(weights), directory) } == .modelVerify)
            #expect(!exists(part(directory)))
            #expect(!exists(model(directory)))
            // The next attempt starts over and succeeds.
            try await fetch(server, artifact(weights), directory)
            #expect(try Data(contentsOf: model(directory)) == weights)
        }
    }

    // ports: ArtifactFetcherTest#aPartLongerThanTheArtifactIsDiscarded
    @Test func aPartLongerThanTheArtifactIsDiscarded() async throws {
        let server = FakeServer(Self.ranged(weights))
        try await withFolder { directory in
            try Data(count: weights.count + 1).write(to: part(directory))
            try await fetch(server, artifact(weights), directory)
            #expect(server.requests.count == 1)
            #expect(server.requests.first?["range"] == nil)
            #expect(try Data(contentsOf: model(directory)) == weights)
        }
    }

    // ports: ArtifactFetcherTest#anUnsatisfiableRangeDeletesThePart (iOS: and the next attempt starts from zero)
    @Test func anUnsatisfiableRangeDeletesThePart() async throws {
        let attempts = Counter()
        let respond = Self.ranged(weights)
        let server = FakeServer { headers in
            attempts.next() == 1 ? FakeServer.Answer(416, Data(), headers: ["Content-Range": "bytes */1000"]) : respond(headers)
        }
        try await withFolder { directory in
            try weights.prefix(123_456).write(to: part(directory))
            #expect(await failure { try await fetch(server, artifact(weights), directory) } == .modelDownload)
            #expect(!exists(part(directory)))
            #expect(!exists(model(directory)))
            try await fetch(server, artifact(weights), directory)
            #expect(server.requests.map { $0["range"] } == ["bytes=123456-", nil], "the retry asks for the whole file")
            #expect(try Data(contentsOf: model(directory)) == weights)
        }
    }

    // ports: ArtifactFetcherTest#aServerErrorKeepsThePartForTheNextAttempt
    @Test func aServerErrorKeepsThePartForTheNextAttempt() async throws {
        let server = FakeServer { _ in FakeServer.Answer(503, Data()) }
        try await withFolder { directory in
            try weights.prefix(1000).write(to: part(directory))
            #expect(await failure { try await fetch(server, artifact(weights), directory) } == .modelDownload)
            #expect(length(part(directory)) == 1000)
        }
    }

    // ports: ArtifactFetcherTest#aVerifiedFileIsNeverReplacedOrDownloadedAgain
    @Test func aVerifiedFileIsNeverReplacedOrDownloadedAgain() async throws {
        let server = FakeServer { [weights] _ in FakeServer.Answer(200, Data(count: weights.count)) }
        try await withFolder { directory in
            try weights.write(to: model(directory))
            try await fetch(server, artifact(weights), directory)
            #expect(server.requests.isEmpty)
            #expect(try Data(contentsOf: model(directory)) == weights)
        }
    }

    // ports: ArtifactFetcherTest#aCompletePartIsVerifiedWithoutARequest
    @Test func aCompletePartIsVerifiedWithoutARequest() async throws {
        let server = FakeServer { _ in FakeServer.Answer(500, Data()) }
        try await withFolder { directory in
            try weights.write(to: part(directory))
            try await fetch(server, artifact(weights), directory)
            #expect(server.requests.isEmpty)
            #expect(try Data(contentsOf: model(directory)) == weights)
        }
    }

    /// Redirects within the fake server: plain HTTP to 127.0.0.1 or localhost.
    private let loopback = RedirectPolicy(hosts: ["127.0.0.1", "localhost"], httpsOnly: false)

    private static func redirect(_ location: String, _ status: Int = 302) -> FakeServer.Answer {
        FakeServer.Answer(status, Data(), headers: ["Location": location])
    }

    // ports: ArtifactFetcherTest#anAllowedRedirectChainIsFollowedAndKeepsTheRange
    @Test func anAllowedRedirectChainIsFollowedAndKeepsTheRange() async throws {
        let attempts = Counter()
        let respond = Self.ranged(weights)
        let port = 8_080
        let server = FakeServer { headers in
            switch attempts.next() {
            case 1: Self.redirect("http://localhost:\(port)/cdn")
            case 2: Self.redirect("/resolve-cache", 307)
            case 3: Self.redirect("http://127.0.0.1:\(port)/final", 301)
            default: respond(headers)
            }
        }
        #expect(server.port == port)
        try await withFolder { directory in
            try weights.prefix(1000).write(to: part(directory))
            try await fetch(server, artifact(weights), directory, loopback)
            #expect(try Data(contentsOf: model(directory)) == weights)
            #expect(server.requests.count == 4)
            #expect(server.requests.map { $0["range"] } == Array(repeating: "bytes=1000-", count: 4))
            let hosts = ["127.0.0.1:\(port)", "localhost:\(port)", "localhost:\(port)", "127.0.0.1:\(port)"]
            #expect(server.requests.map { $0["host"] } == hosts)
        }
    }

    // ports: ArtifactFetcherTest#aRedirectToAForeignHostFailsWithoutContactingItAndKeepsThePart
    @Test func aRedirectToAForeignHostFailsWithoutContactingItAndKeepsThePart() async throws {
        let server = FakeServer { _ in Self.redirect("https://example.com/model.onnx") }
        try await withFolder { directory in
            try weights.prefix(1000).write(to: part(directory))
            #expect(await failure { try await fetch(server, artifact(weights), directory) } == .modelDownload)
            #expect(server.requests.count == 1)
            #expect(length(part(directory)) == 1000)
            #expect(!exists(model(directory)))
        }
    }

    // ports: ArtifactFetcherTest#aRedirectToAHostOffTheListIsNeverFollowed
    @Test func aRedirectToAHostOffTheListIsNeverFollowed() async throws {
        // A transport that followed redirects itself would follow this one: same scheme, a host that answers.
        let onlyLoopbackAddress = RedirectPolicy(hosts: ["127.0.0.1"], httpsOnly: false)
        let attempts = Counter()
        let server = FakeServer { [weights] _ in
            attempts.next() == 1 ? Self.redirect("http://localhost:8080/elsewhere") : FakeServer.Answer(200, weights)
        }
        await withFolder { directory in
            #expect(await failure { try await fetch(server, artifact(weights), directory, onlyLoopbackAddress) }
                    == .modelDownload)
            #expect(server.requests.count == 1)
            #expect(!exists(model(directory)))
        }
    }

    // ports: ArtifactFetcherTest#aRedirectToPlainHttpIsRefusedEvenForAnAllowedHost
    @Test func aRedirectToPlainHttpIsRefusedEvenForAnAllowedHost() async {
        let httpsOnly = RedirectPolicy(hosts: ["127.0.0.1", "dist.gocassini.com"])
        let again = FakeServer { _ in Self.redirect("http://127.0.0.1:8080/again") }
        await withFolder { directory in
            #expect(await failure { try await fetch(again, artifact(weights), directory, httpsOnly) } == .modelDownload)
            #expect(again.requests.count == 1)
        }
        let host = FakeServer { _ in Self.redirect("http://dist.gocassini.com/models/files/x/model.onnx.zst") }
        await withFolder { directory in
            #expect(await failure { try await fetch(host, artifact(weights), directory) } == .modelDownload)
            #expect(host.requests.count == 1)
        }
    }

    // ports: ArtifactFetcherTest#moreThanFiveRedirectsFail
    @Test func moreThanFiveRedirectsFail() async {
        let server = FakeServer { _ in Self.redirect("/again") }
        await withFolder { directory in
            #expect(await failure { try await fetch(server, artifact(weights), directory, loopback) } == .modelDownload)
            #expect(server.requests.count == 1 + RedirectPolicy.maxRedirectsDefault)
            #expect(!exists(model(directory)))
        }
    }

    // ports: ArtifactFetcherTest#fiveRedirectsAreStillFollowed
    @Test func fiveRedirectsAreStillFollowed() async throws {
        let attempts = Counter()
        let server = FakeServer { [weights] _ in
            let attempt = attempts.next()
            return attempt <= RedirectPolicy.maxRedirectsDefault ? Self.redirect("/hop\(attempt)") : FakeServer.Answer(200, weights)
        }
        try await withFolder { directory in
            try await fetch(server, artifact(weights), directory, loopback)
            #expect(server.requests.count == 6)
            #expect(try Data(contentsOf: model(directory)) == weights)
        }
    }

    /// Checks that the verifying updates come after every download update, rise from 0 and end at `total`.
    private func expectChecking(_ events: [(Int64, Bool)], total: Int64) {
        guard let firstCheck = events.firstIndex(where: { $0.1 }) else {
            Issue.record("No verifying update")
            return
        }
        #expect(events[firstCheck...].allSatisfy { $0.1 })
        let checked = events[firstCheck...].map(\.0)
        #expect(checked.first == 0)
        #expect(checked.last == total)
        #expect(checked.sorted() == checked)
        #expect(checked.contains { (1..<total).contains($0) }, "\(checked)")
    }

    // ports: ArtifactFetcherTest#verifyingReportsTheBytesCheckedSoFar
    @Test func verifyingReportsTheBytesCheckedSoFar() async throws {
        let server = FakeServer(weights)
        try await withFolder { directory in
            var events: [(Int64, Bool)] = []
            try await fetcher(server).fetch(server.url, artifact(weights), into: directory) { events.append(($0, $1)) }
            #expect(events.first?.1 == false)
            expectChecking(events, total: Int64(weights.count))
        }
    }

    // ports: ArtifactFetcherTest#theDigestReportsEachStepAndTheEnd
    @Test func theDigestReportsEachStepAndTheEnd() throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let file = folder.file("cassini-digest.bin")
        try weights.write(to: file)
        var seen: [Int64] = []
        let hash = try ArtifactFetcher.digest(file) { seen.append($0) }
        #expect(hash == artifact(weights).sha256)
        #expect(seen.first == Int64(128 * 1024))
        #expect(seen.last == Int64(weights.count))
    }

    // ports: ArtifactFetcherTest#aCompressedDownloadChecksOnceFromZeroToItsSize
    /// Zstandard arrives with the speaker package; a stand-in format (every byte inverted) drives the same rules.
    @Test func aCompressedDownloadChecksOnceFromZeroToItsSize() async throws {
        let compressed = InvertedBytes.compress(weights)
        var download = artifact(compressed)
        download.name = "model.onnx.zst"
        let server = FakeServer(compressed)
        try await withFolder { directory in
            var events: [(Int64, Bool)] = []
            try await fetcher(server).fetchCompressed(server.url, download: download, artifact: artifact(weights),
                                                      into: directory, decoder: InvertedBytes()) {
                events.append(($0, $1))
            }
            #expect(try Data(contentsOf: model(directory)) == weights)
            #expect(!exists(directory.appendingPathComponent("model.onnx.zst")))
            expectChecking(events, total: Int64(compressed.count))
        }
    }

    // MARK: - The model host (D4): identity encoding, If-Range, entity tags

    // ports: ArtifactFetcherTest#everyRequestAsksForTheBytesThemselvesAndAResumeOnlyForTheSameFile
    @Test func everyRequestAsksForTheBytesThemselvesAndAResumeOnlyForTheSameFile() async throws {
        let server = FakeServer(Self.ranged(weights))
        try await withFolder { directory in
            try weights.prefix(1000).write(to: part(directory))
            try await fetch(server, artifact(weights), directory)
            let request = try #require(server.requests.first)
            #expect(server.requests.count == 1)
            #expect(request["accept-encoding"] == "identity")
            #expect(request["range"] == "bytes=1000-")
            // The model host's entity tag is the quoted SHA-256 of the file.
            #expect(request["if-range"] == "\"\(artifact(weights).sha256)\"")
        }
        let fresh = FakeServer(weights)
        try await withFolder { directory in
            try await fetch(fresh, artifact(weights), directory)
            #expect(try Data(contentsOf: model(directory)) == weights)
            #expect(fresh.requests.first?["accept-encoding"] == "identity")
            #expect(fresh.requests.first?["if-range"] == nil, "no If-Range without a kept part")
        }
    }

    /// Behind a proxy that strips entity tags: a transfer breaks, and the retry's whole answer without an entity tag
    /// restarts the kept part from zero and installs the file (Android's rule; the size and SHA-256 checks decide).
    @Test func aResumedWholeAnswerWithoutAnEntityTagRestartsAndTheRetrySucceeds() async throws {
        let attempts = Counter()
        let server = FakeServer { [weights] _ in
            attempts.next() == 1 ? FakeServer.Answer(200, weights, sent: 100_000) : FakeServer.Answer(200, weights)
        }
        try await withFolder { directory in
            #expect(await failure { try await fetch(server, artifact(weights), directory) } == .modelDownload)
            #expect(length(part(directory)) == 100_000)
            try await fetch(server, artifact(weights), directory)
            #expect(server.requests.map { $0["range"] } == [nil, "bytes=100000-"])
            #expect(try Data(contentsOf: model(directory)) == weights)
            #expect(!exists(part(directory)))
        }
    }

    /// A whole answer to a resumed request restarts from zero whatever its entity tag. One with the file's bytes
    /// installs it; one that is not the file (a captive portal) fails its check, which deletes the part, so the next
    /// attempt starts clean and succeeds.
    @Test func aWholeAnswerToAResumeRestartsWhateverItsEntityTag() async throws {
        let portal = FakeServer.Answer(200, Data("<html>sign in</html>".utf8))
        let fetched = FakeServer { [weights] _ in FakeServer.Answer(200, weights, headers: ["ETag": "\"another file\""]) }
        try await withFolder { directory in
            try Data(repeating: 1, count: 123_456).write(to: part(directory))
            try await fetch(fetched, artifact(weights), directory)
            #expect(fetched.requests.map { $0["range"] } == ["bytes=123456-"])
            #expect(try Data(contentsOf: model(directory)) == weights)
        }
        let attempts = Counter()
        let behindAPortal = FakeServer { [weights] _ in attempts.next() == 1 ? portal : FakeServer.Answer(200, weights) }
        try await withFolder { directory in
            try weights.prefix(123_456).write(to: part(directory))
            #expect(await failure { try await fetch(behindAPortal, artifact(weights), directory) } == .modelVerify)
            #expect(!exists(part(directory)))
            try await fetch(behindAPortal, artifact(weights), directory)
            #expect(behindAPortal.requests.map { $0["range"] } == ["bytes=123456-", nil])
            #expect(try Data(contentsOf: model(directory)) == weights)
        }
    }

    /// iOS only: an encoded answer counts other bytes than the file's, so it fails as a download error and the part
    /// stays; asking again from zero would not help.
    @Test func anEncodedWholeAnswerToAResumeKeepsThePart() async throws {
        let server = FakeServer { [weights] _ in
            FakeServer.Answer(200, weights, headers: ["ETag": Self.tag(weights), "Content-Encoding": "gzip"])
        }
        try await withFolder { directory in
            let kept = weights.prefix(123_456)
            try kept.write(to: part(directory))
            #expect(await failure { try await fetch(server, artifact(weights), directory) } == .modelDownload)
            #expect(try Data(contentsOf: part(directory)) == kept)
            #expect(!exists(model(directory)))
        }
    }

    /// iOS only: a partial answer without the file's entity tag (a proxy that strips it, a server that ignored
    /// If-Range) is not appended. It fails as a download error and deletes the part, so the next attempt asks for the
    /// whole file instead of failing the same way.
    @Test func aPartialAnswerWithoutTheFilesEntityTagDeletesThePart() async throws {
        for tag: String? in [nil, "\"another file\""] {
            let attempts = Counter()
            let server = FakeServer { [weights] _ in
                guard attempts.next() == 1 else { return FakeServer.Answer(200, weights) }
                var headers = ["Content-Range": "bytes 1000-\(weights.count - 1)/\(weights.count)"]
                headers["ETag"] = tag
                return FakeServer.Answer(206, weights.subdata(in: 1000..<weights.count), headers: headers)
            }
            try await withFolder { directory in
                try weights.prefix(1000).write(to: part(directory))
                #expect(await failure { try await fetch(server, artifact(weights), directory) } == .modelDownload)
                #expect(!exists(part(directory)), "\(tag ?? "no entity tag")")
                try await fetch(server, artifact(weights), directory)
                #expect(server.requests.map { $0["range"] } == ["bytes=1000-", nil])
                #expect(try Data(contentsOf: model(directory)) == weights)
            }
        }
    }

    /// iOS only: the bytes counted and hashed are the file's own, never a transfer encoding of them.
    @Test func anEncodedAnswerIsRefused() async {
        let server = FakeServer { [weights] _ in FakeServer.Answer(200, weights, headers: ["Content-Encoding": "br"]) }
        await withFolder { directory in
            #expect(await failure { try await fetch(server, artifact(weights), directory) } == .modelDownload)
            #expect(!exists(model(directory)))
        }
    }

    /// A part is named after the file it is the prefix of: a part of another revision of the same name, even of the
    /// same length, is never resumed or checked as this file.
    @Test func aPartOfAnotherFileIsNeverResumed() async throws {
        let server = FakeServer(Self.ranged(weights))
        try await withFolder { directory in
            let other = Data(repeating: 3, count: weights.count)
            try other.write(to: part(directory, other))
            try await fetch(server, artifact(weights), directory)
            #expect(server.requests.map { $0["range"] } == [nil])
            #expect(try Data(contentsOf: model(directory)) == weights)
        }
    }

    /// A cancel (or iOS ending the background time) while a checked download is decompressed keeps the download: the
    /// next attempt decompresses it again without a request, and counts none of its bytes as still to fetch, so it
    /// needs room for the decompressed file only.
    @Test func aCancelWhileDecompressingKeepsTheCheckedDownload() async throws {
        let compressed = InvertedBytes.compress(weights)
        var download = artifact(compressed)
        download.name = "model.onnx.zst"
        let server = FakeServer(compressed)
        let fetcher = fetcher(server), unpacked = artifact(weights), url = server.url, pinned = download
        try await withFolder { directory in
            let attempt = Task {
                await failure {
                    try await fetcher.fetchCompressed(url, download: pinned, artifact: unpacked, into: directory,
                                                      decoder: CancellingDecoder()) { _, _ in }
                }
            }
            #expect(await attempt.value == .cancelled)
            #expect(try Data(contentsOf: directory.appendingPathComponent("model.onnx.zst")) == compressed)
            #expect(!exists(model(directory)))
            #expect(ArtifactFetcher.bytesToFetch(download, in: directory) == 0)
            let offline = FakeServer { _ in FakeServer.Answer(500, Data()) }
            // Room for the decompressed file and the slack, not for the download again.
            let room = FakeStorage(availableBytes: Int64(weights.count) + ArtifactFetcher.slackBytes + 1)
            try await ArtifactFetcher(transport: offline, storage: room)
                .fetchCompressed(offline.url, download: download, artifact: artifact(weights), into: directory,
                                 decoder: InvertedBytes()) { _, _ in }
            #expect(offline.requests.isEmpty)
            #expect(try Data(contentsOf: model(directory)) == weights)
            #expect(!exists(directory.appendingPathComponent("model.onnx.zst")), "deleted once the file is in place")
        }
    }

    /// A disk that fills while a checked download is decompressed (a recording running beside the install) fails with
    /// SPACE (Not enough storage), not VERIFY: the download was checked, and it stays for the next attempt.
    @Test func aFullDiskWhileDecompressingFailsWithSpaceAndKeepsTheDownload() async throws {
        let compressed = InvertedBytes.compress(weights)
        var download = artifact(compressed)
        download.name = "model.onnx.zst"
        let server = FakeServer(compressed)
        try await withFolder { (directory: URL) async throws in
            for full: any Error in [POSIXError(.ENOSPC), CocoaError(.fileWriteOutOfSpace)] {
                let failed = await failure {
                    try await fetcher(server).fetchCompressed(server.url, download: download, artifact: artifact(weights),
                                                              into: directory, decoder: FullDiskDecoder(error: full)) { _, _ in }
                }
                #expect(failed == .space, "\(full)")
                #expect(try Data(contentsOf: directory.appendingPathComponent("model.onnx.zst")) == compressed)
                #expect(!exists(model(directory)))
                #expect(!exists(part(directory)), "the decompressed part is removed")
            }
            #expect(server.requests.count == 1, "the checked download is not fetched again")
        }
    }

    /// A local failure to write the decompressed file (not a full disk) fails with INSTALL, not VERIFY ("download
    /// damaged"): the download was checked and stays for the next attempt.
    @Test func aWriteErrorWhileDecompressingFailsWithInstallAndKeepsTheDownload() async throws {
        let compressed = InvertedBytes.compress(weights)
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let directory = folder.root
        let source = directory.appendingPathComponent("model.onnx.zst")
        try compressed.write(to: source)
        let output = ArtifactFetcher.partial(artifact(weights), in: directory)
        // The output's descriptor refuses writes after it is opened.
        let unwritable = UnwritableOutputDecoder(output: output)
        #expect(await failure {
            try ArtifactFetcher.decompress(source, artifact(weights), into: directory, decoder: unwritable)
        } == .modelInstall)
        #expect(unwritable.found.withLock { $0 }, "the decoder found the output's descriptor")
        #expect(!exists(output) && !exists(model(directory)))
        // The output cannot be created: a directory holds its name.
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        #expect(await failure {
            try ArtifactFetcher.decompress(source, artifact(weights), into: directory, decoder: InvertedBytes())
        } == .modelInstall)
        #expect(try Data(contentsOf: source) == compressed)
        #expect(!exists(model(directory)))
    }

    /// A stream the decoder cannot read fails with VERIFY and leaves no decompressed file.
    @Test func aStreamTheDecoderRefusesFailsWithVerify() async throws {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        let directory = folder.root
        let source = directory.appendingPathComponent("model.onnx.zst")
        try InvertedBytes.compress(weights).write(to: source)
        #expect(await failure {
            try ArtifactFetcher.decompress(source, artifact(weights), into: directory, decoder: DamagedStreamDecoder())
        } == .modelVerify)
        #expect(!exists(ArtifactFetcher.partial(artifact(weights), in: directory)) && !exists(model(directory)))
    }

    /// An install killed after a decompressed file was renamed into place but before its download was deleted: the
    /// next attempt finds the file checked, and deletes the download and its part instead of leaving them to take space.
    @Test func aDownloadLeftBesideItsCheckedFileIsDeleted() async throws {
        let compressed = InvertedBytes.compress(weights)
        var download = artifact(compressed)
        download.name = "model.onnx.zst"
        let server = FakeServer { _ in FakeServer.Answer(500, Data()) }
        try await withFolder { directory in
            try weights.write(to: model(directory))
            try compressed.write(to: directory.appendingPathComponent("model.onnx.zst"))
            try compressed.prefix(10).write(to: part(directory, compressed))
            try await fetcher(server).fetchCompressed(server.url, download: download, artifact: artifact(weights),
                                                      into: directory, decoder: InvertedBytes()) { _, _ in }
            #expect(server.requests.isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["model.onnx"])
        }
    }

    // ports: ArtifactFetcherTest#aSmallAnswerIsReadWholeAndALargerOneIsRefused
    @Test func aSmallAnswerIsReadWholeAndALargerOneIsRefused() async throws {
        let manifest = Data(#"{"schema_version":2}"#.utf8)
        let server = FakeServer(manifest)
        let read = fetcher(server)
        #expect(try await read.read(server.url, limit: 1024) == manifest)
        #expect(server.requests.first?["accept-encoding"] == "identity")
        #expect(await failure { _ = try await read.read(server.url, limit: Int64(manifest.count) - 1) } == .modelVerify)
        let missing = FakeServer(Data(), status: 404)
        #expect(await failure { _ = try await fetcher(missing).read(missing.url, limit: 1024) } == .modelDownload)
        let short = FakeServer { _ in FakeServer.Answer(200, manifest, sent: 5) }
        #expect(await failure { _ = try await fetcher(short).read(short.url, limit: 1024) } == .modelDownload)
    }

    // ports: ArtifactFetcherTest#aReadFollowsOnlyTheAllowedRedirects
    @Test func aReadFollowsOnlyTheAllowedRedirects() async {
        let server = FakeServer { _ in Self.redirect("https://example.com/manifest.json") }
        #expect(await failure { _ = try await fetcher(server).read(server.url, limit: 1024) } == .modelDownload)
        #expect(server.requests.count == 1)
    }

    /// The host's notices go into the model's directory as NOTICE.txt; an empty answer or one that is not text is
    /// refused and leaves no file.
    @Test func theNoticesAreKeptBesideTheModelOnlyWhenTheyAreText() async throws {
        let notices = Data("Parakeet Ultra 0.6B\n==============\n".utf8)
        let server = FakeServer(notices)
        try await withFolder { directory in
            try await fetcher(server).fetchNotice(server.url, into: directory)
            #expect(try Data(contentsOf: directory.appendingPathComponent("NOTICE.txt")) == notices)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["NOTICE.txt"])
        }
        for body in [Data(), Data([0xff, 0xfe, 0x00, 0xd8])] {
            let bad = FakeServer(body)
            try await withFolder { directory in
                let failed = await failure { try await fetcher(bad).fetchNotice(bad.url, into: directory) }
                #expect(failed == .modelVerify)
                let left = try FileManager.default.contentsOfDirectory(atPath: directory.path)
                #expect(left.isEmpty)
            }
        }
    }
}

/// A decoder whose task is cancelled while it writes its first block.
struct CancellingDecoder: Decompressing {
    func decompress(_ source: URL, into sink: (Data) throws -> Void) throws {
        withUnsafeCurrentTask { $0?.cancel() }
        try sink(Data(count: 16))
    }
}

/// A decoder whose output cannot be written: the disk is full.
struct FullDiskDecoder: Decompressing {
    let error: any Error

    func decompress(_ source: URL, into sink: (Data) throws -> Void) throws {
        try sink(Data(count: 16))
        throw error
    }
}

/// A decoder whose output descriptor refuses writes: it finds the descriptor open on `output` and puts a read-only one
/// in its place (`dup2`, so the number is never free for another file), then hands over a block.
final class UnwritableOutputDecoder: Decompressing {
    let output: URL
    let found = Mutex(false)

    init(output: URL) { self.output = output }

    func decompress(_ source: URL, into sink: (Data) throws -> Void) throws {
        guard let resolved = realpath(output.path, nil) else { throw POSIXError(.ENOENT) }
        let wanted = String(cString: resolved)
        free(resolved)
        let readOnly = open("/dev/null", O_RDONLY)
        defer { close(readOnly) }
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        for descriptor in 0..<getdtablesize() where descriptor != readOnly {
            guard fcntl(descriptor, F_GETPATH, &path) == 0, String(cString: path) == wanted else { continue }
            if dup2(readOnly, descriptor) >= 0 { found.withLock { $0 = true } }
        }
        try sink(Data(count: 16))
    }
}

/// A decoder that finds the stream damaged after its first block.
struct DamagedStreamDecoder: Decompressing {
    struct Damaged: Error {}

    func decompress(_ source: URL, into sink: (Data) throws -> Void) throws {
        try sink(Data(count: 16))
        throw Damaged()
    }
}

/// A stand-in compression for `fetchCompressed`: every byte inverted, decoded in 64 KiB blocks.
struct InvertedBytes: Decompressing {
    static func compress(_ data: Data) -> Data { Data(data.map { ~$0 }) }

    func decompress(_ source: URL, into sink: (Data) throws -> Void) throws {
        let data = try Data(contentsOf: source)
        var start = data.startIndex
        while start < data.endIndex {
            let end = min(start + 64 * 1024, data.endIndex)
            try sink(Self.compress(data.subdata(in: start..<end)))
            start = end
        }
    }
}
