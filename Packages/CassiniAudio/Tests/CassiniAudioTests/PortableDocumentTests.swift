import Foundation
import AVFoundation
import Testing
import CassiniCore
import CassiniAudio

/// The portable `.opus` document on this platform (Android `PortableDocumentTest`): a document written over the app's
/// own Opus encoding reads back verified, with the duration of the source. Android's second test checks the platform
/// encoder of API 34; iOS encodes with libopus only, so it has no counterpart.
@Suite struct PortableDocumentTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-audio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// `seconds` of a 440 Hz tone at 16 kHz, with `amplitudes[c]` on channel `c`.
    private func tone(_ name: String, seconds: Double, amplitudes: [Float], rate: Double = 16_000) throws -> URL {
        let url = root.appendingPathComponent(name)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: AVAudioChannelCount(amplitudes.count)))
        let count = AVAudioFrameCount(seconds * rate)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count))
        buffer.frameLength = count
        for (channel, amplitude) in amplitudes.enumerated() {
            for i in 0..<Int(count) { buffer.floatChannelData![channel][i] = Float(sin(Double(i) * 440 * 2 * .pi / rate)) * amplitude }
        }
        try file.write(from: buffer)
        return url
    }

    private func energy(ofDecoded opus: URL) throws -> Double {
        let decoded = root.appendingPathComponent(UUID().uuidString + ".caf")
        try OpusAudio.decode(opus, to: decoded)
        let file = try AVAudioFile(forReading: decoded)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let samples = buffer.floatChannelData![0]
        return (0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(samples[$1] * samples[$1]) } / Double(buffer.frameLength)
    }

    // ports: PortableDocumentTest#theEncoderCapabilityHasAClearOutcome
    @Test func aDocumentOverTheAppsOpusEncodingReadsBackVerified() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try tone("fleurs-like.wav", seconds: 9, amplitudes: [0.3])
        let audio = root.appendingPathComponent("portable-encoder.opus")
        let document = root.appendingPathComponent("portable-document.opus")
        try OpusAudio.encode(source, to: audio)
        let words = [Word("S1", 100, 600, "Hello."), Word("S2", 8_000, 8_500, "Welcome.")]

        try CassiniDocument.create(audio, transcript: Transcript(words, language: "it"), title: "Portable",
                                   processing: JSONObject([("model", .string("test"))]), existing: nil,
                                   speakerLabels: ["S1": "Ada"], target: document)

        let read = CassiniDocument.readChecked(document)
        #expect(read.state == .ok)
        #expect(read.speakerLabel("S1") == "Ada")
        #expect(read.selected()?.transcript?.words == words)
        let info = try OggOpus.scan(document)
        #expect(info.validFraming)
        #expect(info.durationMs == 9_000)
        #expect(try info.digest() == OggOpus.scan(audio).digest())
    }

    @Test func stereoIsMixedDownSoTheRightChannelIsKept() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let rightOnly = try tone("right.caf", seconds: 1, amplitudes: [0, 0.3], rate: 44_100)
        let opus = root.appendingPathComponent("right.opus")
        try OpusAudio.encode(rightOnly, to: opus)
        #expect(try OggOpus.scan(opus).channels == 1)
        #expect(try energy(ofDecoded: opus) > 0.005)
    }

    @Test func aFailedEncodeLeavesNothingBehind() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("not-audio.wav")
        try Data("not audio".utf8).write(to: source)
        let opus = root.appendingPathComponent("out.opus")
        #expect(throws: (any Error).self) { try OpusAudio.encode(source, to: opus) }
        #expect(!FileManager.default.fileExists(atPath: opus.path))
    }
}
