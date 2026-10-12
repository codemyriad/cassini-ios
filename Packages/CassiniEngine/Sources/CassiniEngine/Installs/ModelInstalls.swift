import Foundation
import Observation
import CassiniNotebook

/// The on-device models outside any job: the stored status of each part, and the standalone install that the model
/// download screen's Download (without a note) starts.
///
/// - `refresh()` reads each part's status again: Apple's speech assets for the chosen language, and the speaker
///   models' checked files. It runs at launch, when Settings opens and after every install.
/// - `install(_:)` installs the parts one after another; a request while one runs joins it. Its progress, then the
///   failure of the first part that failed, is `download`, which the download notice and the Settings rows show.
///   A failed part shows as failed until the next install of it.
/// - Recognising saved voices uses the speaker models' install, so it always has their status.
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
    @ObservationIgnored private var installing: Task<Void, Never>?
    @ObservationIgnored private var refreshing: Task<Void, Never>?

    /// `language` is the BCP-47 speech language whose assets count.
    public init(transcriber: any Transcribing, analyzer: any SpeakerAnalyzing, clock: any AppClock,
                language: @escaping @MainActor () -> String) {
        self.transcriber = transcriber
        self.analyzer = analyzer
        self.clock = clock
        self.language = language
    }

    /// Whether a standalone install runs.
    public var isInstalling: Bool { installing != nil }

    /// What a part's row shows: the standalone install's progress or failure over the stored status; nil while the
    /// part has not been read.
    public func status(of part: ModelPart) -> ModelPartStatus? {
        let part = part == .voices ? .speakers : part
        if let download, download.failure == nil, download.part == part {
            return .downloading(download.fraction)
        }
        if let failure = failures[part], stored[part] != .ready { return .failed(failure) }
        return stored[part]
    }

    /// Reads every part's status again; a refresh that runs is joined.
    public func refresh() async {
        if let refreshing { return await refreshing.value }
        let task = Task { [transcriber, analyzer, language] in
            let speech = await transcriber.assetStatus(locale: Locale(identifier: language()))
            let speakers = await analyzer.refreshModelStatus()
            self.stored = [.speech: speech, .speakers: speakers, .voices: speakers]
            if speech == .ready { self.failures[.speech] = nil }
            if speakers == .ready { self.failures[.speakers] = nil }
        }
        refreshing = task
        await task.value
        refreshing = nil
    }

    /// Installs `parts` now, in `ModelPart` order, unless a standalone install runs (the request joins it).
    public func install(_ parts: [ModelPart]) {
        let parts = ModelPart.allCases.filter { $0 != .voices && (parts.contains($0) || ($0 == .speakers && parts.contains(.voices))) }
        guard installing == nil, !parts.isEmpty else { return }
        for part in parts { failures[part] = nil }
        download = DownloadFact(part: parts[0], at: clock.now)
        installing = Task { [weak self] in
            var firstFailure: DownloadFact?
            for part in parts {
                guard let self, !Task.isCancelled else { return }
                self.download = DownloadFact(part: part, at: self.clock.now)
                if let failure = await self.install(part), firstFailure == nil { firstFailure = failure }
            }
            guard let self else { return }
            await self.refresh()
            self.installing = nil
            self.download = firstFailure
        }
    }

    /// Installs one part; its failure, or nil.
    private func install(_ part: ModelPart) async -> DownloadFact? {
        let report: @Sendable (Double?) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.report(part, fraction) }
        }
        do {
            switch part {
            case .speech:
                try await transcriber.installAssets(locale: Locale(identifier: language())) { report($0) }
            case .speakers, .voices:
                try await analyzer.installModels(progress: report)
            }
            return nil
        } catch is CancellationError {
            return nil
        } catch {
            let (failure, bytes) = Self.failure(error)
            failures[part] = failure
            return DownloadFact(part: part, failure: failure, requiredFreeBytes: bytes, at: clock.now)
        }
    }

    private func report(_ part: ModelPart, _ fraction: Double?) {
        guard installing != nil, download?.part == part, download?.failure == nil else { return }
        download = DownloadFact(part: part, fraction: fraction, at: clock.now)
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
