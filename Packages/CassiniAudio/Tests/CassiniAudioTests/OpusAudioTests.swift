import Foundation
import AVFoundation
import Testing
import CassiniCore
import CassiniAudio

@Test func opusRoundTripPreservesDurationAndSignal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("input.caf"), opus = root.appendingPathComponent("note.opus"), decoded = root.appendingPathComponent("decoded.caf")
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
    let count: AVAudioFrameCount = 88_421
    do {
        let file = try AVAudioFile(forWriting: source, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)); buffer.frameLength = count
        for c in 0..<2 { for i in 0..<Int(count) { buffer.floatChannelData![c][i] = Float(sin(Double(i) * 440 * 2 * .pi / 44_100)) * 0.3 } }
        try file.write(from: buffer)
    }
    try OpusAudio.encode(source, to: opus)
    let info = try OggOpus.scan(opus)
    #expect(info.validFraming)
    #expect(abs(Double(info.sampleCount) / 48_000 - Double(count) / 44_100) < 0.002)
    try OpusAudio.decode(opus, to: decoded)
    let file = try AVAudioFile(forReading: decoded)
    #expect(file.length == info.sampleCount)
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let energy = (0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(buffer.floatChannelData![0][$1] * buffer.floatChannelData![0][$1]) } / Double(buffer.frameLength)
    #expect(energy > 0.025 && energy < 0.065)
    #expect(FileManager.default.fileExists(atPath: source.path))
}

@Test func invalidOpusFailsWithoutRemovingOriginal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("bad.opus")
    try Data("invalid".utf8).write(to: source)
    #expect(throws: (any Error).self) { try OpusAudio.decode(source, to: root.appendingPathComponent("out.caf")) }
    #expect(try Data(contentsOf: source) == Data("invalid".utf8))
}
