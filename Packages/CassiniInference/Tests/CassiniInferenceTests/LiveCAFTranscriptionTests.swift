import Foundation
import Synchronization
import Testing
import CassiniCore
@testable import CassiniInference

struct LiveCAFTranscriptionTests {
    @Test func aClosedWakeStreamDrainsTheAvailableAudioAndSettlesTheDraft() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: input) }
        try caf(frames: 48_000).write(to: input)

        let (wakes, continuation) = AsyncStream<Void>.makeStream()
        continuation.finish()
        let updates = Mutex<[LiveCAFTranscription.Event]>([])
        try await LiveCAFTranscription.follow(url: input, wakes: wakes, decode: { samples in
            #expect(samples.count == 16_000)
            return [Word("", 20, 350, "hello")]
        }, events: { event in updates.withLock { $0.append(event) } })
        let final = updates.withLock { $0 }
        #expect(final.count == 1)
        if case let .revision(start, end, settled, words)? = final.first {
            #expect(start == 0)
            #expect(end == 1000)
            #expect(settled == 1000)
            #expect(words.map(\.text) == ["hello"])
        } else {
            Issue.record("Expected a settled revision")
        }
    }

    @Test func growingRecordingSettlesAtAnEdgeAndRejectsAJitteredDuplicate() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try caf(frames: 48_000 * 3 + 1_000).write(to: url)
        let (ticks, tick) = AsyncStream<Void>.makeStream()
        let (events, emit) = AsyncStream<LiveCAFTranscription.Event>.makeStream()
        let follower = Task {
            defer { emit.finish() }
            try await LiveCAFTranscription.follow(url: url, wakes: ticks, decode: { audio in
                if audio.count <= 48_000 {
                    return [Word("", 850, 980, "one")]
                }
                return [Word("", 930, 1060, "one"), Word("", 940, 1140, "two")]
            }, events: { emit.yield($0) })
        }
        tick.yield()
        var updates = events.makeAsyncIterator()
        _ = await updates.next()
        guard case let .revision(_, _, settled, words)? = await updates.next() else {
            follower.cancel()
            Issue.record("The growing file never reached the second window")
            return
        }
        #expect(settled == 980)
        #expect(words.map(\.text) == ["one"])

        let file = try FileHandle(forWritingTo: url)
        try file.seekToEnd()
        try file.write(contentsOf: Data(repeating: 1, count: 48_000 * 4))
        try file.close()
        tick.yield()
        tick.finish()
        try await follower.value
        while let update = await updates.next() {
            if case let .revision(from, _, _, revised) = update {
                #expect(from >= 980)
                #expect(revised.map(\.text) == ["two"] || revised.isEmpty)
            }
        }
    }

    private func caf(frames: Int) -> Data {
        var audio = Data([99, 97, 102, 102, 0, 1, 0, 0])
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.bigEndian) { audio.append(contentsOf: $0) }
        }
        audio.append(contentsOf: "desc".utf8)
        append(UInt64(32))
        append(Double(48_000).bitPattern)
        audio.append(contentsOf: "lpcm".utf8)
        [UInt32(2), 2, 1, 1, 16].forEach { append($0) }
        audio.append(contentsOf: "data".utf8)
        append(Int64(-1))
        append(UInt32(0))
        audio.append(Data(repeating: 1, count: frames * 2))
        return audio
    }
}
