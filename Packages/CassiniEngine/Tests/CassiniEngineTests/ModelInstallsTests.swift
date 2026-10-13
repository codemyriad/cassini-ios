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

    // ports: ModelInstallOwnerTest#aRequestForOtherPartsWaitsAndFetchesNothingTwice
    @Test func aRequestForOtherPartsWhileOneRunsInstallsThemAfterIt() async throws {
        let analyzer = ScriptedAnalyzer(status: .notDownloaded, gated: true)
        let transcriber = LanguageTranscriber(["en-US": .notDownloaded], gated: true)
        let installs = ModelInstalls(transcriber: transcriber, analyzer: analyzer, clock: FakeClock()) { "en-US" }
        installs.install([.speech])
        try await until { transcriber.installs == 1 }
        installs.install([.speech, .speakers])
        #expect(analyzer.installs == 0, "the second request waits for the first")
        transcriber.finish(status: .ready)
        try await until { analyzer.installs == 1 }
        #expect(installs.status(of: .speakers) == .downloading(nil))
        analyzer.finish(with: nil, status: .ready)
        try await until { !installs.isInstalling }
        #expect(transcriber.installs == 1, "nothing is fetched twice")
        #expect(analyzer.installs == 1)
        #expect(installs.status(of: .speech) == .ready)
        #expect(installs.status(of: .speakers) == .ready)
    }

    @Test func aFailedPartAskedForDuringTheClosingRefreshIsInstalledAgain() async throws {
        let analyzer = ScriptedAnalyzer(status: .notDownloaded)
        let transcriber = LanguageTranscriber(["en-US": .notDownloaded], gatedStatus: true, failsInstall: true)
        let installs = ModelInstalls(transcriber: transcriber, analyzer: analyzer, clock: FakeClock()) { "en-US" }
        installs.install([.speech, .speakers])
        try await until { transcriber.waitingReads == 1 }
        #expect(analyzer.installs == 1, "the closing refresh runs")
        #expect(installs.status(of: .speech) == .failed(.noConnection), "the failed row can be tapped")

        installs.install([.speech])
        try await until { transcriber.releaseReads(); return !installs.isInstalling }
        #expect(transcriber.installs == 2, "the request was not lost")
        installs.install([.speech])
        try await until { transcriber.releaseReads(); return !installs.isInstalling }
        #expect(transcriber.installs == 3, "nor is any later one")
    }

    @Test func aFailedPartThatSucceedsWhenAskedForAgainEndsWithoutItsFailure() async throws {
        let analyzer = ScriptedAnalyzer(status: .notDownloaded)
        let transcriber = LanguageTranscriber(["en-US": .notDownloaded], gatedStatus: true, failsInstall: true)
        let installs = ModelInstalls(transcriber: transcriber, analyzer: analyzer, clock: FakeClock()) { "en-US" }
        installs.install([.speech])
        try await until { transcriber.waitingReads == 1 }
        #expect(installs.download?.failure == .noConnection)

        transcriber.failsInstall = false
        transcriber.set("en-US", .ready)
        installs.install([.speech])
        #expect(installs.download == DownloadFact(part: .speech, at: FakeClock().now), "the notice shows the new install")
        #expect(installs.status(of: .speech) == .downloading(nil), "and so does the row")
        try await until { transcriber.releaseReads(); return !installs.isInstalling }
        #expect(transcriber.installs == 2)
        #expect(installs.download == nil, "the earlier failure is not told")
        #expect(installs.status(of: .speech) == .ready)
    }

    @Test func anotherPartAskedForDuringTheClosingRefreshIsInstalled() async throws {
        let analyzer = ScriptedAnalyzer(status: .notDownloaded)
        let transcriber = LanguageTranscriber(["en-US": .notDownloaded], gatedStatus: true)
        let installs = ModelInstalls(transcriber: transcriber, analyzer: analyzer, clock: FakeClock()) { "en-US" }
        installs.install([.speech])
        try await until { transcriber.waitingReads == 1 }
        #expect(transcriber.installs == 1)

        installs.install([.speakers])
        #expect(installs.isInstalling)
        try await until { transcriber.releaseReads(); return analyzer.installs == 1 }
        try await until { transcriber.releaseReads(); return !installs.isInstalling }
        #expect(analyzer.installs == 1)
        #expect(transcriber.installs == 1)
    }

    @Test func cancelStopsTheSpeakerModelsForEveryCallerAndIsNoFailure() async throws {
        let analyzer = ScriptedAnalyzer(status: .notDownloaded, gated: true)
        let installs = ModelInstalls(transcriber: FakeTranscriber(.returns([], total: 0), status: .notDownloaded),
                                     analyzer: analyzer, clock: FakeClock()) { "en-US" }
        await installs.refresh()
        installs.install([.speakers, .speech])
        try await until { analyzer.installs == 1 }
        installs.cancel()
        #expect(!installs.isInstalling)
        #expect(installs.download == nil)
        try await until { analyzer.cancels == 1 }
        // Let the cancelled install end and read the models again.
        try await Task.sleep(for: .milliseconds(50))
        #expect(installs.failures.isEmpty)
        #expect(installs.status(of: .speakers) == .notDownloaded)
        #expect(installs.download == nil, "the cancelled install's end shows nothing")

        installs.install([.speakers])
        try await until { analyzer.installs == 2 }
        analyzer.finish(with: nil, status: .ready)
        try await until { !installs.isInstalling }
        #expect(installs.status(of: .speakers) == .ready)
    }

    @Test func cancelStopsTheSpeechInstallAndDropsTheParts() async throws {
        let analyzer = ScriptedAnalyzer(status: .notDownloaded)
        let transcriber = LanguageTranscriber(["en-US": .notDownloaded], gated: true)
        let installs = ModelInstalls(transcriber: transcriber, analyzer: analyzer, clock: FakeClock()) { "en-US" }
        installs.install([.speech, .speakers])
        try await until { transcriber.installs == 1 }
        installs.cancel()
        try await until { transcriber.cancelled }
        // The cancelled install ends by reading the models again; nothing is installed after that read.
        try await until { installs.status(of: .speech) == .notDownloaded }
        try await Task.sleep(for: .milliseconds(50))
        #expect(analyzer.installs == 0, "the parts after the cancelled one are dropped")
        #expect(analyzer.cancels == 0, "the speaker models' install was not running")
        #expect(installs.failures.isEmpty)
        #expect(installs.status(of: .speech) == .notDownloaded)
    }

    @Test func aRefreshAskedForDuringAnotherReadsAgainOnceItEnds() async throws {
        let analyzer = ScriptedAnalyzer(status: .notDownloaded)
        let transcriber = LanguageTranscriber(["en-US": .notDownloaded], gatedStatus: true)
        let installs = ModelInstalls(transcriber: transcriber, analyzer: analyzer, clock: FakeClock()) { "en-US" }
        let early = Task { await installs.refresh() }
        try await until { transcriber.waitingReads == 1 }
        // The models change while the first read runs, before the second refresh is asked for.
        transcriber.set("en-US", .ready)
        analyzer.finish(with: nil, status: .ready)
        let late = Task { await installs.refresh() }
        transcriber.releaseReads()
        try await until { transcriber.waitingReads == 1 }
        transcriber.releaseReads()
        await early.value
        await late.value
        #expect(installs.status(of: .speech) == .ready, "the late refresh read again")
        #expect(installs.status(of: .speakers) == .ready)
    }

    @Test func aNewSpeechLanguageIsReadAgainAndDropsTheOldLanguagesFailure() async throws {
        let language = Language("en-US")
        let transcriber = LanguageTranscriber(["en-US": .ready, "it-IT": .notDownloaded], failsInstall: true)
        let installs = ModelInstalls(transcriber: transcriber, analyzer: ScriptedAnalyzer(status: .ready),
                                     clock: FakeClock()) { language.value }
        await installs.refresh()
        #expect(installs.status(of: .speech) == .ready)

        language.value = "it-IT"
        try await until { installs.status(of: .speech) == .notDownloaded }
        installs.install([.speech])
        try await until { !installs.isInstalling }
        #expect(installs.status(of: .speech) == .failed(.noConnection))

        language.value = "en-US"
        try await until { installs.status(of: .speech) == .ready }
        transcriber.set("en-US", .notDownloaded)
        await installs.refresh()
        #expect(installs.status(of: .speech) == .notDownloaded, "Italian's failure is not English's")
        #expect(installs.failures[.speech] == nil)
    }

    @Test func theRowsShowTheRunningJobsDownloadAndReadAgainWhenItEnds() async throws {
        let analyzer = ScriptedAnalyzer(status: .notDownloaded)
        let job = JobProgress()
        let installs = ModelInstalls(transcriber: FakeTranscriber(.returns([], total: 0)), analyzer: analyzer,
                                     clock: FakeClock(), job: job) { "en-US" }
        await installs.refresh()
        #expect(installs.statuses == [.speech: .ready, .speakers: .notDownloaded, .voices: .notDownloaded])

        job.begin(UUID(), finalizationMs: nil)
        job.apply(.downloading(DownloadProgress(part: .speakers, doneBytes: 30, totalBytes: 100, verifying: false)))
        #expect(installs.statuses == [.speech: .ready, .speakers: .downloading(0.3), .voices: .downloading(0.3)],
                "recognising saved voices follows the speaker models' download")
        // Give the follower a turn to see the download before it ends.
        try await Task.sleep(for: .milliseconds(50))
        analyzer.finish(with: nil, status: .ready)
        job.end()
        try await until { installs.status(of: .speakers) == .ready }
        #expect(installs.statuses == [.speech: .ready, .speakers: .ready, .voices: .ready])
    }

    @Test func aJobsDownloadShowsOnlyOnRowsThatWereRead() {
        let speech = DownloadProgress(part: .speech, doneBytes: 1, totalBytes: 2, verifying: false)
        #expect(ModelInstalls.statuses([.speech: .notDownloaded], during: speech) == [.speech: .downloading(0.5)])
        let speakers = DownloadProgress(part: .speakers, doneBytes: 1, totalBytes: 2, verifying: true)
        #expect(ModelInstalls.statuses([.speech: .ready, .speakers: .failed(.interrupted), .voices: .failed(.interrupted)],
                                       during: speakers) == [.speech: .ready, .speakers: .checking, .voices: .checking])
        #expect(ModelInstalls.statuses([:], during: speakers).isEmpty)
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
        var progress: (@Sendable (InstallProgress) -> Void)?
        var finish: CheckedContinuation<Void, Error>?
        var cancels = 0
    }

    private let state: Mutex<State>
    private let gated: Bool

    init(status: ModelPartStatus, gated: Bool = false) {
        state = Mutex(State(status: status))
        self.gated = gated
    }

    var installs: Int { state.withLock { $0.installs } }
    var cancels: Int { state.withLock { $0.cancels } }

    func report(_ fraction: Double) { state.withLock { $0.progress }?(.downloading(fraction)) }

    func reportChecking() { state.withLock { $0.progress }?(.checking) }

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

    var modelInstallBytes: Int64 { 54_000_000 }

    func installModels(progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        state.withLock { $0.installs += 1; $0.progress = progress }
        guard gated else { return }
        try await withCheckedThrowingContinuation { continuation in state.withLock { $0.finish = continuation } }
    }

    /// Ends the gated install for its caller with `CancellationError`, as the real install does for every caller.
    func cancelModelInstall() async {
        let waiter = state.withLock { state in
            state.cancels += 1
            defer { state.finish = nil }
            return state.finish
        }
        waiter?.resume(throwing: CancellationError())
    }
}

