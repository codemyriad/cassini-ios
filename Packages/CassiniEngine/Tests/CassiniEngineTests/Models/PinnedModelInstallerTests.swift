import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// Android's ModelInstallOwnerTest: one install at a time, a request for the same parts joins it, a request for other
/// parts waits for it, and every artifact is fetched once. The fetcher is a fake that writes sparse files of the pinned
/// sizes, so nothing is downloaded and almost no disk is used.
@MainActor @Suite final class PinnedModelInstallerTests {
    private static let partBytes = 1024
    private static let settle = Duration.milliseconds(300)

    private let folder = TemporaryFolder()
    private let suite = "cassini.tests.\(UUID().uuidString)"
    private let release = Gate()
    private let fetcher: GatedFetcher
    private let models: ModelRepository
    private let owner: PinnedModelInstaller

    init() async {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!, clock: FakeClock(), defaultLanguage: "en-US")
        fetcher = GatedFetcher(release: release)
        models = ModelRepository(root: folder.root.appendingPathComponent("models"), consent: settings, fetcher: fetcher)
        owner = PinnedModelInstaller(models: models, storage: FakeStorage(), online: { true })
        await models.recordConsent()
    }

    deinit {
        release.open()
        folder.remove()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private nonisolated static func key(_ model: ModelDescriptor) -> String { "\(model.directory)/\(model.markerFile)" }

    private let everyModel = ModelPart.allCases.flatMap(\.models).map(key).sorted()
    private let all = Set(ModelPart.allCases)
    private var allReady: [ModelPart: ModelStatus] { ModelPart.allCases.reduce(into: [:]) { $0[$1] = .ready } }

    private nonisolated static func waiters(_ owner: PinnedModelInstaller) -> Int? {
        if case .installing(_, _, _, let waiters) = owner.status { waiters } else { nil }
    }

    // ports: ModelInstallOwnerTest#aJobJoiningTheStandaloneDownloadFetchesEachArtifactOnce
    @Test func aJobJoiningTheStandaloneDownloadFetchesEachArtifactOnce() async throws {
        owner.startDownload()
        try await waitUntil { [fetcher] in fetcher.started }
        let progress = Mutex(0)
        let job = Task { [owner, all] in try await owner.install(all) { _ in progress.withLock { $0 += 1 } } }
        try await waitUntil { [owner] in Self.waiters(owner) == 2 }
        guard case .installing(_, _, let standalone, _) = owner.status else { return }
        #expect(standalone)

        release.open()
        #expect(try await job.value == .installed())
        #expect(fetcher.fetched.sorted() == everyModel)
        #expect(progress.withLock { $0 } > 0, "the job saw the shared progress")
        try await waitUntil { [owner] in owner.status == .idle }
        #expect(models.status == allReady)
    }

    // ports: ModelInstallOwnerTest#aRequestForOtherPartsWaitsAndFetchesNothingTwice
    @Test func aRequestForOtherPartsWaitsAndFetchesNothingTwice() async throws {
        owner.startDownload([.speech])
        try await waitUntil { [fetcher] in fetcher.started }
        let job = Task { [owner, all] in try await owner.install(all) }
        try await Task.sleep(for: Self.settle)
        #expect(fetcher.fetched == [Self.key(ModelCatalog.parakeet)], "the second install waits for the first")

        release.open()
        #expect(try await job.value == .installed())
        #expect(fetcher.fetched.sorted() == everyModel)
    }

    // ports: ModelInstallOwnerTest#cancelEndsEveryWaitAndKeepsThePartFiles
    @Test func cancelEndsEveryWaitAndKeepsThePartFiles() async throws {
        let download = owner.startDownload()
        try await waitUntil { [fetcher] in fetcher.started }
        let job = Task { [owner, all] in try await owner.install(all) }
        try await waitUntil { [owner] in Self.waiters(owner) == 2 }

        owner.cancel()
        await #expect(throws: CancellationError.self) { try await job.value }
        await download.value
        try await waitUntil { [owner] in owner.status == .idle }
        #expect(release.interrupted)
        let part = ModelCatalog.parakeet.directory(in: models.root).appendingPathComponent("encoder.int8.onnx.part")
        #expect(exists(part))
        #expect(models.status[.speech] == .missing(consented: true))
    }

    // ports: ModelInstallOwnerTest#aRequestRightAfterACancelWaitsForTheCancelledFetchToEnd
    @Test func aRequestRightAfterACancelWaitsForTheCancelledFetchToEnd() async throws {
        release.stubborn = true
        owner.startDownload()
        try await waitUntil { [fetcher] in fetcher.started }

        owner.cancel()
        let again = Task { [owner, all] in try await owner.install(all) }
        try await Task.sleep(for: Self.settle)
        #expect(release.interrupted)
        #expect(fetcher.fetched == [Self.key(ModelCatalog.parakeet)], "no second fetch while the first one runs")

        release.open()
        #expect(try await again.value == .installed())
        #expect(fetcher.mostInFlight == 1, "one fetch at a time")
        #expect(models.status == allReady)
    }

    // ports: ModelInstallOwnerTest#theInstallStopsWhenItsLastWaiterLeaves
    @Test func theInstallStopsWhenItsLastWaiterLeaves() async throws {
        let job = Task { [owner] in try await owner.install([.speech]) }
        try await waitUntil { [fetcher] in fetcher.started }
        job.cancel()
        _ = await job.result

        try await waitUntil { [owner] in owner.status == .idle }
        #expect(release.interrupted)
        #expect(fetcher.fetched == [Self.key(ModelCatalog.parakeet)])
    }

    // ports: ModelInstallOwnerTest#anInstallCancelledBeforeItsBodyRunsLeavesTheOwnerIdle
    @Test func anInstallCancelledBeforeItsBodyRunsLeavesTheOwnerIdle() async throws {
        // The only thread of the executor is busy, so the install is cancelled before its body runs.
        let executor = GatedExecutor()
        defer { executor.open() }
        let gated = PinnedModelInstaller(models: models, storage: FakeStorage(), online: { true }, executor: executor)
        let download = gated.startDownload([.speech])
        try await waitUntil { gated.status != .idle }
        gated.cancel()
        executor.open()
        await download.value
        try await waitUntil { gated.status == .idle }
        #expect(fetcher.fetched.isEmpty, "the cancelled install fetched nothing")

        release.open()
        #expect(try await gated.install([.speech]) == .installed())
        #expect(fetcher.fetched.sorted() == ModelPart.speech.models.map(Self.key).sorted())
        try await waitUntil { gated.status == .idle }
    }

    // ports: ModelInstallOwnerTest#downloadErrorsAndProgressMapToTheModelStatus
    @Test func downloadErrorsAndProgressMapToTheModelStatus() {
        #expect(DownloadError.notEnoughStorage.failure == .space)
        let progress = DownloadProgress(part: .speech, doneBytes: 50, totalBytes: 200, verifying: false)
        #expect(PinnedModelInstaller.statusOf(progress) == .downloading(percent: 25, bytes: 50, total: 200))
    }

    /// iOS ended the background time of the standalone download: its parts show "Download stopped".
    @Test func aStoppedDownloadShowsStoppedBySystemUntilTheNextInstall() async throws {
        owner.startDownload([.speech])
        try await waitUntil { [fetcher] in fetcher.started }
        #expect(await owner.stopDownloads())
        try await waitUntil { [owner] in owner.status == .idle }
        #expect(owner.lastOutcome == .failed(part: .speech, error: .stoppedBySystem, requiredFreeBytes: 0))
        #expect(models.status[.speech] == .failed(.modelDownload, detail: "STOPPED_BY_SYSTEM"))
        #expect(await !owner.stopDownloads(), "no standalone download runs")
    }
}

