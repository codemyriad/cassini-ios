import Foundation
import AVFoundation
import Testing
import CassiniAudio

/// CAF captures cut short by a crash (RecoveryRepositoryTest, adapted from Ogg repair to CAF).
@Suite struct CAFRepairTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Two seconds of a 440 Hz tone in the recorder's format: 48 kHz 16-bit mono PCM in CAF.
    private func capture(_ name: String = "capture.caf") throws -> URL {
        let url = root.appendingPathComponent(name)
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 96_000))
        buffer.frameLength = 96_000
        for index in 0..<96_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.3 }
        try file.write(from: buffer)
        return url
    }

    private func duration(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Keeps the first `fraction` of the file's bytes, plus `extra` bytes of a frame.
    private func truncate(_ url: URL, to fraction: Double, extra: Int = 0) throws {
        let data = try Data(contentsOf: url)
        try data.prefix(Int(Double(data.count) * fraction) / 2 * 2 + extra).write(to: url)
    }

    // ports: RecoveryRepositoryTest#aTruncatedOpusCaptureIsRepairedToPlainWithASaneDuration
    @Test func aTruncatedCaptureIsRepairedToItsWholeFrames() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try capture()
        try truncate(url, to: 0.6, extra: 1)
        #expect(try CAFRepair.repair(url) == .repaired)
        let repaired = try duration(url)
        #expect(repaired > 1 && repaired < 2)
        #expect((try Data(contentsOf: url).count) % 2 == 0, "the partial frame is cut")
        #expect(try CAFRepair.repair(url) == .clean)
    }

    // ports: RecoveryRepositoryTest#aCleanCaptureKeepsItsBytesAndGetsItsDuration
    @Test func aCleanCaptureKeepsItsBytes() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try capture()
        let before = try Data(contentsOf: url)
        #expect(try CAFRepair.repair(url) == .clean)
        #expect(try Data(contentsOf: url) == before)
        #expect(try duration(url) == 2)
    }

    @Test func anUnknownDataSizeIsSetToTheAudioOnDisk() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try capture()
        var data = try Data(contentsOf: url)
        let data4 = try #require(data.range(of: Data("data".utf8)))
        data.replaceSubrange(data4.upperBound ..< data4.upperBound + 8, with: Data(repeating: 0xFF, count: 8))
        try data.write(to: url)
        #expect(try CAFRepair.repair(url) == .repaired)
        #expect(try duration(url) == 2)
    }

    // ports: RecoveryRepositoryTest#aCaptureWithoutAudioIsUnplayable (what the repair leaves alone)
    @Test func otherFilesAreLeftAlone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let garbage = root.appendingPathComponent("garbage.caf")
        try Data("not caf".utf8).write(to: garbage)
        #expect(try CAFRepair.repair(garbage) == .notCAF)
        #expect(try Data(contentsOf: garbage) == Data("not caf".utf8))
        let headerOnly = root.appendingPathComponent("header.caf")
        try Data("caff".utf8 + [0, 1, 0, 0]).write(to: headerOnly)
        #expect(try CAFRepair.repair(headerOnly) == .unsupported)
        #expect(throws: (any Error).self) { try CAFRepair.repair(root.appendingPathComponent("missing.caf")) }
    }
}
