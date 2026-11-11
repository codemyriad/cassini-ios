import AVFoundation
import CassiniAudio
import Foundation
import Synchronization
import XCTest
@testable import Cassini

final class AudioWorkCancellationTests: XCTestCase {
    /// A real native PCM chunk is the event: cancellation must reach the detached encoder before it resumes.
    @MainActor func testCancellingAudioAdapterStopsNativeEncodingAndRemovesPartialOutput() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("Synthetic English sample.wav")
        let destination = folder.appendingPathComponent("export.opus")
        try writeSyntheticSignal(to: source)
        let original = try Data(contentsOf: source)
        let firstPacket = expectation(description: "The first actual Opus PCM packet was encoded")
        let release = DispatchSemaphore(value: 0)
        let crossed = Mutex(false)
        defer { release.signal() }
        let processing = LocalAudioProcessing(encode: { source, destination in
            try OpusAudio.encode(source, to: destination, onChunk: {
                let first = crossed.withLock { crossed in
                    if crossed { return false }
                    crossed = true; return true
                }
                if first { firstPacket.fulfill(); release.wait() }
            })
        })
        let work = Task { try await processing.encodeOpus(source, to: destination) }
        await fulfillment(of: [firstPacket], timeout: 15)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        work.cancel()
        release.signal()
        do { try await work.value; XCTFail("Native encoding ignored adapter cancellation") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    private func writeSyntheticSignal(to destination: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for index in 0..<48_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.2 }
        let file = try AVAudioFile(forWriting: destination, settings: format.settings)
        try file.write(from: buffer)
    }
}
