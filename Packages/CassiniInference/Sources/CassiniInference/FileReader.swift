import AVFoundation
import CassiniNotebook

/// Reads an audio file from a start offset and converts it block by block. Only one consumer calls `nextBuffer()`, one
/// call at a time, so the AVFoundation objects inside are never used concurrently; `failure` and `reachedEnd` are read
/// once the consumer is done. Apple Speech reads it as analyzer input (`next()`), Parakeet as 16 kHz mono floats.
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
    /// The first frame read, at the file's rate.
    let startFrame: AVAudioFramePosition
    /// The file's own sample rate.
    var sourceRate: Double { file.processingFormat.sampleRate }
    /// Frames in the file at its own rate.
    var length: AVAudioFramePosition { file.length }
    private let file: AVAudioFile
    private let output: AVAudioFormat
    private let converter: AVAudioConverter?
    private let blockFrames: AVAudioFrameCount
    private var first = true

    /// `downmix` averages the channels of a file with more channels than `format` (Parakeet hears one); otherwise
    /// the converter's own channel map applies.
    init(url: URL, from offset: TimeInterval, to format: AVAudioFormat, downmix: Bool = false) throws {
        file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        duration = Double(file.length) / rate
        startFrame = min(AppleSpeechWindows.frame(atMs: CheckpointState.ms(max(0, offset)), sampleRate: rate), file.length)
        file.framePosition = startFrame
        startTime = Double(startFrame) / rate
        output = format
        converter = file.processingFormat == format ? nil : AVAudioConverter(from: file.processingFormat, to: format)
        converter?.downmix = downmix
        blockFrames = AVAudioFrameCount(AppleSpeechWindows.samples(AppleSpeechWindows.blockMs, sampleRate: Int(rate)))
    }

    /// The next block in the output format and whether it is the first; nil at the end of the file or after a failure.
    func nextBuffer() -> (AVAudioPCMBuffer, first: Bool)? {
        while failure == nil, !reachedEnd {
            guard let buffer = read() else { continue }
            guard buffer.frameLength > 0 else { continue }
            defer { first = false }
            return (buffer, first)
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
