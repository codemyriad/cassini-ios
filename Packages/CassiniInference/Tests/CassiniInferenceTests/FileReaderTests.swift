import AVFoundation
import Foundation
import Speech
import Testing
@testable import CassiniInference

/// `FileReader` over generated WAV and CAF files: the resume offset, the recording-clock time of the first block, block reading,
/// conversion, the end of the file and a file cut short.
@Suite struct FileReaderTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private let rate = 16_000.0

    private func audioFile(seconds: Double, name: String = "audio.wav") throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(seconds * rate)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for index in 0..<Int(frames) { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 0.05) * 0.3) }
        try file.write(from: buffer)
        return url
    }

    /// What the analyzer asks for: 16-bit samples at the file's rate. (`AnalyzerInput` traps on the Float32 buffers a
    /// file reads into, so every input is converted.)
    private func analyzerFormat() throws -> AVAudioFormat {
        try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: true))
    }

    private func readAll(_ reader: FileReader) -> [AnalyzerInput] {
        var inputs: [AnalyzerInput] = []
        while let input = reader.next() { inputs.append(input) }
        return inputs
    }

    @Test func aResumedReadStartsAtTheOffsetOnTheRecordingsClock() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try audioFile(seconds: 3.5)
        let format = try analyzerFormat()
        let reader = try FileReader(url: url, from: 1.0, to: format)
        #expect(reader.startTime == 1.0)
        #expect(reader.duration == 3.5)
        let inputs = readAll(reader)
        #expect(inputs.first?.bufferStartTime == CMTime(value: 16_000, timescale: 16_000))
        #expect(inputs.dropFirst().allSatisfy { $0.bufferStartTime == nil })
        #expect(inputs.allSatisfy { $0.buffer.frameLength <= 16_000 }, "blocks of at most one second")
        #expect(inputs.reduce(0) { $0 + Int($1.buffer.frameLength) } == 40_000, "every frame to the end, the tail too")
        #expect(reader.reachedEnd)
        #expect(reader.failure == nil)
        #expect(reader.next() == nil)
    }

    @Test func aConvertedReadKeepsEveryFrameIncludingTheConvertersTail() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try audioFile(seconds: 2.5)
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
        let reader = try FileReader(url: url, from: 0, to: output)
        let inputs = readAll(reader)
        #expect(inputs.first?.bufferStartTime == CMTime(value: 0, timescale: 16_000))
        #expect(inputs.allSatisfy { $0.buffer.format == output })
        let frames = inputs.reduce(0) { $0 + Int($1.buffer.frameLength) }
        #expect(abs(frames - 120_000) <= 48, "\(frames) frames for 2.5 s at 48 kHz")
        #expect(reader.reachedEnd)
        #expect(reader.failure == nil)
    }

    @Test func anOffsetPastTheEndReadsNothing() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = try audioFile(seconds: 1)
        let format = try analyzerFormat()
        let reader = try FileReader(url: url, from: 5, to: format)
        #expect(reader.startTime == 1)
        #expect(readAll(reader).isEmpty)
        #expect(reader.reachedEnd)
    }

    @Test func aRecordingCutShortFailsInsteadOfEnding() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        // A damaged CAF: the header still says 3 s, one second of samples is left.
        let url = try audioFile(seconds: 3, name: "audio.caf")
        let data = try Data(contentsOf: url)
        try data.prefix(data.count - Int(2 * rate) * 2).write(to: url)
        let reader = try FileReader(url: url, from: 0, to: try analyzerFormat())
        #expect(reader.duration == 3)
        let inputs = readAll(reader)
        #expect(reader.failure != nil, "a file that ends before its length is a read failure")
        #expect(!reader.reachedEnd)
        #expect(inputs.reduce(0) { $0 + Int($1.buffer.frameLength) } <= 16_000)
    }

    @Test func installErrorsKeepTheirCause() {
        #expect(InstallErrors.downloadError(URLError(.notConnectedToInternet)) == .noConnection)
        #expect(InstallErrors.downloadError(URLError(.timedOut)) == .noConnection)
        #expect(InstallErrors.downloadError(CocoaError(.fileWriteOutOfSpace)) == .notEnoughStorage)
        #expect(InstallErrors.downloadError(POSIXError(.ENOSPC)) == .notEnoughStorage)
        let wrapped = NSError(domain: "com.apple.speech", code: 1,
                              userInfo: [NSUnderlyingErrorKey: URLError(.networkConnectionLost)])
        #expect(InstallErrors.downloadError(wrapped) == .noConnection)
        #expect(InstallErrors.downloadError(NSError(domain: "com.apple.speech", code: 2)) == .install)
    }
}
