import AVFoundation
import Foundation
import Testing
@testable import CassiniAudio

/// The waveform measures AC level (D26.1), so a microphone's DC offset neither draws silence as sound nor changes how
/// loud sound looks.
@Suite struct AudioInspectionTests {
    func level(_ samples: [Float]) -> Float { samples.withUnsafeBufferPointer { AudioInspection.acLevel($0) } }

    @Test func anOffsetAloneIsSilence() {
        #expect(level([Float](repeating: -2060.0 / 32768, count: 2048)) == 0)
        #expect(level([]) == 0)
    }

    @Test func soundOverAnOffsetMeasuresAsWithout() {
        let tone = (0..<2048).map { Float(sin(Double($0) * 2 * .pi * 440 / 48_000)) * 0.3 }
        let clean = level(tone)
        #expect(abs(clean - Float(0.3 / 2.0.squareRoot())) < 0.002)
        #expect(abs(level(tone.map { $0 - 2060.0 / 32768 }) - clean) < 0.0005)
    }

    @Test func theWaveformOfAnOffsetRecordingIsFlat() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buffer.frameLength = 32_000
        for i in 0..<32_000 { buffer.floatChannelData![0][i] = -2060.0 / 32768 }
        try file.write(from: buffer)
        let inspection = try await AudioInspection.inspect(url)
        #expect(inspection.waveform.count == 96)
        #expect(inspection.waveform.allSatisfy { $0 == 0.04 }, "the floor, not a bar of sound")
    }
}
