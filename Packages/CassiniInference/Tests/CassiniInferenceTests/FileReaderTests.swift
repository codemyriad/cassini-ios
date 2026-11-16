import AVFoundation
import Foundation
import CassiniEngineTesting
import CassiniEngine
import CassiniAudio
import CassiniCore
import Synchronization
import Speech
import Testing
@testable import CassiniInference

/// `FileReader` over generated WAV and CAF files: the resume offset, the recording-clock time of the first block, block reading,
/// conversion, the end of the file and a file cut short.
@Suite struct FileReaderTests {
    @Test(arguments: [48_000, 44_100]) func nativeFLACReachesTheEndForAppleAndParakeet(rate: Int) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try FLACFixtures.native(rate: rate).write(to: url)
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let reader = try FileReader(url: url, from: 0, to: output, downmix: true)
        var count = 0
        while let block = reader.nextBuffer() { count += Int(block.0.frameLength) }
        #expect(abs(count - FLACFixtures.samples * 16_000 / rate) <= 1)
        #expect(reader.reachedEnd)
        #expect(reader.failure == nil)
        for bytes in FLACFixtures.invalid {
            try bytes.write(to: url)
            #expect(throws: (any Error).self) { try FileReader(url: url, from: 0, to: output) }
        }
    }

    @Test func cancellationDuringValidationOnInferenceThread() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".flac")
        defer { try? FileManager.default.removeItem(at: url) }
        try FLACFixtures.native(frames: 8192).write(to: url)
        let cancel = CancelFlag()
        let decoding = Mutex(false)
        NativeFLAC.observeValidation(at: url) { event in
            // This callback is the event: cancellation happens only after frame validation starts,
            // on the actual dedicated thread, before any full decode can finish.
            if event == .checkingFrames { cancel.set() }
            if event == .decoding { decoding.withLock { $0 = true } }
        }
        defer { NativeFLAC.observeValidation(at: url, nil) }
        await #expect(throws: CancellationError.self) {
            try await InferenceThread.speech.run {
                withUnsafeCurrentTask { task in #expect(task == nil) }
                let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
                _ = try FileReader(url: url, from: 0, to: format, checkCancellation: cancel.check)
            }
        }
        #expect(!decoding.withLock { $0 })
        // A cancelled validation must not populate the cache.
        NativeFLAC.observeValidation(at: url) { event in
            if event == .decoding { decoding.withLock { $0 = true } }
        }
        try NativeFLAC.validateIfPresent(url)
        #expect(decoding.withLock { $0 })
    }

    @Test func importedFLACValidationIsReusedByEveryReaderAndInvalidatedByChanges() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("extensionless")
        let staged = root.appendingPathComponent("source.tmp")
        let final = root.appendingPathComponent("source.flac")
        let passes = Mutex(0)
        for url in [staged, final] {
            NativeFLAC.observeValidation(at: url) { event in
                if event == .decoding { passes.withLock { $0 += 1 } }
            }
        }
        defer {
            NativeFLAC.observeValidation(at: staged, nil)
            NativeFLAC.observeValidation(at: final, nil)
        }
        let bytes = FLACFixtures.native()
        try bytes.write(to: source)
        _ = try await CoordinatedFileImporter(storage: FakeStorage()).copy(
            from: source, to: staged, maxBytes: 1 << 20, reserveBytes: 0)
        #expect(passes.withLock { $0 } == 1)
        try NativeFLAC.moveValidatedFile(from: staged, to: final)
        _ = try await AudioInspection.inspect(final)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        _ = try FileReader(url: final, from: 0, to: format)
        _ = try WhistleAudioReader(url: final, position: 0)
        try OpusAudio.encode(final, to: root.appendingPathComponent("export.opus"))
        #expect(passes.withLock { $0 } == 1)
        // Cache hits still honor cancellation, including readers on a non-Task inference thread.
        let cancel = CancelFlag(); cancel.set()
        #expect(throws: CancellationError.self) {
            try FileReader(url: final, from: 0, to: format, checkCancellation: cancel.check)
        }
        #expect(throws: CancellationError.self) {
            try WhistleAudioReader(url: final, position: 0, checkCancellation: cancel.check)
        }
        // Same size/inode, changed mtime: revalidate once, then reuse.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: final.path)
        try NativeFLAC.validateIfPresent(final)
        #expect(passes.withLock { $0 } == 2)
        // Replacing an inode with the same size and mtime must also force a pass.
        let replacement = root.appendingPathComponent("replacement")
        try bytes.write(to: replacement)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: replacement.path)
        try FileManager.default.removeItem(at: final)
        try FileManager.default.moveItem(at: replacement, to: final)
        try NativeFLAC.validateIfPresent(final)
        #expect(passes.withLock { $0 } == 3)
        // Even an identical cache key never bypasses the cheap magic/header check.
        let header = try FileHandle(forWritingTo: final)
        try header.write(contentsOf: Data([0]))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: final.path)
        #expect(throws: (any Error).self) { try NativeFLAC.validateIfPresent(final) }
        try header.seek(toOffset: 0)
        try header.write(contentsOf: Data([bytes[0]]))
        try header.close()
        let handle = try FileHandle(forWritingTo: final)
        try handle.truncate(atOffset: UInt64(bytes.count - 1))
        try handle.close()
        #expect(throws: (any Error).self) { try NativeFLAC.validateIfPresent(final) }
        await #expect(throws: (any Error).self) { try await AudioInspection.inspect(final) }
        #expect(throws: (any Error).self) { try FileReader(url: final, from: 0, to: format) }
        #expect(throws: (any Error).self) { try WhistleAudioReader(url: final, position: 0) }
        #expect(throws: (any Error).self) { try OpusAudio.encode(final, to: root.appendingPathComponent("bad.opus")) }
    }

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
