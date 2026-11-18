import Foundation
import Testing
import CassiniAudio

struct LiveCAFReaderTests {
    @Test func readsOnlyCompleteFramesFromOpenCapture() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var caf = Data([99, 97, 102, 102, 0, 1, 0, 0])
        func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.bigEndian) { caf.append(contentsOf: $0) }
        }
        caf.append(contentsOf: "desc".utf8)
        appendBigEndian(UInt64(32))
        appendBigEndian(Double(48_000).bitPattern)
        caf.append(contentsOf: "lpcm".utf8)
        [UInt32(2), 2, 1, 1, 16].forEach { appendBigEndian($0) }
        caf.append(contentsOf: "data".utf8)
        appendBigEndian(Int64(-1))
        appendBigEndian(UInt32(0))
        caf.append(contentsOf: [1, 0, 2])
        try caf.write(to: url)
        #expect(try LiveCAFReader.read(url, fromFrame: 0)?.pcm16LE == Data([1, 0]))
        #expect(try LiveCAFReader.read(url, fromFrame: 1) == nil)

        caf.append(0)
        try caf.write(to: url)
        let tail = try #require(LiveCAFReader.read(url, fromFrame: 1))
        #expect(tail.firstFrame == 1)
        #expect(tail.pcm16LE == Data([2, 0]))
    }
}
