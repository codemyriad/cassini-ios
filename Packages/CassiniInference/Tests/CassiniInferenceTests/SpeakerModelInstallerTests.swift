import Foundation
import CryptoKit
import Synchronization
import Testing
import CassiniEngine
import CassiniInference
import CassiniNotebook

/// The speaker models' install over a fake fetch that writes a two-file manifest: one install at a time, joined by
/// later requests, checked file by file, with the free space checked before the first byte.
@Suite struct SpeakerModelInstallerTests {
    let directory: URL

    init() throws {
        directory = URL.temporaryDirectory.appendingPathComponent("installer-\(UUID().uuidString)", isDirectory: true)
    }

    // ports: ModelInstallOwnerTest#aJobJoiningTheStandaloneDownloadFetchesEachArtifactOnce
    @Test func aJobJoiningTheStandaloneDownloadFetchesEachFileOnce() async throws {
        let fetch = GatedFetch(writes: Fixture.files)
        let installer = makeInstaller(fetch)
        let standalone = Task { try await installer.install(allowDownload: true) }
        await fetch.started.wait()
        let progress = Counter()
        let job = Task { try await installer.install(allowDownload: false) { _ in progress.increment() } }
        try await until { await installer.waiting == 2 }
        try await until { await installer.status() == .downloading(0.5) }

        fetch.release()
        try await standalone.value
        try await job.value
        #expect(await installer.fetches == 1)
        #expect(fetch.calls == 1)
        #expect(progress.value > 0, "the job saw the shared progress")
        #expect(await installer.status() == .ready)
        try? FileManager.default.removeItem(at: directory)
    }

    // ports: ModelInstallOwnerTest#cancelEndsEveryWaitAndKeepsThePartFiles
    @Test func theInstallStopsWhenItsLastWaiterLeavesAndTheNextOneResumesItsFiles() async throws {
        let fetch = GatedFetch(writes: Fixture.files, partial: true)
        let installer = makeInstaller(fetch)
        let first = Task { try await installer.install(allowDownload: true) }
        await fetch.started.wait()
        let second = Task { try await installer.install(allowDownload: true) }
        try await until { await installer.waiting == 2 }

        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(!fetch.cancelled, "another caller still waits")
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        try await until { fetch.cancelled }
        try await until { await installer.waiting == 0 }
        try await until { await installer.status() == .notDownloaded }
        #expect(Fixture.manifest.check(in: directory) == .incomplete)

        // The next install keeps the finished file and FluidAudio's partial one for the fetch to resume.
        try await installer.install(allowDownload: true)
        #expect(fetch.calls == 2)
        #expect(fetch.found.last?.isSuperset(of: ["a.bin", "b.json.partial", ".fluidaudio-revision"]) == true)
        #expect(await installer.status() == .ready)
        try? FileManager.default.removeItem(at: directory)
    }

