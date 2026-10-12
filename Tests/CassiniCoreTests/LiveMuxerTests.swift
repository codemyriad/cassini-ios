@testable import CassiniCore
import Foundation
import Testing

@Suite struct LiveMuxerTests {
    let head = Array("OpusHead".utf8) + [1, 1, 0x38, 1, 0x80, 0xBB, 0, 0, 0, 0, 0]

    /** 20 ms CELT packets (TOC config 31, one frame) of varying size. */
    func packet(_ i: Int) -> [UInt8] {
        (0..<(40 + i % 300)).map { $0 == 0 ? UInt8(31 << 3) : UInt8(truncatingIfNeeded: i + $0) }
    }

    func pages(_ bytes: [UInt8]) throws -> [[UInt8]] {
        let reader = OggOpus.Reader(ArraySource(bytes))
        var pages: [[UInt8]] = []
        while let page = try reader.page() { pages.append(page) }
        return pages
    }

    // ports: LiveMuxerTest#finishedStreamIsCompleteWithMonotonicGranulesAndExactLength
    @Test func finishedStreamIsCompleteWithMonotonicGranulesAndExactLength() throws {
        let out = ArraySink()
        let muxer = try OggOpus.LiveMuxer(out, head: head, tags: CassiniDocument.tagsPacket([]), serial: 7)
        for i in 0..<500 { try muxer.add(packet(i)) }
        let captured = 500 * 960 - 700 as Int64
        try muxer.finish(finalGranule: Int64(muxer.preSkip) + captured)
        let reader = OggOpus.Reader(ArraySource(out.bytes))
        var granules: [Int64] = []
        while let page = try reader.page() { granules.append(OggOpus.i64(page, 6)) }
        #expect(reader.complete)
        #expect(granules.sorted() == granules)
        let info = try OggOpus.scan(ArraySource(out.bytes))
        #expect(info.sampleCount == captured)
        _ = try info.digest()
        // Re-muxing the same packets with the whole-stream muxer gives the same audio digest.
        let stream = try OggOpus.read(out.bytes)
        #expect(try stream.digest() == OggOpus.read(OggOpus.mux(stream, tags: CassiniDocument.tagsPacket([]), serial: 9)).digest())
    }

    // ports: LiveMuxerTest#truncatedCaptureStillReadsUpToItsLastWholePage
    @Test func truncatedCaptureStillReadsUpToItsLastWholePage() throws {
        let out = ArraySink()
        let muxer = try OggOpus.LiveMuxer(out, head: head, tags: CassiniDocument.tagsPacket([]))
        for i in 0..<120 { try muxer.add(packet(i)) }
        let whole = try pages(out.bytes)
        #expect(whole.count == 2 + 119)
        let reader = OggOpus.Reader(ArraySource(Array(out.bytes.dropLast(17))))
        var read = 0
        do { while try reader.page() != nil { read += 1 } } catch {}
        #expect(read == whole.count - 1)
        #expect(reader.valid)
        #expect(!reader.eos)
    }

    // ports: LiveMuxerTest#finishClampsToCoveredSamplesAndNeedsAudio
    @Test func finishClampsToCoveredSamplesAndNeedsAudio() throws {
        let out = ArraySink()
        let muxer = try OggOpus.LiveMuxer(out, head: head, tags: CassiniDocument.tagsPacket([]))
        #expect(throws: CassiniError.self) { try muxer.finish() }
        for i in 0..<3 { try muxer.add(packet(i)) }
        try muxer.finish(finalGranule: 1_000_000)
        #expect(try OggOpus.scan(ArraySource(out.bytes)).sampleCount + 312 == 3 * 960)
    }
}
