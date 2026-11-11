import AVFoundation
import Foundation
import Synchronization
import Testing
import CassiniCore
@testable import CassiniAudio

private final class NativeChunkGate: Sendable {
    private let state = Mutex(0)
    private let entered: AsyncStream<Void>
    private let signal: AsyncStream<Void>.Continuation
    private let release = DispatchSemaphore(value: 0)
    init() { (entered, signal) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1)) }
    func chunk() {
        let first = state.withLock { $0 += 1; return $0 == 1 }
        if first { signal.yield(()); signal.finish(); release.wait() }
    }
    func wait() async { for await _ in entered { return } }
    func open() { release.signal() }
    var count: Int { state.withLock { $0 } }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct NativeWorkCancellationTests {
    private func pcm(_ folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("Synthetic English fixture.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32_000))
        buffer.frameLength = 32_000
        for i in 0..<32_000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) / 30)) * 0.1 }
        try file.write(from: buffer)
        return url
    }

    @Test func cancelInterruptsActualEncodeAndDecodeBeforeAnotherPCMChunk() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try pcm(root)
        let opus = root.appendingPathComponent("original.opus")
        try OpusAudio.encode(input, to: opus)
        for decode in [false, true] {
            let gate = NativeChunkGate()
            defer { gate.open() }
            let source = decode ? opus : input
            let before = try Data(contentsOf: source)
            let target = root.appendingPathComponent(decode ? "cancelled.caf" : "cancelled.opus")
            let task = Task {
                try await CancellableFileWork.run {
                    if decode { try OpusAudio.decode(source, to: target, onChunk: gate.chunk) }
                    else { try OpusAudio.encode(source, to: target, onChunk: gate.chunk) }
                }
            }
            await gate.wait(); task.cancel(); gate.open()
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(gate.count == 1, "The native loop must stop, not merely discard a completed result")
            #expect(!FileManager.default.fileExists(atPath: target.path))
            #expect(try Data(contentsOf: source) == before)
        }
    }

    @Test func cancelInterruptsNativeInspectionAfterItsFirstRead() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = try pcm(root), gate = NativeChunkGate()
        defer { gate.open() }
        let task = Task { try await AudioInspection.inspect(input, onWindow: gate.chunk) }
        await gate.wait(); task.cancel(); gate.open()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(gate.count == 1)
    }
}