    // ports: ModelInstallOwnerTest#aRequestRightAfterACancelWaitsForTheCancelledFetchToEnd
    @Test func aRequestRightAfterACancelWaitsForTheCancelledFetchToEnd() async throws {
        let fetch = GatedFetch(writes: Fixture.files, stubborn: true)
        let installer = makeInstaller(fetch)
        let first = Task { try await installer.install(allowDownload: true) }
        await fetch.started.wait()
        try await until { await installer.waiting == 1 }

        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        try await until { fetch.cancelled }
        let again = Task { try await installer.install(allowDownload: true) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(fetch.calls == 1, "no second fetch while the first one runs")
        #expect(await installer.waiting == 0, "the request does not join the cancelled install")

        fetch.release()
        try await again.value
        #expect(fetch.calls == 2)
        #expect(fetch.mostInFlight == 1, "one fetch at a time")
        #expect(await installer.status() == .ready)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func aFileWithTheWrongHashGoesBeforeTheFetchAndTheMatchingOnesStay() async throws {
        let folder = directory.appendingPathComponent("models", isDirectory: true)
        var damaged = Fixture.files
        damaged["a.bin"] = Data(repeating: 8, count: 1000)
        try GatedFetch.write(damaged, marker: Fixture.manifest.revision, into: folder)
        #expect(Fixture.manifest.check(in: directory) == .mismatch)
        let fetch = GatedFetch(writes: Fixture.files, gated: false)
        try await makeInstaller(fetch).install(allowDownload: true)
        #expect(fetch.found == [["b.json", ".fluidaudio-revision"]])
        #expect(Fixture.manifest.check(in: directory) == .ready)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func filesOfAnotherRevisionGoBeforeTheFetch() async throws {
        let folder = directory.appendingPathComponent("models", isDirectory: true)
        try GatedFetch.write(Fixture.files, marker: "another", into: folder)
        let fetch = GatedFetch(writes: Fixture.files, gated: false)
        try await makeInstaller(fetch).install(allowDownload: true)
        #expect(fetch.found == [[]])
        #expect(Fixture.manifest.check(in: directory) == .ready)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func theProgressReachesEveryCallerInTheOrderTheFetchSentIt() async throws {
        let fractions = (1...200).map { Double($0) / 200 }
        let fetch = GatedFetch(writes: Fixture.files, gated: false, fractions: fractions)
        let seen = Mutex<[Double]>([])
        try await makeInstaller(fetch).install(allowDownload: true) { fraction in
            if let fraction { seen.withLock { $0.append(fraction) } }
        }
        #expect(seen.withLock { $0 } == fractions + [1])
        try? FileManager.default.removeItem(at: directory)
    }

    // ports: ModelInstallerTest#notEnoughSpaceFailsSpeechBeforeTheFirstByte
    @Test func notEnoughSpaceFailsBeforeTheFirstByte() async throws {
        let fetch = GatedFetch(writes: Fixture.files, gated: false)
        let required = Fixture.manifest.requiredFreeBytes
        let installer = makeInstaller(fetch, freeBytes: required - 1)
        await #expect(throws: SpeakerAnalysisError.download(.notEnoughStorage, requiredFreeBytes: required)) {
            try await installer.install(allowDownload: true)
        }
        #expect(fetch.calls == 0)
        #expect(await installer.status() == .failed(.notEnoughStorage))
        #expect(required == Fixture.manifest.totalBytes + 32 * 1024 * 1024)

        let roomy = makeInstaller(GatedFetch(writes: Fixture.files, gated: false), freeBytes: required)
        try await roomy.install(allowDownload: true)
        #expect(await roomy.status() == .ready)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func withoutConsentNothingIsFetched() async throws {
        let fetch = GatedFetch(writes: Fixture.files, gated: false)
        let installer = makeInstaller(fetch)
        await #expect(throws: SpeakerAnalysisError.needsConsent) { try await installer.install(allowDownload: false) }
        #expect(fetch.calls == 0)
        #expect(await installer.status() == .notDownloaded)
    }

    @Test func aFileThatDoesNotMatchTheManifestFailsTheCheckAndIsRemoved() async throws {
        var damaged = Fixture.files
        damaged["b.json"] = Data("tampered".utf8)
        let fetch = GatedFetch(writes: damaged, holdFrom: 2)
        let installer = makeInstaller(fetch)
        await #expect(throws: SpeakerAnalysisError.download(.fileCheckFailed, requiredFreeBytes: 0)) {
            try await installer.install(allowDownload: true)
        }
        #expect(await installer.status() == .failed(.fileCheckFailed))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("models").path))
        #expect(await installer.refresh() == .failed(.fileCheckFailed), "the failure stays until the next install")