/// Blocks the fetch of Parakeet until `release` opens, after it wrote a `.part` file; records every fetch.
private final class GatedFetcher: ModelFetching, Sendable {
    private struct State {
        var fetched: [String] = []
        var inFlight = 0
        var mostInFlight = 0
        var started = false
    }

    private let release: Gate
    private let state = Mutex(State())

    init(release: Gate) { self.release = release }

    var fetched: [String] { state.withLock { $0.fetched } }
    var mostInFlight: Int { state.withLock { $0.mostInFlight } }
    var started: Bool { state.withLock { $0.started } }

    func fetch(_ model: ModelDescriptor, into directory: URL,
               progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
        state.withLock { state in
            state.fetched.append("\(model.directory)/\(model.markerFile)")
            state.inFlight += 1
            state.mostInFlight = max(state.mostInFlight, state.inFlight)
        }
        defer { state.withLock { $0.inFlight -= 1 } }
        if model == ModelCatalog.parakeet {
            let part = directory.appendingPathComponent("encoder.int8.onnx.part")
            try Data(count: 1024).write(to: part)
            state.withLock { $0.started = true }
            try await release.wait()
            try? FileManager.default.removeItem(at: part)
        }
        sparse(model, in: directory)
        progress(model.downloadBytes, false)
    }
}

/// The test's release of the blocked fetch. A cancelled wait ends with `CancellationError` and marks `interrupted`,
/// unless the gate is `stubborn`: then it ignores the cancel, as a socket read blocked until its timeout does.
private final class Gate: Sendable {
    private struct State {
        var open = false
        var interrupted = false
        var stubborn = false
        var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    }

    private let state = Mutex(State())

    var interrupted: Bool { state.withLock { $0.interrupted } }

    var stubborn: Bool {
        get { state.withLock { $0.stubborn } }
        set { state.withLock { $0.stubborn = newValue } }
    }

    func open() {
        let waiters = state.withLock { state in
            state.open = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async throws {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let go = state.withLock { state in
                    if Task.isCancelled { state.interrupted = true }
                    if state.open || (Task.isCancelled && !state.stubborn) { return true }
                    state.waiters[id] = continuation
                    return false
                }
                if go { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.interrupted = true
                return state.stubborn ? nil : state.waiters.removeValue(forKey: id)
            }
            waiter?.resume()
        }
        let (open, stubborn) = state.withLock { ($0.open, $0.stubborn) }
        if Task.isCancelled && !open && !stubborn { throw CancellationError() }
    }
}

/// A one-thread executor whose thread is busy until `open()`.
private final class GatedExecutor: TaskExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "cassini.tests.gated-executor")
    private let busy = DispatchSemaphore(value: 0)
    private let opened = Mutex(false)

    init() { queue.async { [busy] in busy.wait() } }

    func open() {
        let first = opened.withLock { opened in
            defer { opened = true }
            return !opened
        }
        if first { busy.signal() }
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        queue.async { job.runSynchronously(on: self.asUnownedTaskExecutor()) }
    }
}
