import AVFoundation
import Speech
import CassiniEngine
import CassiniNotebook

/// Apple's on-device `SpeechTranscriber`, fed the file from `startOffset` one block at a time. The analyzer pulls each
/// block when it is ready for it, so a long file is never held in memory, and results keep the recording's clock.
/// Volatile results are reported for the draft; finalized ones are what a checkpoint keeps, and a final result without
/// words is reported as an empty one so that the finalized audio still moves on. A file that cannot be read to its end
/// fails with `OPEN`; one read to its end reports its whole duration as done before the transcriber returns.
public actor AppleSpeechTranscriber: Transcribing {
    private let probe: AppleSpeechProbe
    public init() { probe = .live }
    init(probe: AppleSpeechProbe) { self.probe = probe }

    private func capability(locale requested: Locale) async -> (locale: Locale?, value: AppleSpeechCapability) {
        guard probe.isAvailable() else {
            return (nil, .init(hardwareAvailable: false, localeSupported: false, assets: .unsupported))
        }
        guard let locale = await probe.supportedLocale(requested) else {
            return (nil, .init(hardwareAvailable: true, localeSupported: false, assets: .unsupported))
        }
        return (locale, .init(hardwareAvailable: true, localeSupported: true, assets: await probe.assetStatus(locale)))
    }

    private func selected(_ capability: AppleSpeechCapability) -> Bool {
        SpeechCapability.choose(linked: false, capable: false, apple: capability) == .appleSpeech
    }

    public func unavailability(locale: Locale) async -> JobFailure? {
        let state = await capability(locale: locale)
        return selected(state.value) ? nil : state.value.failure
    }

    public func transcribe(_ request: TranscriptionRequest,
                           events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        let state = await capability(locale: Locale(identifier: request.language))
        guard selected(state.value), let locale = state.locale else {
            throw TranscriptionError.failed(state.value.failure ?? .model)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults],
                                            attributeOptions: [.audioTimeRange])
        try await installAssets(for: transcriber, locale: locale, allowDownload: request.allowDownload, events: events)
        try Task.checkCancellation()
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.failed(.model)
        }
        let input: FileInput
        do { input = try FileInput(url: request.url, from: request.startOffset, to: format) } catch {
            throw TranscriptionError.failed(.open)
        }
        events(.progress(done: input.startTime, total: input.duration))
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: [TranscriptSegment]?.self) { group in
                    group.addTask {
                        try await Self.results(of: transcriber, total: input.duration, events: events)
                    }
                    group.addTask {
                        let last = try await analyzer.analyzeSequence(input)
                        // A read error ends the input early: what came before it is not the whole file.
                        if input.failed { throw TranscriptionError.failed(.open) }
                        if let last {
                            try await analyzer.finalizeAndFinish(through: last)
                        } else {
                            await analyzer.cancelAndFinishNow()
                        }
                        return nil
                    }
                    var segments: [TranscriptSegment] = []
                    for try await result in group { if let result { segments = result } }
                    try Task.checkCancellation()
                    guard input.reachedEnd else { throw TranscriptionError.failed(.open) }
                    events(.progress(done: input.duration, total: input.duration))
                    return TranscriptionResult(segments: segments)
                }
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    /// Throws `TranscriptionError.failed(.download(_))` when the download or the install fails.
    public func installAssets(locale requested: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        let state = await capability(locale: requested)
        guard selected(state.value), let locale = state.locale else {
            throw TranscriptionError.failed(state.value.failure ?? .model)
        }
        guard state.value.assets != .ready else { return }
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        try await Self.install(module, locale: locale) { if let fraction = $0 { progress(.downloading(fraction)) } }
    }

    public func availability(locale: Locale) async -> SpeechAvailability {
        let state = await capability(locale: locale)
        return SpeechAvailability(assets: selected(state.value) ? state.value.assets : .unsupported,
                                  failure: state.value.failure)
    }

    public func assetStatus(locale: Locale) async -> ModelPartStatus {
        let state = await capability(locale: locale)
        return selected(state.value) ? state.value.assets : .unsupported
    }

    /// "Apple SpeechTranscriber it-IT": the module and the locale whose assets it runs. Apple names no model version,
    /// so the OS build in the provenance's `version` stands in for it.
    public func modelName(locale: Locale) async -> String? {
        let state = await capability(locale: locale)
        guard selected(state.value), let supported = state.locale else { return nil }
        return "Apple SpeechTranscriber \(supported.identifier(.bcp47))"
    }

    /// The locale `supportedLocale(equivalentTo:)` picks for `requested`, the one a run transcribes in.
    public func runLanguage(requested: String) async -> String? {
        let state = await capability(locale: Locale(identifier: requested))
        return selected(state.value) ? state.locale?.identifier(.bcp47) : nil
    }

    public func speechLanguages() async -> [SpeechLanguage] {
        guard probe.isAvailable() else { return [] }
        let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        return await SpeechTranscriber.supportedLocales.map { locale in
            let id = locale.identifier(.bcp47)
            return SpeechLanguage(id: id, installed: installed.contains(id))
        }
    }

    // MARK: - Assets

    /// Downloads Apple's assets for `locale` when they are missing and downloading is allowed.
    private func installAssets(for transcriber: SpeechTranscriber, locale: Locale, allowDownload: Bool,
                               events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws {
        guard await AssetInventory.status(forModules: [transcriber]) != .installed else { return }
        guard allowDownload else { throw TranscriptionError.needsConsent }
        events(.preparingModel(.downloading(nil)))
        try await Self.install(transcriber, locale: locale) { events(.preparingModel(.downloading($0))) }
    }

    /// Reserves `locale` and installs the assets `module` needs, reporting the share done (nil while unknown) about
    /// twice a second. A failure other than a cancel is `TranscriptionError.failed(.download(_))`.
    private static func install(_ module: SpeechTranscriber, locale: Locale,
                                report: @escaping @Sendable (Double?) -> Void) async throws {
        guard try await AssetInventory.reserve(locale: locale) else { throw TranscriptionError.failed(.reservationLimit) }
        guard let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let progress = installation.progress
        let reporter = Task {
            while !Task.isCancelled {
                report(progress.totalUnitCount > 0 ? progress.fractionCompleted : nil)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { reporter.cancel() }
        do { try await installation.downloadAndInstall() } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionError.failed(.download(InstallErrors.downloadError(error)))
        }
    }

    // MARK: - Results

    /// Reports each result as it comes and returns the finalized ones in time order.
    private static func results(of transcriber: SpeechTranscriber, total: TimeInterval,
                                events: @Sendable (TranscriptionEvent) -> Void) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        for try await result in transcriber.results {
            try Task.checkCancellation()
            let segment = segment(text: result.text, range: result.range)
            if result.isFinal {
                if let segment {
                    segments.append(segment)
                    events(.finalized(segment))
                } else {
                    // Silence: nothing to keep, but the audio up to here is final.
                    events(.finalized(TranscriptSegment(text: "", start: result.range.start.seconds,
                                                        end: result.range.end.seconds)))
                }
                events(.progress(done: result.range.end.seconds, total: total))
            } else {
                events(.volatile(segment))
            }
        }
        return segments.sorted { $0.start < $1.start }
    }

    /// One result as a segment with its timed words; nil when it holds no words.
    private static func segment(text: AttributedString, range: CMTimeRange) -> TranscriptSegment? {
        let plain = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !plain.isEmpty else { return nil }
        let start = range.start.seconds, end = range.end.seconds
        var words: [TimedWord] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let time = run.audioTimeRange
            let previous = words.last?.end ?? start
            words.append(TimedWord(text: piece, start: time?.start.seconds ?? previous, end: time?.end.seconds ?? previous))
        }
        return TranscriptSegment(text: plain, start: start, end: end, words: words)
    }
}

