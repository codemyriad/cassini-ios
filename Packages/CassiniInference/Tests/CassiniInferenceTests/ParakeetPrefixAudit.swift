import AVFoundation
import Darwin
import Foundation
import Testing
@testable import CassiniInference

@Suite struct ParakeetPrefixAudit {
    @Test func measuresExistingReader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("parakeet-audit-\(UUID()).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        try makeAAC(url)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        _ = try measure(url, format: format, target: 28)
        let positions = [28, 288, 808]
        for order in [positions, positions.reversed().map { $0 }, positions] {
            for position in order {
                let sample = try measure(url, format: format, target: position)
                print("PARAKEET_PREFIX seconds=\(position) buffers=\(sample.blocks) frames=\(sample.frames) cpuMs=\(sample.cpu)")
            }
        }
    }

    private func makeAAC(_ url: URL) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let audio = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        let channel = try #require(block.floatChannelData).pointee
        block.frameLength = block.frameCapacity
        for frame in 0..<48_000 {
            let phase = Double(frame)
            let envelope = 0.1 + 0.05 * sin(phase * 0.0007)
            channel[frame] = Float(envelope * sin(phase * 0.052) + 0.03 * sin(phase * 0.16))
        }
        for _ in 0..<825 { try audio.write(from: block) }
    }

    private func measure(_ url: URL, format: AVAudioFormat, target: Int) throws -> (blocks: Int, frames: Int, cpu: Double) {
        let end = target * 16_000
        let start = end - 2 * 16_000
        let began = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let reader = try FileReader(url: url, from: 0, to: format, downmix: true)
        var frames = 0
        var blocks = 0
        var window: [Float] = []
        while frames < end, let (buffer, _) = reader.nextBuffer() {
            let count = Int(buffer.frameLength)
            let channel = try #require(buffer.floatChannelData).pointee
            let samples = Array(UnsafeBufferPointer(start: channel, count: count))
            let need = min(count, end - frames)
            let windowStart = max(0, start - frames)
            if windowStart < need { window.append(contentsOf: samples[windowStart..<need]) }
            frames += need
            blocks += 1
        }
        let cpu = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - began
        #expect(reader.failure == nil)
        #expect(frames == end)
        #expect(window.count == 32_000)
        return (blocks, frames, Double(cpu) / 1_000_000)
    }
}
