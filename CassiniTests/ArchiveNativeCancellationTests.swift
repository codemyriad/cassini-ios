import XCTest
import Foundation
import AVFoundation
import Synchronization
import CassiniAudio
import CassiniEngineTesting
@testable import Cassini

@MainActor final class ArchiveNativeCancellationTests: XCTestCase {
    func testAppAudioAdapterCancelsActualNativeWorkAndRemovesPartialFiles() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Synthetic English fixture.caf")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
            pcm.frameLength = 32_000
            for i in 0..<32_000 { pcm.floatChannelData![0][i] = 0.1 }
            try file.write(from: pcm)
        }
        let opus = root.appendingPathComponent("original.opus")
        try await FakeAudioProcessing(duration: 2).encodeOpus(source, to: opus)
        for decode in [false, true] {
            let entered = expectation(description: "actual native PCM chunk was produced")
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            let counts = Mutex((chunks: 0, onMain: false))
            let adapter = LocalAudioProcessing(onNativeChunk: {
                let first = counts.withLock { state in
                    state.chunks += 1; state.onMain = state.onMain || Thread.isMainThread
                    return state.chunks == 1
                }
                if first { entered.fulfill(); release.wait() }
            })
            let target = root.appendingPathComponent(decode ? "cancelled.caf" : "cancelled.opus")
            let task = Task {
                if decode { try await adapter.decodeOpus(opus, to: target) }
                else { try await adapter.encodeOpus(source, to: target) }
            }
            await fulfillment(of: [entered], timeout: 30)
            task.cancel(); release.signal()
            do { try await task.value; XCTFail("Native work must observe cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
            XCTAssertEqual(counts.withLock { $0.chunks }, 1)
            XCTAssertFalse(counts.withLock { $0.onMain })
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
    }
}