/// The file from a start time on, as analyzer input in the analyzer's format: one block per `next()`, read when the
/// analyzer asks for it. A read or conversion error ends the input and sets `failed`; the end of the file sets
/// `reachedEnd`.
struct FileInput: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput

    let startTime: TimeInterval
    let duration: TimeInterval
    private let reader: FileReader

    init(url: URL, from offset: TimeInterval, to format: AVAudioFormat) throws {
        reader = try FileReader(url: url, from: offset, to: format)
        startTime = reader.startTime
        duration = reader.duration
    }

    var failed: Bool { reader.failure != nil }
    var reachedEnd: Bool { reader.reachedEnd }

    func makeAsyncIterator() -> Iterator { Iterator(reader: reader) }

    struct Iterator: AsyncIteratorProtocol {
        let reader: FileReader
        mutating func next() async -> AnalyzerInput? {
            guard !Task.isCancelled else { return nil }
            return reader.next()
        }
    }
}

extension FileReader {
    /// The next block as analyzer input; nil at the end of the file or after a failure. The first carries its time on
    /// the recording's clock, so the results keep it.
    func next() -> AnalyzerInput? {
        guard let (buffer, first) = nextBuffer() else { return nil }
        let time = first ? CMTime(value: startFrame, timescale: CMTimeScale(sourceRate)) : nil
        return AnalyzerInput(buffer: buffer, bufferStartTime: time)
    }
}

/// Apple's asset install errors as the download errors the banners tell apart.
enum InstallErrors {
    static func downloadError(_ error: any Error) -> DownloadError {
        let error = error as NSError
        switch (error.domain, error.code) {
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet), (NSURLErrorDomain, NSURLErrorNetworkConnectionLost),
             (NSURLErrorDomain, NSURLErrorCannotConnectToHost), (NSURLErrorDomain, NSURLErrorCannotFindHost),
             (NSURLErrorDomain, NSURLErrorTimedOut), (NSURLErrorDomain, NSURLErrorDataNotAllowed),
             (NSURLErrorDomain, NSURLErrorInternationalRoamingOff), (NSURLErrorDomain, NSURLErrorDNSLookupFailed):
            return .noConnection
        case (NSCocoaErrorDomain, NSFileWriteOutOfSpaceError), (NSPOSIXErrorDomain, Int(ENOSPC)):
            return .notEnoughStorage
        default:
            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? any Error {
                return downloadError(underlying)
            }
            return .install
        }
    }
}

/// Public framework probes are injected only for adapter tests; policy stays in CassiniEngine.
struct AppleSpeechProbe: Sendable {
    var isAvailable: @Sendable () -> Bool
    var supportedLocale: @Sendable (Locale) async -> Locale?
    var assetStatus: @Sendable (Locale) async -> ModelPartStatus

    static let live = Self(isAvailable: { SpeechTranscriber.isAvailable }, supportedLocale: {
        await SpeechTranscriber.supportedLocale(equivalentTo: $0)
    }, assetStatus: { locale in
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        switch await AssetInventory.status(forModules: [module]) {
        case .installed: return .ready
        case .downloading: return .downloading(nil)
        case .supported: return .notDownloaded
        default: return .unsupported
        }
    })
}
