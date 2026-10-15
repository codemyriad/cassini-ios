import Foundation
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

    /// Answers a Range request with the requested suffix of `body`, announcing `total` as the full length.
    private static func ranged(_ body: Data, total: Int? = nil) -> @Sendable ([String: String]) -> FakeServer.Answer {
        { headers in
            guard let range = headers["range"] else { return FakeServer.Answer(200, body) }
            let from = Int(range.dropFirst("bytes=".count).dropLast())!
            return FakeServer.Answer(206, body.subdata(in: from..<body.count),
                                     headers: ["Content-Range": "bytes \(from)-\(body.count - 1)/\(total ?? body.count)"])
        }
    }

    private func fetch(_ server: FakeServer, _ artifact: Artifact, _ directory: URL,
                       _ policy: RedirectPolicy = .downloads) async throws {
        try await fetcher(server).fetch(server.url, artifact, into: directory, redirects: policy) { _, _ in }
    }

    private func part(_ directory: URL) -> URL { directory.appendingPathComponent("model.onnx.part") }
    private func model(_ directory: URL) -> URL { directory.appendingPathComponent("model.onnx") }

    // ports: ArtifactFetcherTest#bytesThatDoNotMatchTheVoiceprintPinAreNotKept
    @Test func bytesThatDoNotMatchTheVoiceprintPinAreNotKept() async {
        let server = FakeServer(Data("voiceprint weights".utf8))
        await withFolder { directory in
            #expect(await failure { try await fetch(server, ModelCatalog.voiceprintModel, directory) } == .modelVerify)
            #expect(!exists(directory.appendingPathComponent(ModelCatalog.voiceprintModel.name)))
            #expect(!exists(directory.appendingPathComponent("\(ModelCatalog.voiceprintModel.name).part")))
        }
    }

    // ports: ArtifactFetcherTest#verifiedBytesAreInstalledAndPartialFilesAreRemoved
    @Test func verifiedBytesAreInstalledAndPartialFilesAreRemoved() async throws {
        let bytes = Data("model weights".utf8)
        let server = FakeServer(bytes)
        try await withFolder { directory in
            try await fetch(server, artifact(bytes), directory)
            #expect(try Data(contentsOf: model(directory)) == bytes)
            #expect(!exists(part(directory)))
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
            #expect(!exists(part(directory)))
        }
    }

    // ports: ArtifactFetcherTest#unavailableModelsReportDownloadFailureAndKeepNoPartial
    @Test func unavailableModelsReportDownloadFailureAndKeepNoPartial() async {
        let bytes = Data("missing model".utf8)
        let server = FakeServer(bytes, status: 404)
        await withFolder { directory in
            #expect(await failure { try await fetch(server, artifact(bytes), directory) } == .modelDownload)
            #expect(!exists(model(directory)))
            #expect(!exists(part(directory)))
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
                                     headers: ["Content-Range": "bytes \(from)-\(to - 1)/\(weights.count)"])
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
                              headers: ["Content-Range": "bytes 1000-\(weights.count)/\(weights.count)"])
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
                              headers: ["Content-Range": "bytes 10-\(weights.count - 1)/\(weights.count)"])
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

    // ports: ArtifactFetcherTest#anUnsatisfiableRangeDeletesThePart
    @Test func anUnsatisfiableRangeDeletesThePart() async throws {
        let server = FakeServer { _ in FakeServer.Answer(416, Data()) }
        try await withFolder { directory in
            try weights.prefix(1000).write(to: part(directory))
            #expect(await failure { try await fetch(server, artifact(weights), directory) } == .modelDownload)
            #expect(!exists(part(directory)))
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
        let httpsOnly = RedirectPolicy(hosts: ["127.0.0.1", "huggingface.co"])
        let again = FakeServer { _ in Self.redirect("http://127.0.0.1:8080/again") }
        await withFolder { directory in
            #expect(await failure { try await fetch(again, artifact(weights), directory, httpsOnly) } == .modelDownload)
            #expect(again.requests.count == 1)
        }
        let huggingFace = FakeServer { _ in Self.redirect("http://huggingface.co/repo/model") }
        await withFolder { directory in
            #expect(await failure { try await fetch(huggingFace, artifact(weights), directory) } == .modelDownload)
            #expect(huggingFace.requests.count == 1)
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
