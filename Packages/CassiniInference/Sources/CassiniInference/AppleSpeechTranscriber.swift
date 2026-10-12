import AVFoundation
import Speech
import CassiniEngine
import CassiniNotebook

/// Apple's on-device `SpeechTranscriber` over a whole file.
public actor AppleSpeechTranscriber: Transcribing {
    public init() {}

    public func transcribe(_ request: TranscriptionRequest,
                           events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.failed(.model) }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: request.language)) else {
            throw TranscriptionError.failed(.unsupportedLanguage)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        let status = await AssetInventory.status(forModules: [transcriber])
        if status != .installed {
            guard request.allowDownload else { throw TranscriptionError.needsConsent }
            events(.preparingModel(nil))
            try await Self.install(transcriber, locale: locale) { events(.preparingModel($0)) }
        }
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: request.url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        events(.progress(done: 0, total: duration))
        return try await withTaskCancellationHandler {
            do {
                return try await withThrowingTaskGroup(of: [TranscriptSegment].self) { group in
                    group.addTask {
                        do { try await analyzer.start(inputAudioFile: file, finishAfterFile: true) }
                        catch { await analyzer.cancelAndFinishNow(); throw error }
                        return []
                    }
                    group.addTask {
                        var segments: [TranscriptSegment] = []
                        for try await result in transcriber.results {
                            try Task.checkCancellation()
                            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { continue }
                            let start = result.range.start.seconds
                            let end = result.range.end.seconds
                            var words: [TimedWord] = []
                            for run in result.text.runs {
                                let range = run.audioTimeRange
                                words.append(TimedWord(text: String(result.text[run.range].characters),
                                    start: range?.start.seconds ?? (words.last?.end ?? start),
                                    end: range?.end.seconds ?? (words.last?.end ?? start)))
                            }
                            let segment = TranscriptSegment(text: text, start: start, end: end, words: words)
                            segments.append(segment)
                            events(.finalized(segment))
                            events(.progress(done: end, total: duration))
                        }
                        return segments
                    }
                    var transcript: [TranscriptSegment] = []
                    for try await result in group { if !result.isEmpty { transcript = result } }
                    return TranscriptionResult(segments: transcript.sorted { $0.start < $1.start })
                }
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    public func installAssets(locale requested: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else { return }
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        guard await AssetInventory.status(forModules: [module]) != .installed else { return }
        try await Self.install(module, locale: locale, progress: progress)
    }

    /// Reserves `locale` and installs the assets `module` needs, reporting the fraction done.
    private static func install(_ module: SpeechTranscriber, locale: Locale,
                                progress: @escaping @Sendable (Double) -> Void) async throws {
        guard try await AssetInventory.reserve(locale: locale) else { throw TranscriptionError.failed(.reservationLimit) }
        guard let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let observation = installation.progress.observe(\.fractionCompleted) { reported, _ in
            progress(reported.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await installation.downloadAndInstall()
    }

    public func assetStatus(locale: Locale) async -> ModelPartStatus {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return .unsupported }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .installed: return .ready
        case .downloading: return .downloading(nil)
        case .supported: return .notDownloaded
        default: return .unsupported
        }
    }
}