        // The next install on the same installer clears it, fetches again and succeeds.
        fetch.writes(Fixture.files)
        let retry = Task { try await installer.install(allowDownload: true) }
        try await until { fetch.calls == 2 }
        try await until { await installer.status() == .downloading(0.5) }
        fetch.release()
        try await retry.value
        #expect(await installer.status() == .ready)
        #expect(await installer.refresh() == .ready)
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func installedFilesAreCheckedAgainstTheManifestAndTheRevision() throws {
        let folder = directory.appendingPathComponent("models", isDirectory: true)
        #expect(Fixture.manifest.check(in: directory) == .missing)
        try GatedFetch.write(Fixture.files, marker: Fixture.manifest.revision, into: folder)
        #expect(Fixture.manifest.check(in: directory) == .ready)
        #expect(Fixture.manifest.looksReady(in: directory))
        try FileManager.default.removeItem(at: folder.appendingPathComponent("b.json"))
        #expect(Fixture.manifest.check(in: directory) == .incomplete, "an interrupted install is resumed, not removed")
        #expect(!Fixture.manifest.looksReady(in: directory))
        try GatedFetch.write(Fixture.files, marker: Fixture.manifest.revision, into: folder)
        try Data("other".utf8).write(to: folder.appendingPathComponent(".fluidaudio-revision"))
        #expect(Fixture.manifest.check(in: directory) == .mismatch, "files of another revision are not used")
        try? FileManager.default.removeItem(at: directory)
    }

    // ports: ModelInstallOwnerTest#downloadErrorsAndProgressMapToTheModelStatus
    // ports: ModelInstallerTest#errorsMapToTheDownloadBanners
    @Test func errorsMapToTheDownloadBanners() {
        func map(_ error: Error) -> DownloadError { SpeakerModelInstaller.downloadError(error) }
        #expect(map(URLError(.timedOut)) == .noConnection)
        #expect(map(URLError(.notConnectedToInternet)) == .noConnection)
        #expect(map(URLError(.cannotFindHost)) == .noConnection)
        #expect(map(URLError(.networkConnectionLost)) == .interrupted)
        #expect(map(URLError(.badServerResponse)) == .interrupted)
        #expect(map(NSError(domain: "HTTP", code: 503)) == .interrupted)
        #expect(map(CocoaError(.fileWriteOutOfSpace)) == .notEnoughStorage)
        #expect(map(POSIXError(.ENOSPC)) == .notEnoughStorage)
        #expect(map(CocoaError(.fileWriteNoPermission)) == .install)
        let wrapped = NSError(domain: "Wrapper", code: 1, userInfo: [NSUnderlyingErrorKey: URLError(.timedOut)])
        #expect(map(wrapped) == .noConnection)
    }

    @Test func theProgressOfTheRunningInstallIsItsStatus() async throws {
        let fetch = GatedFetch(writes: Fixture.files)
        let installer = makeInstaller(fetch)
        let install = Task { try await installer.install(allowDownload: true) }
        await fetch.started.wait()
        try await until { await installer.status() == .downloading(0.5) }
        fetch.release()
        try await install.value
        #expect(await installer.status() == .ready)
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeInstaller(_ fetch: GatedFetch, freeBytes: Int64 = .max) -> SpeakerModelInstaller {
        SpeakerModelInstaller(manifest: Fixture.manifest, directory: directory, storage: FixedStorage(bytes: freeBytes),
                              network: ModelNetworkGate { _ in }, fetch: fetch.fetch)
    }
}

/// The analyses over installed models, with a fake analysis in place of FluidAudio's.
@Suite struct SpeakerAnalyzerQueueTests {
    let directory = URL.temporaryDirectory.appendingPathComponent("analyzer-\(UUID().uuidString)", isDirectory: true)

