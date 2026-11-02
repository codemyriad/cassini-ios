import CassiniCore
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

    /// Cancel ends the standalone's own wait on the speaker models' install (the shared installer stops it when
    /// nobody else waits) and is no failure.
    @Test func cancelEndsTheSpeakerModelsWaitAndIsNoFailure() async throws {
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

    /// Parakeet's standalone download: the row shows the download, then Checking files, then Ready.
    @Test func aParakeetDownloadShowsDownloadingThenCheckingFiles() async throws {
        let transcriber = SharedInstallTranscriber()
        let installs = ModelInstalls(transcriber: transcriber, analyzer: ScriptedAnalyzer(status: .ready),
                                     clock: FakeClock()) { "en-US" }
        await installs.refresh()
        installs.install([.speech])
        try await until { transcriber.installs == 1 }
        transcriber.report(.downloading(0.3))
        try await until { installs.status(of: .speech) == .downloading(0.3) }
        transcriber.report(.checking)
        try await until { installs.status(of: .speech) == .checking }
        #expect(installs.download?.checking == true, "the download notice says so too")
        transcriber.finish(nil)
        try await until { !installs.isInstalling }
        #expect(installs.status(of: .speech) == .ready)
        #expect(transcriber.cancels == 0)
    }

    /// The standalone install holds background time from its start to its end, with the download's progress, so a
    /// download of Ultra goes on after Cassini leaves the screen.
    @Test func theStandaloneInstallHoldsBackgroundTimeUntilItEnds() async throws {
        let transcriber = SharedInstallTranscriber()
        let background = FakeBackgroundRunner()
        let installs = ModelInstalls(transcriber: transcriber, analyzer: ScriptedAnalyzer(status: .ready),
                                     clock: FakeClock(), background: background,
                                     backgroundTitle: { "Downloading models" }) { "en-US" }
        await installs.refresh()
        installs.install([.speech])
        #expect(background.activeCount == 1)
        #expect(background.titles.values.first == "Downloading models")
        #expect(background.subtitles.values.first == "They run on this device", "not the queue's subtitle")
        installs.install([.speakers])
        #expect(background.begunCount == 1, "one background time for the whole install")
        try await until { transcriber.installs == 1 }
        transcriber.finish(nil)
        try await until { !installs.isInstalling }
        #expect(background.activeCount == 0 && background.endedCount == 1)

        installs.install([.speech])
        #expect(background.activeCount == 1)
        installs.cancel()
        #expect(background.activeCount == 0, "a cancel gives the time back")
    }

    /// The background progress weighs each part by its download over the whole install, so it never goes back when
    /// the next part starts: half of Ultra (443 MB) is under half of the whole, and the speaker models (88 MB) start
    /// where it ended.
    @Test func theBackgroundProgressNeverGoesBackWhenTheNextPartStarts() async throws {
        let transcriber = SharedInstallTranscriber()
        let analyzer = ScriptedAnalyzer(status: .notDownloaded, gated: true)
        let background = FakeBackgroundRunner()
        let installs = ModelInstalls(transcriber: transcriber, analyzer: analyzer, clock: FakeClock(),
                                     background: background) { "en-US" }
        await installs.refresh()
        installs.install([.speech, .speakers])
        let progress = try #require(background.progresses.values.first)
        var seen: [Int64] = []
        try await until { transcriber.installs == 1 }
        for fraction in [0.5, 1.0] {
            transcriber.report(.downloading(fraction))
            try await until { installs.status(of: .speech) == .downloading(fraction) }
            seen.append(progress.completedUnitCount)
        }
        transcriber.finish(nil)
        try await until { analyzer.installs == 1 }
        for fraction in [0.1, 0.5, 1.0] {
            analyzer.report(fraction)
            try await until { installs.status(of: .speakers) == .downloading(fraction) }
            seen.append(progress.completedUnitCount)
        }
        #expect(seen == seen.sorted(), "never back: \(seen)")
        #expect(seen[0] > 0 && seen[0] < 50, "half of Ultra is under half of the whole: \(seen)")
        #expect(seen[2] > seen[1], "the speaker models go on from where Ultra ended: \(seen)")
        #expect(seen.last == 100)
        analyzer.finish(with: nil, status: .ready)
        try await until { !installs.isInstalling }
    }

    /// iOS takes the time back: the install stops, and the part in flight shows "Download stopped" (STOPPED_BY_SYSTEM)
    /// on its row and in the download notice until its next install.
    @Test func whenIOSTakesTheTimeBackTheDownloadShowsStopped() async throws {
        let transcriber = SharedInstallTranscriber()
        let analyzer = ScriptedAnalyzer(status: .notDownloaded)
        let background = FakeBackgroundRunner()
        let installs = ModelInstalls(transcriber: transcriber, analyzer: analyzer, clock: FakeClock(),
                                     background: background) { "en-US" }
        await installs.refresh()
        installs.install([.speech, .speakers])
        try await until { transcriber.installs == 1 }
        background.expireAll()
        #expect(!installs.isInstalling)
        #expect(installs.download?.failure == .stoppedBySystem)
        #expect(installs.download?.part == .speech)
        #expect(installs.status(of: .speech) == .failed(.stoppedBySystem))
        try await until { transcriber.cancels == 1 && transcriber.ended }
        try await until { installs.status(of: .speech) == .failed(.stoppedBySystem) }
        #expect(analyzer.installs == 0, "the parts after it are dropped")
        #expect(background.activeCount == 0)

        installs.install([.speech])
        #expect(installs.status(of: .speech) == .downloading(nil), "the next install clears it")
        #expect(background.activeCount == 1)
    }

    /// Cancel of Parakeet's download ends the standalone's wait on the shared install, as for the speaker models.
    @Test func cancelEndsTheWaitOnParakeetsSharedInstallAndIsNoFailure() async throws {
        let transcriber = SharedInstallTranscriber()
        let analyzer = ScriptedAnalyzer(status: .notDownloaded)
        let installs = ModelInstalls(transcriber: transcriber, analyzer: analyzer, clock: FakeClock()) { "en-US" }
        await installs.refresh()
        installs.install([.speech, .speakers])
        try await until { transcriber.installs == 1 }
        transcriber.report(.checking)
        try await until { installs.status(of: .speech) == .checking }
        installs.cancel()
        #expect(!installs.isInstalling)
        try await until { transcriber.cancels == 1 }
        #expect(analyzer.cancels == 0, "the speaker models' install was not running")
        try await until { transcriber.ended }
        #expect(installs.failures.isEmpty)
        #expect(installs.download == nil)
        #expect(analyzer.installs == 0, "the parts after the cancelled one are dropped")
    }

    /// "Free about N MB" of a failed speech download is what the transcriber's install asks for: Parakeet's
    /// `ModelPlan` figure rather than the estimate for Apple's assets.
    @Test func aSpeechDownloadWithoutRoomAsksForTheTranscribersFigure() async throws {
        let transcriber = SharedInstallTranscriber()
        let installs = ModelInstalls(transcriber: transcriber, analyzer: ScriptedAnalyzer(status: .ready),
                                     clock: FakeClock()) { "en-US" }
        await installs.refresh()
        installs.install([.speech])
        try await until { transcriber.installs == 1 }
        transcriber.finish(TranscriptionError.failed(.download(.notEnoughStorage)))
        try await until { !installs.isInstalling }
        #expect(installs.download?.failure == .notEnoughStorage)
        #expect(installs.download?.requiredFreeBytes == transcriber.assetInstallBytes)
        #expect(installs.speechInstallBytes == transcriber.assetInstallBytes)
        #expect(installs.speechRecognizer == .parakeet)
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
    }

    private let state: Mutex<State>
    private let gated: Bool
    private let held = HeldInstall()

    init(status: ModelPartStatus, gated: Bool = false) {
        state = Mutex(State(status: status))
        self.gated = gated
    }

    var installs: Int { state.withLock { $0.installs } }
    var cancels: Int { held.cancels }

    func report(_ fraction: Double) { state.withLock { $0.progress }?(.downloading(fraction)) }

    func reportChecking() { state.withLock { $0.progress }?(.checking) }

    func finish(with error: SpeakerAnalysisError?, status: ModelPartStatus) {
        state.withLock { $0.status = status }
        held.end(error)
    }

    func analyze(url: URL, words: [Word], allowDownload: Bool,
                 progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis {
        SpeakerAnalysis(turns: [], prints: [])
    }

    func modelStatus() async -> ModelPartStatus { state.withLock { $0.status } }
    func refreshModelStatus() async -> ModelPartStatus { state.withLock { $0.status } }

    var modelInstallBytes: Int64 { 54_000_000 }

    /// A gated install waits for `finish`; cancelling its caller ends the wait with `CancellationError`, as the shared
    /// installer does for a caller that leaves, and counts in `cancels`.
    func installModels(progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        state.withLock { $0.installs += 1; $0.progress = progress }
        guard gated else { return }
        try await held.wait()
    }
}

/// An install the test holds: `wait()` returns when the test calls `end`, or throws `CancellationError` when its
/// caller is cancelled, as the shared installer ends the wait of a caller that leaves; `cancels` counts those.
private final class HeldInstall: Sendable {
    private struct State {
        var waiter: CheckedContinuation<Void, Error>?
        var cancelled = false
        var cancels = 0
    }

    private let state = Mutex(State())

    var cancels: Int { state.withLock { $0.cancels } }

    func wait() async throws {
        state.withLock { $0.cancelled = false }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let cancelled = state.withLock { state in
                    if !state.cancelled { state.waiter = continuation }
                    return state.cancelled
                }
                if cancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { state in
                state.cancelled = true
                state.cancels += 1
                defer { state.waiter = nil }
                return state.waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    /// Ends the wait: returns without `error`, else throws it.
    func end(_ error: Error?) {
        let waiter = state.withLock { state in defer { state.waiter = nil }; return state.waiter }
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume() }
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

    func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
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

/// Parakeet over the shared installer, driven by the test: its install reports what the test says and ends when the
/// test finishes it, or with `CancellationError` once its caller is cancelled.
private final class SharedInstallTranscriber: Transcribing {
    private struct State {
        var status: ModelPartStatus = .notDownloaded
        var installs = 0
        var ended = false
        var progress: (@Sendable (InstallProgress) -> Void)?
    }

    private let state = Mutex(State())
    private let held = HeldInstall()

    var recognizer: SpeechRecognizer { .parakeet }
    var assetInstallBytes: Int64 { 1_290_000_000 }
    var installs: Int { state.withLock { $0.installs } }
    var cancels: Int { held.cancels }
    var ended: Bool { state.withLock { $0.ended } }

    func report(_ progress: InstallProgress) { state.withLock { $0.progress }?(progress) }

    /// Ends the install: installed without `error`, else failed with it.
    func finish(_ error: Error?) {
        if error == nil { state.withLock { $0.status = .ready } }
        held.end(error)
    }

    func transcribe(_ request: TranscriptionRequest,
                    events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        TranscriptionResult(segments: [])
    }

    func assetStatus(locale: Locale) async -> ModelPartStatus { state.withLock { $0.status } }

    func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        state.withLock { $0.installs += 1; $0.progress = progress }
        defer { state.withLock { $0.ended = true } }
        try await held.wait()
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
