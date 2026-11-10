import AVFoundation
import Foundation
import Testing
@testable import CassiniInference

@Suite struct WhistleAudioReaderTests {
    @Test(arguments: [16_000, 44_100, 48_000], [false, true])
    func resumedBlocksAreExactlyTheSameAfterSeeking(rate: Int, compressed: Bool) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(compressed ? "audio.m4a" : "audio.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 2))
        let frameCount = AVAudioFrameCount(4 * rate + 127)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        let channels = try #require(buffer.floatChannelData)
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            channels[0][frame] = Float(0.3 * sin(Double(frame) * 0.013) + 0.1 * cos(Double(frame) * 0.3))
            channels[1][frame] = Float(0.2 * cos(Double(frame) * 0.025))
        }
        try write(buffer, to: url, compressed: compressed)

        let reader = try WhistleAudioReader(url: url, position: 0)
        var blocks: [[Float]] = []
        var positions: [Int64] = [0]
        while let block = try reader.next() {
            blocks.append(block)
            positions.append(reader.position)
        }
        #expect(blocks.count == 5)
        #expect(positions.last == reader.length)
        #expect(blocks.flatMap { $0 }.count == reader.inputFrames(through: reader.length))
        for index in [1, 2, 4] {
            let resumed = try WhistleAudioReader(url: url, position: positions[index])
            for expected in blocks[index...] {
                let read = try #require(resumed.nextReadRange)
                #expect(read.lowerBound == resumed.position - Int64(rate / 10))
                #expect(read.count <= 12 * rate / 10)
                let actual = try #require(try resumed.next())
                // Avoid printing hundreds of thousands of floats on a regression.
                #expect(actual.elementsEqual(expected), "resume at block \(index), read through \(resumed.position)")
            }
            #expect(try resumed.next() == nil)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, to url: URL, compressed: Bool) throws {
        var settings = buffer.format.settings
        if compressed {
            settings = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: buffer.format.sampleRate,
                AVNumberOfChannelsKey: Int(buffer.format.channelCount)
            ]
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