    @Test func aSecondAnalysisWaitsForTheFirstAndBothSucceed() async throws {
        let first = Latch()
        let state = Mutex((running: 0, most: 0, order: [String]()))
        let installer = SpeakerModelInstaller(manifest: Fixture.manifest, directory: directory,
                                              storage: FixedStorage(bytes: .max), network: ModelNetworkGate { _ in },
                                              fetch: GatedFetch(writes: Fixture.files, gated: false).fetch)
        let analyzer = SpeakerAnalyzer(installer: installer, network: ModelNetworkGate { _ in }) { url, _, _ in
            let name = url.lastPathComponent
            state.withLock { $0.running += 1; $0.most = max($0.most, $0.running); $0.order.append(name) }
            defer { state.withLock { $0.running -= 1 } }
            if name == "one.m4a" { await first.wait() }
            return SpeakerAnalysis(turns: [SpeakerTurn(speakerID: name, start: 0, end: 1)], prints: [])
        }
        let one = Task { try await analyzer.analyze(url: URL(filePath: "/tmp/one.m4a"), allowDownload: true) { _ in } }
        try await until { state.withLock { $0.order } == ["one.m4a"] }
        let two = Task { try await analyzer.analyze(url: URL(filePath: "/tmp/two.m4a"), allowDownload: true) { _ in } }
        try await Task.sleep(for: .milliseconds(50))
        #expect(state.withLock { $0.order } == ["one.m4a"], "the second analysis waits its turn")

        first.open()
        #expect(try await one.value.turns.map(\.speakerID) == ["one.m4a"])
        #expect(try await two.value.turns.map(\.speakerID) == ["two.m4a"])
        #expect(state.withLock { $0.most } == 1)
        #expect(await installer.fetches == 1, "the models are installed once")
        try? FileManager.default.removeItem(at: directory)
    }
}

/// FluidAudio's single offline switch: overlapping downloads keep it off until the last one ends.
@Suite struct ModelNetworkGateTests {
    @Test func aDownloadThatEndsDoesNotCloseTheNetworkUnderAnotherOne() async throws {
        let changes = Mutex<[Bool]>([])
        let gate = ModelNetworkGate { offline in changes.withLock { $0.append(offline) } }
        gate.close()
        let first = Latch(), second = Latch(), firstDone = Latch()
        let a = Task { try await gate.allowingDownloads { first.open(); await firstDone.wait() } }
        await first.wait()
        let b = Task { try await gate.allowingDownloads { second.open(); try await Task.sleep(for: .milliseconds(50)) } }
        await second.wait()
        firstDone.open()
        try await a.value
        #expect(gate.isOpen, "the second download still runs")
        #expect(changes.withLock { $0 } == [true, false])
        try await b.value
        #expect(!gate.isOpen)
        #expect(changes.withLock { $0 } == [true, false, true])
        gate.close()
        #expect(changes.withLock { $0 }.last == true)
    }

    @Test func theNetworkClosesWhenTheDownloadFails() async {
        let offline = Mutex(true)
        let gate = ModelNetworkGate { value in offline.withLock { $0 = value } }
        struct Failure: Error {}
        await #expect(throws: Failure.self) { try await gate.allowingDownloads { throw Failure() } }
        #expect(offline.withLock { $0 })
    }
}

/// The pinned manifest of the app's speaker models.
@Suite struct SpeakerModelManifestTests {
    @Test func theDiarizerIsPinnedToOneRevisionWithAHashForEveryFile() {
        let manifest = SpeakerModelManifest.diarizer
        #expect(manifest.revision.count == 40 && manifest.revision.allSatisfy(\.isHexDigit))
        #expect(manifest.files.count == 21)
        #expect(manifest.files.allSatisfy { $0.sha256.count == 64 && $0.bytes > 0 })
        #expect(Set(manifest.files.map(\.path)).count == manifest.files.count)
        for model in ["Segmentation", "FBank", "Embedding", "PldaRho"] {
            #expect(manifest.files.contains { $0.path == "\(model).mlmodelc/weights/weight.bin" })
        }
        #expect(manifest.files.contains { $0.path == "plda-parameters.json" })
        #expect(manifest.downloads.allSatisfy { $0.url.host() == "huggingface.co" && $0.url.path().contains(manifest.revision) })
        #expect(SpeakerModelManifest.downloadHosts == ["huggingface.co", "*.huggingface.co", "*.hf.co"])
    }
}

// MARK: - Fixtures

private enum Fixture {
    static let files: [String: Data] = ["a.bin": Data(repeating: 7, count: 1000), "b.json": Data("{\"psi\":1}".utf8)]

