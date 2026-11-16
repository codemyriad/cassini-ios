import Foundation
import AVFoundation
import Testing
import CassiniAudio
import CassiniCore
import CassiniEngine
import CassiniEngineTesting

@Suite struct FLACImportTests {
    @Test(arguments: [48_000, 44_100]) func nativeAndExtensionlessCopy(rate: Int) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = FLACFixtures.native(rate: rate)
        for name in ["native.flac", "shared-audio"] {
            let source = folder.appendingPathComponent(name), destination = folder.appendingPathComponent("staged.tmp")
            try bytes.write(to: source)
            let info = try #require(try NativeFLAC.validateIfPresent(source))
            #expect(info.totalSamples == FLACFixtures.samples)
            // Inspect both names directly as well as copying them: adding playback duration must not narrow
            // the valid FLAC inputs accepted by the decoder, including extensionless Open-with inputs.
            let player = try AVAudioPlayer(contentsOf: source)
            let inspection = try await AudioInspection.inspect(source)
            #expect(inspection.duration == player.duration)
            #expect(inspection.duration == Double(FLACFixtures.samples) / Double(rate))
            #expect(inspection.waveform.count == 96)
            let importer = CoordinatedFileImporter(storage: FakeStorage())
            _ = try await importer.copy(from: source, to: destination, maxBytes: 1 << 20, reserveBytes: 0)
            #expect(try Data(contentsOf: destination) == bytes)
            try FileManager.default.removeItem(at: destination)
        }
    }
    @Test(arguments: [48_000, 44_100]) func unknownSampleCountRequiresCompleteNonemptyFrames(rate: Int) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
        defer { try? FileManager.default.removeItem(at: url) }
        var bytes = FLACFixtures.native(rate: rate)
        bytes[21] &= 0xf0
        for index in 22...25 { bytes[index] = 0 }
        try bytes.write(to: url)
        #expect(try NativeFLAC.validateIfPresent(url)?.totalSamples == 0)
        // Every possible cut inside the last frame, plus an empty stream, must fail.
        for count in [FLACFixtures.audioOffset] + Array((bytes.count - FLACFixtures.frameBytes + 1)..<bytes.count) {
            try bytes.prefix(count).write(to: url)
            #expect(throws: (any Error).self) { try NativeFLAC.validateIfPresent(url) }
        }
        // A corrupt later header with repaired CRC-16 is not a complete valid stream.
        bytes[FLACFixtures.audioOffset + FLACFixtures.frameBytes + 5] ^= 1
        var crc: UInt16 = 0
        let start = FLACFixtures.audioOffset + FLACFixtures.frameBytes
        for byte in bytes[start..<(start + FLACFixtures.frameBytes - 2)] {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x8005 : crc &<< 1 }
        }
        bytes[start + FLACFixtures.frameBytes - 2] = UInt8(crc >> 8)
        bytes[start + FLACFixtures.frameBytes - 1] = UInt8(crc & 255)
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { try NativeFLAC.validateIfPresent(url) }
    }

    @Test(arguments: [16, 24, 32]) func encodedStereoFramesAcrossValidationWindows(depth: Int) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
        defer { try? FileManager.default.removeItem(at: url) }
        // Exercise native encoder output (predictors, residuals, stereo decorrelation and verbatim
        // blocks) as well as the tiny constant-subframe fixtures, across multiple 64 KiB windows.
        let count: AVAudioFrameCount = 48_000
        do {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatFLAC, AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: depth
            ])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count))
            buffer.frameLength = count
            let channels = try #require(buffer.floatChannelData)
            var random: UInt32 = 1
            for index in 0..<Int(count) {
                random = random &* 1664525 &+ 1013904223
                let signal = index < 24_000 ? Float(sin(Double(index) * 0.05)) * 0.3 : Float(Int32(bitPattern: random)) / Float(Int32.max) * 0.3
                channels[0][index] = signal
                channels[1][index] = signal * 0.5
            }
            try file.write(from: buffer)
        }
        #expect(try NativeFLAC.validateIfPresent(url)?.totalSamples == Int64(count))
        var bytes = try Data(contentsOf: url)
        bytes[21] &= 0xf0
        for index in 22...25 { bytes[index] = 0 }
        try bytes.write(to: url)
        #expect(try NativeFLAC.validateIfPresent(url)?.totalSamples == 0)
        try bytes.dropLast().write(to: url)
        #expect(throws: (any Error).self) { try NativeFLAC.validateIfPresent(url) }
        // CRC-zero trailing bytes are not another complete frame, even with an unknown total.
        try (bytes + Data([0, 0])).write(to: url)
        #expect(throws: (any Error).self) { try NativeFLAC.validateIfPresent(url) }
    }

    @Test func typeAndMIMEAdmission() throws {
        for mime in ["audio/flac", "audio/x-flac"] {
            try ImportPolicy.validate(header: FLACFixtures.native(), filename: "shared", fileBytes: nil,
                                      typeIdentifier: "org.xiph.flac", mimeType: mime)
            for bytes in FLACFixtures.invalid.prefix(4) {
                #expect(throws: FileImportError.cannotOpen) {
                    try ImportPolicy.validate(header: bytes, filename: "shared", fileBytes: nil,
                                              typeIdentifier: "org.xiph.flac", mimeType: mime)
                }
            }
            #expect(ImportPolicy.accepts(filename: "shared", typeIdentifier: "org.xiph.flac", mimeType: mime))
            #expect(!ImportPolicy.accepts(filename: "shared.mp3", typeIdentifier: "org.xiph.flac", mimeType: mime))
        }
        for mime in ["audio/ogg", "application/ogg", "audio/x-oggflac", "audio/x-flac+ogg"] {
            #expect(!ImportPolicy.accepts(filename: "native.flac", typeIdentifier: "org.xiph.flac", mimeType: mime))
        }
    }
    @Test func damagedStreamsNeverLeaveStaging() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for bytes in FLACFixtures.invalid {
            for name in ["broken.flac", "shared-audio"] {
                let source = folder.appendingPathComponent(name), destination = folder.appendingPathComponent("stage.tmp")
                try bytes.write(to: source)
                await #expect(throws: (any Error).self) {
                    try await AudioInspection.inspect(source)
                }
                await #expect(throws: FileImportError.cannotOpen) {
                    try await CoordinatedFileImporter(storage: FakeStorage()).copy(from: source, to: destination, maxBytes: 1 << 20, reserveBytes: 0)
                }
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                #expect(try Data(contentsOf: source) == bytes)
            }
        }
    }
}
