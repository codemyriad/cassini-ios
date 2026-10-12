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
    public func installAssets(locale requested: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else { return }
        let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        guard await AssetInventory.status(forModules: [module]) != .installed else { return }
        try await Self.install(module, locale: locale) { if let fraction = $0 { progress(fraction) } }
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

    /// Downloads Apple's assets for `locale` when they are missing and downloading is allowed.
    private func installAssets(for transcriber: SpeechTranscriber, locale: Locale, allowDownload: Bool,
                               events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws {
        guard await AssetInventory.status(forModules: [transcriber]) != .installed else { return }
        guard allowDownload else { throw TranscriptionError.needsConsent }
        events(.preparingModel(nil))
        try await Self.install(transcriber, locale: locale) { events(.preparingModel($0)) }
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

/// Reads and converts the blocks. Only the analyzer's single consumer of `FileInput` calls `next()`, one call at a
/// time, so the AVFoundation objects inside are never used concurrently; `failure` and `reachedEnd` are read once the
/// analyzer is done with the input.
final class FileReader: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case read(String)
        /// The file ended before its length said.
        case short
        case convert
    }

    let startTime: TimeInterval
    let duration: TimeInterval
    private(set) var failure: Failure?
    /// Every frame from the start offset was read and converted.
    private(set) var reachedEnd = false
    private let file: AVAudioFile
    private let output: AVAudioFormat
    private let converter: AVAudioConverter?
    private let blockFrames: AVAudioFrameCount
    private let startFrame: AVAudioFramePosition
    private var first = true

    init(url: URL, from offset: TimeInterval, to format: AVAudioFormat) throws {
        file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        duration = Double(file.length) / rate
        startFrame = min(SpeechWindows.frame(atMs: CheckpointState.ms(max(0, offset)), sampleRate: rate), file.length)
        file.framePosition = startFrame
        startTime = Double(startFrame) / rate
        output = format
        converter = file.processingFormat == format ? nil : AVAudioConverter(from: file.processingFormat, to: format)
        blockFrames = AVAudioFrameCount(SpeechWindows.samples(SpeechWindows.blockMs, sampleRate: Int(rate)))
    }

    /// The next block; nil at the end of the file or after a failure. The first carries its time on the recording's
    /// clock, so the results keep it.
    func next() -> AnalyzerInput? {
        while failure == nil, !reachedEnd {
            guard let buffer = read() else { continue }
            guard buffer.frameLength > 0 else { continue }
            defer { first = false }
            let time = first ? CMTime(value: startFrame, timescale: CMTimeScale(file.processingFormat.sampleRate)) : nil
            return AnalyzerInput(buffer: buffer, bufferStartTime: time)
        }
        return nil
    }

    /// One block in the output format, the converter's tail at the end of the file, or nil once it failed or ended.
    private func read() -> AVAudioPCMBuffer? {
        guard file.framePosition < file.length else {
            reachedEnd = true
            return converter.flatMap { drain($0) }
        }
        guard let block = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockFrames) else {
            failure = .convert
            return nil
        }
        do { try file.read(into: block, frameCount: blockFrames) } catch {
            failure = .read(String(describing: error))
            return nil
        }
        guard block.frameLength > 0 else { failure = .short; return nil }
        guard let converter else { return block }
        let ratio = output.sampleRate / block.format.sampleRate
        let capacity = AVAudioFrameCount((Double(block.frameLength) * ratio).rounded(.up)) + 32
        return convert(converter, block, capacity: capacity)
    }

    /// The frames the converter still holds once the input ended.
    private func drain(_ converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        convert(converter, nil, capacity: AVAudioFrameCount(output.sampleRate))
    }

    /// Converts `block`, or flushes the converter when it is nil.
    private func convert(_ converter: AVAudioConverter, _ block: AVAudioPCMBuffer?,
                         capacity: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
            failure = .convert
            return nil
        }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: converted, error: &error) { _, inputStatus in
            guard let block else { inputStatus.pointee = .endOfStream; return nil }
            if consumed { inputStatus.pointee = .noDataNow; return nil }
            consumed = true
            inputStatus.pointee = .haveData
            return block
        }
        guard status != .error, error == nil else { failure = .convert; return nil }
        return converted
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
