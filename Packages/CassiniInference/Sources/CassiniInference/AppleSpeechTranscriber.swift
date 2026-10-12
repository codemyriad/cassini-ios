import AVFoundation
import Speech
import CassiniEngine
import CassiniNotebook

/// Apple's on-device `SpeechTranscriber`, fed the file from `startOffset` one block at a time. The analyzer pulls each
/// block when it is ready for it, so a long file is never held in memory, and results keep the recording's clock.
/// Volatile results are reported for the draft; finalized ones are what a checkpoint keeps.
public actor AppleSpeechTranscriber: Transcribing {
    public init() {}

    public func transcribe(_ request: TranscriptionRequest,
                           events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.failed(.model) }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: request.language)) else {
            throw TranscriptionError.failed(.unsupportedLanguage)
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
                        if let last = try await analyzer.analyzeSequence(input) {
                            try await analyzer.finalizeAndFinish(through: last)
                        } else {
                            await analyzer.cancelAndFinishNow()
                        }
                        return nil
                    }
                    var segments: [TranscriptSegment] = []
                    for try await result in group { if let result { segments = result } }
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

    // MARK: - Assets

    /// Downloads Apple's assets for `locale` when they are missing and downloading is allowed, reporting the download's
    /// share done about twice a second.
    private func installAssets(for transcriber: SpeechTranscriber, locale: Locale, allowDownload: Bool,
                               events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws {
        guard await AssetInventory.status(forModules: [transcriber]) != .installed else { return }
        guard allowDownload else { throw TranscriptionError.needsConsent }
        events(.preparingModel(nil))
        guard try await AssetInventory.reserve(locale: locale) else { throw TranscriptionError.failed(.reservationLimit) }
        guard let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else { return }
        let progress = installation.progress
        let reporter = Task {
            while !Task.isCancelled {
                events(.preparingModel(progress.totalUnitCount > 0 ? progress.fractionCompleted : nil))
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { reporter.cancel() }
        do { try await installation.downloadAndInstall() } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw TranscriptionError.failed(.download(.install))
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
/// analyzer asks for it.
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

    func makeAsyncIterator() -> Iterator { Iterator(reader: reader) }

    struct Iterator: AsyncIteratorProtocol {
        let reader: FileReader
        mutating func next() async -> AnalyzerInput? {
            guard !Task.isCancelled else { return nil }
            return reader.next()
        }
    }
}

/// Reads and converts the blocks. Only the analyzer's single consumer of `FileInput` calls `next()`, one call at a
/// time, so the AVFoundation objects inside are never used concurrently.
final class FileReader: @unchecked Sendable {
    let startTime: TimeInterval
    let duration: TimeInterval
    private let file: AVAudioFile
    private let output: AVAudioFormat
    private let converter: AVAudioConverter?
    private let blockFrames: AVAudioFrameCount
    private var first = true

    init(url: URL, from offset: TimeInterval, to format: AVAudioFormat) throws {
        file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        duration = Double(file.length) / rate
        let startFrame = min(SpeechWindows.frame(atMs: CheckpointState.ms(max(0, offset)), sampleRate: rate), file.length)
        file.framePosition = startFrame
        startTime = Double(startFrame) / rate
        output = format
        converter = file.processingFormat == format ? nil : AVAudioConverter(from: file.processingFormat, to: format)
        blockFrames = AVAudioFrameCount(SpeechWindows.samples(SpeechWindows.blockMs, sampleRate: Int(rate)))
    }

    func next() -> AnalyzerInput? {
        guard file.framePosition < file.length,
              let block = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockFrames) else { return nil }
        let position = file.framePosition
        do { try file.read(into: block, frameCount: blockFrames) } catch { return nil }
        guard block.frameLength > 0, let buffer = convert(block) else { return nil }
        defer { first = false }
        let time = first ? CMTime(value: position, timescale: CMTimeScale(file.processingFormat.sampleRate)) : nil
        return AnalyzerInput(buffer: buffer, bufferStartTime: time)
    }

    private func convert(_ block: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let converter else { return block }
        let ratio = output.sampleRate / block.format.sampleRate
        let capacity = AVAudioFrameCount((Double(block.frameLength) * ratio).rounded(.up)) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return block
        }
        guard status != .error, error == nil else { return nil }
        return converted
    }
}
