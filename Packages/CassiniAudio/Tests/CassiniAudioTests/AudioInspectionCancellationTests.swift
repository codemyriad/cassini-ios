import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import CassiniAudio

struct AudioInspectionCancellationTests {
    @Test func parentCancellationReachesInspectionAtAnActualPcmBuffer() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent("inspection-cancel-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: source) }
        do {
            let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            for index in 0..<48_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 48_000)) * 0.2 }
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            try file.write(from: buffer)
        }
        let original = try Data(contentsOf: source)
        let (events, started) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let crossed = Mutex(false)
        defer { release.signal(); started.finish() }
        let work = Task {
            try await AudioInspection.inspect(source, onBuffer: {
                let first = crossed.withLock { crossed in
                    if crossed { return false }
                    crossed = true; return true
                }
                if first { started.yield(()); release.wait() }
            })
        }
        var iterator = events.makeAsyncIterator()
        _ = await iterator.next()
        work.cancel()
        release.signal()
        do { _ = try await work.value; Issue.record("Inspection ignored its caller's cancellation") }
        catch { #expect(error is CancellationError) }
        #expect(try Data(contentsOf: source) == original)
    }
}