/// The speech language the test sets; the installs read it on the main actor.
@MainActor @Observable private final class Language {
    var value: String
    init(_ value: String) { self.value = value }
}

/// A transcriber whose asset status is per language. Its installs and status reads can be held until the test lets
/// them go; a failing install throws `NO_CONNECTION`, and a cancelled one `CancellationError`.
private final class LanguageTranscriber: Transcribing {
    private struct State {
        var statuses: [String: ModelPartStatus]
        var installs = 0
        var cancelled = false
        var failsInstall: Bool
        var finish: CheckedContinuation<Void, Never>?
        var reads: [CheckedContinuation<Void, Never>] = []
    }

    private let state: Mutex<State>
    private let gated: Bool
    private let gatedStatus: Bool

    init(_ statuses: [String: ModelPartStatus], gated: Bool = false, gatedStatus: Bool = false, failsInstall: Bool = false) {
        state = Mutex(State(statuses: statuses, failsInstall: failsInstall))
        self.gated = gated; self.gatedStatus = gatedStatus
    }

    var installs: Int { state.withLock { $0.installs } }
    var waitingReads: Int { state.withLock { $0.reads.count } }
    var cancelled: Bool { state.withLock { $0.cancelled } }
    /// Whether the next installs fail with no connection.
    var failsInstall: Bool {
        get { state.withLock { $0.failsInstall } }
        set { state.withLock { $0.failsInstall = newValue } }
    }

