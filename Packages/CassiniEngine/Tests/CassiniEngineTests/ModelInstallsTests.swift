import Foundation
import Synchronization
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// The standalone model installs and the stored model status, over fake models.
@MainActor @Suite struct ModelInstallsTests {
    @Test func aRefreshReadsEveryPartAndVoicesFollowTheSpeakerModels() async {
        let installs = ModelInstalls(transcriber: FakeTranscriber(.returns([], total: 0), status: .notDownloaded),
                                     analyzer: ScriptedAnalyzer(status: .ready), clock: FakeClock()) { "en-US" }
        #expect(installs.status(of: .speech) == nil, "nothing is shown before the first read")
        await installs.refresh()
        #expect(installs.status(of: .speech) == .notDownloaded)
        #expect(installs.status(of: .speakers) == .ready)
        #expect(installs.status(of: .voices) == .ready)
    }

    // ports: ModelInstallOwnerTest#aJobJoiningTheStandaloneDownloadFetchesEachArtifactOnce (the standalone side)
    @Test func aSecondDownloadWhileOneRunsJoinsIt() async throws {
        let analyzer = ScriptedAnalyzer(status: .notDownloaded, gated: true)
        let installs = ModelInstalls(transcriber: FakeTranscriber(.returns([], total: 0)), analyzer: analyzer,
                                     clock: FakeClock()) { "en-US" }
        await installs.refresh()
        installs.install([.speakers, .voices])
        try await until { analyzer.installs == 1 }
        installs.install([.speakers])
        #expect(installs.isInstalling)
        analyzer.report(0.4)
        try await until { installs.status(of: .speakers) == .downloading(0.4) }
        #expect(installs.status(of: .voices) == .downloading(0.4), "one install serves both parts")
        #expect(installs.download == DownloadFact(part: .speakers, fraction: 0.4, at: FakeClock().now))

        analyzer.finish(with: nil, status: .ready)
        try await until { !installs.isInstalling }
        #expect(analyzer.installs == 1)
        #expect(installs.download == nil)
        #expect(installs.status(of: .speakers) == .ready)
    }

    // ports: ModelInstallOwnerTest#downloadErrorsAndProgressMapToTheModelStatus
    @Test func aFailedDownloadShowsUntilTheNextInstallAndTellsTheSpaceItAskedFor() async throws {
        let analyzer = ScriptedAnalyzer(status: .notDownloaded, gated: true)
        let installs = ModelInstalls(transcriber: FakeTranscriber(.returns([], total: 0)), analyzer: analyzer,
                                     clock: FakeClock()) { "en-US" }
        await installs.refresh()
        installs.install([.speakers])
        try await until { analyzer.installs == 1 }
        analyzer.finish(with: .download(.notEnoughStorage, requiredFreeBytes: 55_000_000), status: .notDownloaded)
        try await until { !installs.isInstalling }
        #expect(installs.status(of: .speakers) == .failed(.notEnoughStorage))
        #expect(installs.download?.failure == .notEnoughStorage)
        #expect(installs.download?.requiredFreeBytes == 55_000_000)
        await installs.refresh()
        #expect(installs.status(of: .speakers) == .failed(.notEnoughStorage), "a refresh keeps the failure")

        installs.install([.speakers])
        #expect(installs.status(of: .speakers) == .downloading(nil), "the next install clears it")
        try await until { analyzer.installs == 2 }
        analyzer.finish(with: nil, status: .ready)
        try await until { !installs.isInstalling }
        #expect(installs.status(of: .speakers) == .ready)
    }

    @Test func theStandaloneDownloadInstallsSpeechThenTheSpeakerModels() async throws {
        let analyzer = ScriptedAnalyzer(status: .notDownloaded)
        let installs = ModelInstalls(transcriber: FakeTranscriber(.returns([], total: 0), status: .notDownloaded),
                                     analyzer: analyzer, clock: FakeClock()) { "it-IT" }
        installs.install([.speakers, .speech])
        try await until { !installs.isInstalling }
        #expect(analyzer.installs == 1)
        #expect(installs.download == nil)
        #expect(installs.stored.keys.count == 3, "the install ends with a refresh")
    }

    @Test func failuresMapToTheDownloadError() {
        #expect(ModelInstalls.failure(TranscriptionError.failed(.download(.noConnection))) == (.noConnection, 0))
        #expect(ModelInstalls.failure(SpeakerAnalysisError.download(.notEnoughStorage, requiredFreeBytes: 9)) == (.notEnoughStorage, 9))
        #expect(ModelInstalls.failure(CocoaError(.fileWriteUnknown)) == (.install, 0))
    }
}

/// A speaker analyzer whose install the test drives: it waits for `finish(with:status:)` when gated, else ends at once
/// (with `failure` when given).
private final class ScriptedAnalyzer: SpeakerAnalyzing {
    private struct State {
        var status: ModelPartStatus
        var installs = 0
        var progress: (@Sendable (Double?) -> Void)?
        var finish: CheckedContinuation<Void, Error>?
    }

    private let state: Mutex<State>
    private let gated: Bool

    init(status: ModelPartStatus, gated: Bool = false) {
        state = Mutex(State(status: status))
        self.gated = gated
    }

    var installs: Int { state.withLock { $0.installs } }

    func report(_ fraction: Double) { state.withLock { $0.progress }?(fraction) }

    func finish(with error: SpeakerAnalysisError?, status: ModelPartStatus) {
        let waiter = state.withLock { state in
            state.status = status
            defer { state.finish = nil }
            return state.finish
        }
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
    }

    func analyze(url: URL, allowDownload: Bool,
                 progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis {
        SpeakerAnalysis(turns: [], prints: [])
    }

    var modelIdentity: String? { get async { nil } }
    func modelStatus() async -> ModelPartStatus { state.withLock { $0.status } }
    func refreshModelStatus() async -> ModelPartStatus { state.withLock { $0.status } }

    func installModels(progress: @escaping @Sendable (Double?) -> Void) async throws {
        state.withLock { $0.installs += 1; $0.progress = progress }
        guard gated else { return }
        try await withCheckedThrowingContinuation { continuation in state.withLock { $0.finish = continuation } }
    }
}

/// Polls `condition` on the main actor until it holds, for at most five seconds.
@MainActor private func until(_ condition: @MainActor () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("The condition never held")
            return
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}
