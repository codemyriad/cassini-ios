import AVFoundation
import CassiniEngine

/// One-second reads anchored to source frames. Each block primes the file decoder and, when needed, its
/// rate converter with the same bounded context on a fresh run and on resume. The converter itself cannot
/// be serialized. The separate Whistle FIR remains continuous across these blocks.
final class WhistleAudioReader {
    private let file: AVAudioFile
    private let sourceRate: Int
    private let padding: Int
    let rate: Int
    let length: Int64
    var duration: Double { Double(length) / Double(sourceRate) }
    private(set) var position: Int64

    init(url: URL, position: Int64) throws {
        file = try AVAudioFile(forReading: url)
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
        Int((position * Int64(rate) + Int64(sourceRate) - 1) / Int64(sourceRate))
    }

    func next() throws -> [Float]? {
        guard position < length else { return nil }
        let end = min(position + Int64(sourceRate), length)
        let startWithContext = max(0, position - Int64(padding))
        let endWithContext = rate == sourceRate ? end : min(length, end + Int64(padding))
        let frames = AVAudioFrameCount(endWithContext - startWithContext)
        file.framePosition = startWithContext
        guard let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
            throw TranscriptionError.failed(.audio)
        }
        try file.read(into: input, frameCount: frames)
        guard input.frameLength == frames else { throw TranscriptionError.failed(.open) }
        let output = try mono(input)
        let first = inputFrames(through: position - startWithContext)
        let last = first + inputFrames(through: end) - inputFrames(through: position)
        guard last <= Int(output.frameLength), let channel = output.floatChannelData?.pointee else {
            throw TranscriptionError.failed(.open)
        }
        position = end
        return Array(UnsafeBufferPointer(start: channel + first, count: last - first))
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
