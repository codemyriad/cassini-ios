import Foundation
import Observation
import CassiniNotebook

/// The on-device models outside any job: the stored status of each part, and the standalone install that the model
/// download screen's Download (without a note) starts.
///
/// - `refresh()` reads each part's status again: Apple's speech assets for the chosen language, and the speaker
///   models' checked files. It runs at launch, when Settings opens or comes back, after every install, when the
///   speech language changes and when the running job's model download ends. A refresh asked for while one runs
///   reads again once that one ends, so it never returns what was read before it was asked for.
/// - `install(_:)` installs the parts one after another; a request while one runs adds the parts it does not cover,
///   which install after it, so nothing is fetched twice. `cancel()` stops it, and a cancel is no failure. Its progress,
///   then the failure of the first part that failed and was not asked for again, is `download`, which the download
///   notice and the Settings rows show. A failed part shows as failed until the next install of it; a failed speech
///   install counts only for the language it was for.
/// - The standalone install holds background time (`BackgroundRunner`) from its start to its end, so a download of
///   Parakeet Ultra goes on after Cassini leaves the screen. When iOS takes that time back, the install stops as a
///   cancel does and the part in flight shows "Download stopped" (STOPPED_BY_SYSTEM) until its next install.
/// - `statuses` is what the Settings rows show: the running job's model download over the standalone install and the
///   stored status. Recognising saved voices uses the speaker models' install, so it always has their status.
@MainActor @Observable public final class ModelInstalls {
    /// The status of each part as last read; empty until the first refresh.
    public private(set) var stored: [ModelPart: ModelPartStatus] = [:]
    /// The standalone install that runs (no failure), or the failure of the last one; nil when none ran or it finished.
    public private(set) var download: DownloadFact?
    /// The parts whose last standalone install failed, until the next install of them.
    public private(set) var failures: [ModelPart: DownloadError] = [:]

    @ObservationIgnored private let transcriber: any Transcribing
    @ObservationIgnored private let analyzer: any SpeakerAnalyzing
    @ObservationIgnored private let language: @MainActor () -> String
    @ObservationIgnored private let clock: any AppClock
    @ObservationIgnored private let job: JobProgress?
    @ObservationIgnored private var installing: Task<Void, Never>?
    /// Counts the standalone installs started and cancelled; an install whose number is no longer this one has ended.
    @ObservationIgnored private var installNumber = 0
    /// The parts the running standalone install still has to do, in order.
    @ObservationIgnored private var queued: [ModelPart] = []
    /// The part the running standalone install fetches now; nil during its closing refresh.
    @ObservationIgnored private var inFlight: ModelPart?
    /// The failures of the running standalone install, in the order they happened; a part asked for again drops its
    /// own. The first one left is `download` once the install ends.
    @ObservationIgnored private var installFailures: [DownloadFact] = []
    @ObservationIgnored private var refreshing: Task<Void, Never>?
    /// Refreshes asked for, and the last one whose read has ended.
    @ObservationIgnored private var refreshesAsked = 0
    @ObservationIgnored private var refreshesRead = 0
    /// The language `failures[.speech]` is for.
    @ObservationIgnored private var speechFailureLanguage: String?
    @ObservationIgnored private var followers: [Task<Void, Never>] = []
    /// Standalone installs whose run has ended, a cancelled one's closing refresh included, and the running job's
    /// model downloads the follower has seen begin: what a test waits on instead of sleeping.
    @ObservationIgnored private(set) var installsEnded = 0
    @ObservationIgnored private(set) var downloadsFollowed = 0
    @ObservationIgnored private let background: (any BackgroundRunner)?
    @ObservationIgnored private let backgroundTitle: @MainActor () -> String
    @ObservationIgnored private let backgroundSubtitle: @MainActor () -> String
    /// The background time the running standalone install holds, and the progress iOS shows for it.
    @ObservationIgnored private var backgroundToken: BackgroundToken?
    @ObservationIgnored private var backgroundProgress = Progress(totalUnitCount: 100)
    /// The bytes of every part the running standalone install was asked for, and of those it has finished: the
    /// background progress weighs each part's fraction by them, so it never goes back when the next part starts.
    @ObservationIgnored private var backgroundBytes: (total: Int64, done: Int64) = (0, 0)

