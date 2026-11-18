import Foundation
import Synchronization
import Testing
import CassiniCore
@testable import CassiniInference

struct LiveCAFTranscriptionTests {
    @Test func aClosedWakeStreamDrainsTheAvailableAudioAndSettlesTheDraft() async throws {
        let input = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: input) }
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
        audio.append(Data(repeating: 1, count: 48_000 * 2))
        try audio.write(to: input)

        let (wakes, continuation) = AsyncStream<Void>.makeStream()
        continuation.finish()
        let updates = Mutex<[LiveCAFTranscription.Event]>([])
        try await LiveCAFTranscription.follow(url: input, wakes: wakes, decode: { samples in
            #expect(samples.count == 16_000)
            return [Word("", 20, 350, "hello")]
        }, events: { event in updates.withLock { $0.append(event) } })
        let final = updates.withLock { $0 }
        #expect(final.count == 1)
        if case let .revision(start, end, settled, words) = final.first {
            #expect(start == 0)
            #expect(end == 1000)
            #expect(settled == 1000)
            #expect(words.map(\.text) == ["hello"])
        } else {
            Issue.record("Expected a settled revision")
        }
    }
}