    static let manifest = SpeakerModelManifest(
        repository: "test/models", revision: "0123456789abcdef0123456789abcdef01234567", folder: "models",
        marker: ".fluidaudio-revision",
        files: files.keys.sorted().map { name in
            let data = files[name]!
            return .init(name, bytes: Int64(data.count),
                         sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        })
}

/// A fetch that reports half the download, then waits for `release()` before it writes the files. Calls from
/// `holdFrom` on wait (all of them by default); a stubborn fetch keeps waiting for `release()` when it is cancelled.
private final class GatedFetch: Sendable {
    private struct State {
        var calls = 0
        var cancelled = false
        var inFlight = 0
        var mostInFlight = 0
        var files: [String: Data]
        /// The model folder's files when each call began.
        var found: [Set<String>] = []
    }

    let started = Latch()
    private let gate = Latch()
    private let state: Mutex<State>
    private let held: Bool
    private let holdFrom: Int
    private let partial: Bool
    private let stubborn: Bool
    private let fractions: [Double]

    init(writes files: [String: Data], gated: Bool = true, holdFrom: Int = 1, partial: Bool = false,
         stubborn: Bool = false, fractions: [Double] = [0.5]) {
        state = Mutex(State(files: files))
        held = gated
        self.holdFrom = holdFrom
        self.partial = partial
        self.stubborn = stubborn
        self.fractions = fractions
    }

    var calls: Int { state.withLock { $0.calls } }
    var cancelled: Bool { state.withLock { $0.cancelled } }
    var mostInFlight: Int { state.withLock { $0.mostInFlight } }
    var found: [Set<String>] { state.withLock { $0.found } }
    func release() { gate.open() }
    func writes(_ files: [String: Data]) { state.withLock { $0.files = files } }

    var fetch: SpeakerModelInstaller.Fetch {
        { [self] directory, progress in
            let folder = directory.appendingPathComponent("models", isDirectory: true)
            let present = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            let call = state.withLock { state in
                state.calls += 1
                state.inFlight += 1
                state.mostInFlight = max(state.mostInFlight, state.inFlight)
                state.found.append(present)
                return state.calls
            }
            defer { state.withLock { $0.inFlight -= 1 } }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if partial {
                // As FluidAudio leaves an interrupted download: the marker, one finished file and a partial one.
                try Self.write(["a.bin": Fixture.files["a.bin"]!], marker: Fixture.manifest.revision, into: folder)
                try Data([1]).write(to: folder.appendingPathComponent("b.json.partial"))
            }
            for fraction in fractions { progress(fraction) }
            started.open()
            if held, call >= holdFrom {
                await withTaskCancellationHandler {
                    await gate.wait()
                } onCancel: {
                    self.state.withLock { $0.cancelled = true }
                    if !self.stubborn { self.gate.open() }
                }
            }
            try Task.checkCancellation()
            try Self.write(state.withLock { $0.files }, marker: Fixture.manifest.revision, into: folder)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent("b.json.partial"))
            progress(1)
        }
    }

    static func write(_ files: [String: Data], marker: String, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, data) in files { try data.write(to: folder.appendingPathComponent(name)) }
        try Data(marker.utf8).write(to: folder.appendingPathComponent(".fluidaudio-revision"))
    }
}

/// Opens once; every wait before or after returns once it is open.
final class Latch: Sendable {
    private let state = Mutex<(open: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = state.withLock { state in
                if state.open { return true }
                state.waiters.append(continuation)
                return false
            }
            if resume { continuation.resume() }
        }
    }
}

private final class Counter: Sendable {
    private let count = Mutex(0)
    func increment() { count.withLock { $0 += 1 } }
    var value: Int { count.withLock { $0 } }
}

private struct FixedStorage: StorageProbe {
    let bytes: Int64
    func availableBytes(at url: URL) -> Int64 { bytes }
}

/// Polls `condition` until it holds, for at most five seconds.
private func until(_ condition: @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !(await condition()) {
        guard ContinuousClock.now < deadline else {
            Issue.record("The condition never held")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}