    /// `language` is the BCP-47 speech language whose assets count; `job` is the running job's progress, whose model
    /// download the rows show. `background` gives the standalone install its time after Cassini leaves the screen,
    /// under `backgroundTitle` and `backgroundSubtitle`.
    public init(transcriber: any Transcribing, analyzer: any SpeakerAnalyzing, clock: any AppClock,
                job: JobProgress? = nil, background: (any BackgroundRunner)? = nil,
                backgroundTitle: @escaping @MainActor () -> String = { "Downloading models" },
                backgroundSubtitle: @escaping @MainActor () -> String = { "They run on this device" },
                language: @escaping @MainActor () -> String) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.clock = clock
        self.job = job
        self.background = background
        self.backgroundTitle = backgroundTitle
        self.backgroundSubtitle = backgroundSubtitle
        self.language = language
        follow()
    }

    isolated deinit {
        for follower in followers { follower.cancel() }
    }

    /// Whether a standalone install runs.
    public var isInstalling: Bool { installing != nil }

    /// The recognizer whose model the speech row and the download screen show.
    public var speechRecognizer: SpeechRecognizer { transcriber.recognizer }

    /// The free space the speech model's install asks for ("Free about N MB" of a job's failed download).
    public var speechInstallBytes: Int64 { transcriber.assetInstallBytes }

    /// The free space the speaker models' install asks for ("Free about N MB" of a failed Identify speakers).
    public var speakersInstallBytes: Int64 { analyzer.modelInstallBytes }

    /// What a part's row shows: the standalone install's progress or failure over the stored status; nil while the
    /// part has not been read.
    public func status(of part: ModelPart) -> ModelPartStatus? {
        let part = part == .voices ? .speakers : part
        if part == .speech, stored[part] == .unsupported { return .unsupported }
        if let download, download.failure == nil, download.part == part {
            return download.checking ? .checking : .downloading(download.fraction)
        }
        if let failure = failures[part], stored[part] != .ready, part != .speech || speechFailureLanguage == language() {
            return .failed(failure)
        }
        return stored[part]
    }

    /// Every row's status, with the running job's model download over it; a part not read yet is missing.
    public var statuses: [ModelPart: ModelPartStatus] {
        Self.statuses(ModelPart.allCases.reduce(into: [:]) { $0[$1] = status(of: $1) }, during: job?.modelDownload)
    }

    /// `standalone` with the running job's model download over it: a speech download shows on the speech row, a
    /// speaker models download on both the speakers and the voices rows. A part not read yet stays missing.
    public nonisolated static func statuses(_ standalone: [ModelPart: ModelPartStatus],
                                            during job: DownloadProgress?) -> [ModelPart: ModelPartStatus] {
        guard let job else { return standalone }
        var statuses = standalone
        let parts: [ModelPart] = job.part == .speech ? [.speech] : [.speakers, .voices]
        for part in parts where statuses[part] != nil {
            if part == .speech, statuses[part] == .unsupported { continue }
            statuses[part] = ModelRows.status(of: job)
        }
        return statuses
    }

    /// Reads every part's status again. While a read runs, waits for it and then reads again, unless a read that
    /// started after this call has already ended.
    public func refresh() async {
        refreshesAsked += 1
        let asked = refreshesAsked
        while refreshesRead < asked {
            if let refreshing {
                await refreshing.value
                continue
            }
            let number = refreshesAsked
            let task = Task {
                await self.read()
                self.refreshesRead = max(self.refreshesRead, number)
                self.refreshing = nil
            }
            refreshing = task
            await task.value
        }
    }

    private func read() async {
        let language = language()
        let speech = await transcriber.assetStatus(locale: Locale(identifier: language))
        let speakers = await analyzer.refreshModelStatus()
        if speechFailureLanguage != language { failures[.speech] = nil }
        stored = [.speech: speech, .speakers: speakers, .voices: speakers]
        if speech == .ready { failures[.speech] = nil }
        if speakers == .ready { failures[.speakers] = nil }
    }

    /// Installs `parts` now, in `ModelPart` order. While a standalone install runs, the parts it does not cover are
    /// installed after it, even when they are asked for during its closing refresh.
    public func install(_ parts: [ModelPart]) {
        let parts = ModelPart.allCases.filter { $0 != .voices && (parts.contains($0) || ($0 == .speakers && parts.contains(.voices))) }
        let added = parts.filter { !queued.contains($0) && $0 != inFlight }
        guard !added.isEmpty else { return }
        for part in added { failures[part] = nil }
        installFailures.removeAll { added.contains($0.part) }
        queued.append(contentsOf: added)
        if installing == nil { backgroundBytes = (0, 0) }
        backgroundBytes.total += added.reduce(0) { $0 + bytes(of: $1) }
        guard installing == nil else {
            // During the closing refresh nothing is in flight: the part asked for shows as downloading at once.
            if inFlight == nil { download = DownloadFact(part: queued[0], at: clock.now) }
            return
        }
        installFailures = []
        installNumber += 1
        let number = installNumber
        download = DownloadFact(part: queued[0], at: clock.now)
        holdBackgroundTime(number)
        installing = Task { [weak self] in await self?.drain(number) }
    }

    /// Cancels the standalone install: its wait on the part in flight ends and the parts after it are dropped. The
    /// shared installer stops that part's install when nobody else waits on it; a job that waits on the same install
    /// goes on with it (the processing card's Cancel stops the job's download). A cancel is no failure: the rows show
    /// what a refresh finds, and the files fetched so far stay for the next install.
    public func cancel() {
        guard let installing else { return }
        installNumber += 1
        self.installing = nil
        inFlight = nil
        queued = []
        installFailures = []
        download = nil
        installing.cancel()
        releaseBackgroundTime()
    }

    /// iOS took the standalone install's background time back: the install stops as `cancel()` stops it, and the part
    /// in flight shows "Download stopped" until its next install. Runs before iOS's handler returns.
    private func stopBySystem(_ number: Int) {
        guard installNumber == number, let installing else { return }
        let part = inFlight ?? queued.first
        installNumber += 1
        self.installing = nil
        inFlight = nil
        queued = []
        installFailures = []
        installing.cancel()
        backgroundToken = nil
        guard let part else { download = nil; return }
        let error = DownloadError.stoppedBySystem
        failures[part] = error
        if part == .speech { speechFailureLanguage = language() }
        download = DownloadFact(part: part, failure: error, at: clock.now)
    }

    /// Asks for background time for install `number`, with a progress that follows the part in flight.
    private func holdBackgroundTime(_ number: Int) {
        guard let background, backgroundToken == nil else { return }
        // A new progress each time: a progress joins the system's task only once.
        backgroundProgress = Progress(totalUnitCount: 100)
        backgroundToken = background.begin(title: backgroundTitle(), subtitle: backgroundSubtitle(),
                                           progress: backgroundProgress) { [weak self] in
            // The runner ends the token right after this.
            self?.stopBySystem(number)
        }
    }

    private func releaseBackgroundTime() {
        guard let token = backgroundToken else { return }
        backgroundToken = nil
        background?.end(token)
    }

    /// Installs the queued parts one after another, then reads every part again; parts asked for during that read are
    /// installed before the install ends. Install `number` stops at once when it is cancelled, after its refresh.
    private func drain(_ number: Int) async {
        defer { installsEnded += 1 }
        repeat {
            while installNumber == number, !queued.isEmpty {
                let part = queued.removeFirst()
                inFlight = part
                download = DownloadFact(part: part, at: clock.now)
                let failure = await install(part, number)
                guard installNumber == number else { break }
                inFlight = nil
                backgroundBytes.done += bytes(of: part)
                if let failure {
                    download = failure
                    installFailures.append(failure)
                }
            }
            await refresh()
        } while installNumber == number && !queued.isEmpty
        // No await between the last look at `queued` and the end, so no request is left behind.
        guard installNumber == number else { return }
        installing = nil
        download = installFailures.first
        installFailures = []
        releaseBackgroundTime()
    }

    /// The user closed the failure of the last standalone install: the download notice goes, while the part's row
    /// shows it as failed until its next install.
    public func dismissFailure() {
        if download?.failure != nil { download = nil }
    }

    /// Installs one part for install `number`; its failure, or nil. A cancel is no failure.
    private func install(_ part: ModelPart, _ number: Int) async -> DownloadFact? {
        let report: @Sendable (InstallProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.report(part, progress, number) }
        }
        let language = language()
        do {
            switch part {
            case .speech:
                try await transcriber.installAssets(locale: Locale(identifier: language), progress: report)
            case .speakers, .voices:
                try await analyzer.installModels(progress: report)
            }
            return nil
        } catch {
            if error is CancellationError || Task.isCancelled || installNumber != number { return nil }
            var (failure, bytes) = Self.failure(error)
            // A speech failure carries no figure: "Free about N MB" says what the speech install asks for.
            if part == .speech, bytes == 0 { bytes = transcriber.assetInstallBytes }
            failures[part] = failure
            if part == .speech { speechFailureLanguage = language }
            return DownloadFact(part: part, failure: failure, requiredFreeBytes: bytes, at: clock.now)
        }
    }

    private func report(_ part: ModelPart, _ progress: InstallProgress, _ number: Int) {
        guard installNumber == number, inFlight == part, download?.part == part, download?.failure == nil else { return }
        switch progress {
        case .downloading(let fraction): download = DownloadFact(part: part, fraction: fraction, at: clock.now)
        case .checking: download = DownloadFact(part: part, fraction: download?.fraction, checking: true, at: clock.now)
        }
        guard let fraction = download?.fraction, backgroundBytes.total > 0 else { return }
        let done = Double(backgroundBytes.done) + Double(bytes(of: part)) * min(max(fraction, 0), 1)
        let units = Int64((done / Double(backgroundBytes.total) * 100).rounded(.down))
        // A part asked for during the install adds to the whole: the progress waits rather than go back.
        backgroundProgress.completedUnitCount = max(backgroundProgress.completedUnitCount, min(units, 100))
    }

    /// A part's weight in the background progress: its download, or for Apple's speech assets, whose size iOS does not
    /// tell, the estimate of their install.
    private func bytes(of part: ModelPart) -> Int64 {
        part == .speech && transcriber.recognizer != .parakeet ? ModelDownloadPlan.speechInstallBytes
            : ModelDownloadPlan.fullDownloadBytes(part)
    }

    /// Reads the models again when the speech language changes, and when the running job's model download ends.
    private func follow() {
        let language = language
        followers.append(Task { [weak self] in
            var last: String?
            for await value in Observations({ language() }) {
                defer { last = value }
                guard let last, last != value else { continue }
                guard let self else { return }
                await self.refresh()
            }
        })
        guard let job else { return }
        followers.append(Task { [weak self] in
            var downloading = false
            for await now in Observations({ job.modelDownload != nil }) {
                defer { downloading = now }
                if now, !downloading { self?.downloadsFollowed += 1 }
                guard downloading, !now else { continue }
                guard let self else { return }
                await self.refresh()
            }
        })
    }

    /// The download error a failed install stands for, and the bytes its space check asked for.
    public nonisolated static func failure(_ error: Error) -> (DownloadError, Int64) {
        switch error {
        case TranscriptionError.failed(.download(let error)): (error, 0)
        case SpeakerAnalysisError.download(let error, let bytes): (error, bytes)
        default: (.install, 0)
        }
    }
}
