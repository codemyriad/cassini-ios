import AVFoundation
import CassiniEngine

/// One-second reads anchored to source frames. Each block primes the file decoder and, when needed, its
/// rate converter with the same bounded context on a fresh run and on resume. The converter itself cannot
/// be serialized. The separate Whistle FIR remains continuous across these blocks.
final class WhistleAudioReader {
    private let file: AVAudioFile
    private let sourceRate: Int
    private let padding: Int
    private let onRead: (@Sendable (Range<Int64>) -> Void)?
    let rate: Int
    let length: Int64
    var duration: Double { Double(length) / Double(sourceRate) }
    private(set) var position: Int64

    init(url: URL, position: Int64, onRead: (@Sendable (Range<Int64>) -> Void)? = nil) throws {
        self.onRead = onRead
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let hz = file.processingFormat.sampleRate
        guard hz.isFinite, (1...1_000_000).contains(hz), hz.rounded() == hz else {
            throw TranscriptionError.failed(.audio)
        }
        sourceRate = Int(hz)
        rate = sourceRate == 16_000 ? 16_000 : 48_000
        length = file.length
        guard position >= 0, position <= length,
              position == length || position.isMultiple(of: Int64(sourceRate)) else {
            throw TranscriptionError.failed(.checkpointMismatch)
        }
        self.position = position
        // Use at least 100 ms of context. Align to a whole output frame even at unusual source rates.
        var divisor = sourceRate, remainder = rate
        while remainder != 0 { (divisor, remainder) = (remainder, divisor % remainder) }
        let period = sourceRate / divisor
        padding = ((sourceRate + 10 * period - 1) / (10 * period)) * period
    }

    func inputFrames(through position: Int64) -> Int {
        // Only whole converted frames are available at a partial final block.
        Int(position * Int64(rate) / Int64(sourceRate))
    }

    /// Actual file read, including the codec/converter context.
    var nextReadRange: Range<Int64>? {
        guard position < length else { return nil }
        let end = min(position + Int64(sourceRate), length)
        let lower = max(0, position - Int64(padding))
        let upper = rate == sourceRate ? end : min(length, end + Int64(padding))
        return lower..<upper
    }

    func next() throws -> [Float]? {
        guard let range = nextReadRange else { return nil }
        let end = min(position + Int64(sourceRate), length)
        let startWithContext = range.lowerBound
        let frames = AVAudioFrameCount(range.count)
        file.framePosition = startWithContext
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw TranscriptionError.failed(.audio)
        }
        try fill(input, frames: frames)
        let output = try mono(input)
        let first = inputFrames(through: position - startWithContext)
        let last = first + inputFrames(through: end) - inputFrames(through: position)
        guard last <= Int(output.frameLength), let channel = output.floatChannelData?.pointee else {
            throw TranscriptionError.failed(.open)
        }
        position = end
        return Array(UnsafeBufferPointer(start: channel + first, count: last - first))
    }

    private func fill(_ input: AVAudioPCMBuffer, frames: AVAudioFrameCount) throws {
        try read(input, frames: frames)
        guard input.frameLength < frames else { return }
        guard input.frameLength > 0, let destination = input.floatChannelData,
              let rest = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames - input.frameLength),
              let source = rest.floatChannelData else { throw TranscriptionError.failed(.open) }
        // AVAudioFile can return a partial read before EOF (e.g. a packet boundary on the simulator).
        while input.frameLength < frames {
            let offset = input.frameLength
            try read(rest, frames: frames - offset)
            guard rest.frameLength > 0 else { throw TranscriptionError.failed(.open) }
            input.frameLength = offset + rest.frameLength
            for channel in 0..<Int(input.format.channelCount) {
                destination[channel].advanced(by: Int(offset))
                    .update(from: source[channel], count: Int(rest.frameLength))
            }
        }
    }

    private func read(_ buffer: AVAudioPCMBuffer, frames: AVAudioFrameCount) throws {
        let start = file.framePosition
        try file.read(into: buffer, frameCount: frames)
        onRead?(start..<(start + Int64(buffer.frameLength)))
    }

    private func mono(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1) else {
            throw TranscriptionError.failed(.audio)
        }
        if input.format == format { return input }
        let count = inputFrames(through: Int64(input.frameLength))
        guard let converter = AVAudioConverter(from: input.format, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count + 256)) else {
            throw TranscriptionError.failed(.audio)
        }
        converter.downmix = true
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .endOfStream; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { throw TranscriptionError.failed(.audio) }
        return output
    }
}