    func set(_ language: String, _ status: ModelPartStatus) { state.withLock { $0.statuses[language] = status } }

    func finish(status: ModelPartStatus) {
        let waiter = state.withLock { state in
            for key in state.statuses.keys { state.statuses[key] = status }
            defer { state.finish = nil }
            return state.finish
        }
        waiter?.resume()
    }

    func releaseReads() {
        let reads = state.withLock { state in defer { state.reads = [] }; return state.reads }
        for read in reads { read.resume() }
    }

    func transcribe(_ request: TranscriptionRequest,
                    events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        TranscriptionResult(segments: [])
    }

    func assetStatus(locale: Locale) async -> ModelPartStatus {
        let status = state.withLock { $0.statuses[locale.identifier(.bcp47)] ?? .unsupported }
        if gatedStatus { await withCheckedContinuation { continuation in state.withLock { $0.reads.append(continuation) } } }
        return status
    }

    func installAssets(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        let fails = state.withLock { state in
            state.installs += 1
            return state.failsInstall
        }
        if fails { throw TranscriptionError.failed(.download(.noConnection)) }
        guard gated else { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let cancelled = state.withLock { state in
                    if !state.cancelled { state.finish = continuation }
                    return state.cancelled
                }
                if cancelled { continuation.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.cancelled = true
                defer { state.finish = nil }
                return state.finish
            }
            waiter?.resume()
        }
        try Task.checkCancellation()
    }

    func speechLanguages() async -> [SpeechLanguage] { [] }
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
