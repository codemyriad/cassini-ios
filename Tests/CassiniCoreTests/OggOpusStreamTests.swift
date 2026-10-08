@testable import CassiniCore
import Foundation
import XCTest

final class OggOpusStreamTests: XCTestCase {
    private let head = Array("OpusHead".utf8) + [1, 1, 0x38, 1, 0x80, 0xBB, 0, 0, 0, 0, 0]

    /** The whole-buffer muxer as it shipped on Android before streaming, kept as the golden reference. */
    private func legacyMux(_ stream: OggOpus.Stream, _ tags: [UInt8], _ serial: Int32) throws -> [UInt8] {
        var out: [UInt8] = []
        var seq: Int32 = 0
        func packet(_ bytes: [UInt8], _ flags: Int, _ granule: Int64) {
            var laces = [Int](repeating: 255, count: bytes.count / 255); laces.append(bytes.count % 255)
            var offset = 0
            for (index, start) in stride(from: 0, to: laces.count, by: 255).enumerated() {
                let group = Array(laces[start..<min(start + 255, laces.count)])
                let size = group.reduce(0, +)
                var page = [UInt8](repeating: 0, count: 27 + group.count + size)
                page.replaceSubrange(0..<4, with: Array("OggS".utf8))
                let last = offset + size == bytes.count && group.last! < 255
                page[5] = UInt8((index > 0 ? 1 : flags & 2) | (last ? flags & 4 : 0))
                page.replaceSubrange(6..<14, with: OggOpus.le64(last ? granule : -1))
                OggOpus.put32(&page, 14, serial); OggOpus.put32(&page, 18, seq); seq += 1
                page[26] = UInt8(group.count)
                for (i, n) in group.enumerated() { page[27 + i] = UInt8(n) }
                for i in 0..<size { page[27 + group.count + i] = bytes[offset + i] }
                OggOpus.put32(&page, 22, OggOpus.crc(page)); out += page; offset += size
            }
        }
        packet(stream.head, 2, 0); packet(tags, 0, 0)
        var granule: Int64 = 0
        for (i, bytes) in stream.audio.enumerated() {
            granule += Int64(try OggOpus.packetSamples(bytes))
            let last = i == stream.audio.count - 1
            packet(bytes, last ? 4 : 0, last ? stream.finalGranule : granule)
        }
        return out
    }

    /** Packet sizes straddle the 255-byte lacing edges; the tags span several pages. */
    private func fixture() throws -> [UInt8] {
        var state: UInt64 = 7
        let audio: [[UInt8]] = [1, 254, 255, 256, 510, 1275, 4000, 65025, 65026, 3].map { n in
            var packet = (0..<n).map { _ -> UInt8 in
                state = state &* 6364136223846793005 &+ 1442695040888963407
                return UInt8(truncatingIfNeeded: state >> 33)
            }
            packet[0] = 0xF8
            return packet
        }
        let tags = CassiniDocument.tagsPacket(["TITLE=fixture", "X_BIG=" + String(repeating: "x", count: 70000)])
        return try legacyMux(OggOpus.Stream(head: head, tags: tags, audio: audio, finalGranule: Int64(audio.count) * 960 + 312 - 100, validFraming: true), tags, 0x1234)
    }

    private func fixtures() throws -> [[UInt8]] {
        var vectors: [[UInt8]] = []
        if let directory = try? conformanceDirectory(),
           let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) {
            for case let url as URL in files where url.pathExtension == "opus" {
                let data = try bytes(url)
                if let stream = try? OggOpus.read(data), stream.validFraming && !stream.audio.isEmpty { vectors.append(data) }
            }
        }
        return vectors + [try fixture()]
    }

    func testRewriteIsByteIdenticalToTheLegacyMux() throws {
        let tags = CassiniDocument.tagsPacket(["TITLE=rewritten", "X_PAD=" + String(repeating: "y", count: 300)])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for data in try fixtures() {
            let stream = try OggOpus.read(data)
            let expected = try legacyMux(stream, tags, 99)
            let out = ArraySink()
            let info = try OggOpus.rewrite(ArraySource(data), tags: tags, to: out, serial: 99)
            XCTAssertEqual(expected, out.bytes)
            XCTAssertEqual(expected, try OggOpus.mux(stream, tags: tags, serial: 99))
            XCTAssertEqual(try stream.digest(), try info.digest()); XCTAssertEqual(stream.sampleCount, info.sampleCount)
            let source = dir.appendingPathComponent("source.opus"), target = dir.appendingPathComponent("target.opus")
            try Data(data).write(to: source)
            XCTAssertEqual(try stream.digest(), try OggOpus.rewrite(source, tags: tags, to: target, serial: 99).digest())
            XCTAssertEqual(expected, try bytes(target))
        }
    }

    func testMuxerStreamsTheSameBytesAndDropsFlushPackets() throws {
        let tags = CassiniDocument.tagsPacket([])
        for data in try fixtures() {
            let stream = try OggOpus.read(data)
            var covered: Int64 = 0
            var used: [[UInt8]] = []
            for packet in stream.audio {
                if covered >= stream.finalGranule { break }
                covered += Int64(try OggOpus.packetSamples(packet)); used.append(packet)
            }
            if covered < stream.finalGranule { continue }
            let out = ArraySink()
            let muxer = try OggOpus.Muxer(out, head: stream.head, tags: tags, finalGranule: stream.finalGranule, serial: 7)
            for packet in stream.audio + [stream.audio.last!] { try muxer.add(packet) }
            try muxer.finish()
            let trimmed = OggOpus.Stream(head: stream.head, tags: stream.tags, audio: used, finalGranule: stream.finalGranule, validFraming: true)
            XCTAssertEqual(try legacyMux(trimmed, tags, 7), out.bytes)
        }
        let stream = try OggOpus.read(try fixture())
        let short = try OggOpus.Muxer(ArraySink(), head: stream.head, tags: tags, finalGranule: stream.finalGranule + 1_000_000, serial: 7)
        for packet in stream.audio { try short.add(packet) }
        XCTAssertThrowsError(try short.finish())
    }

    func testScanMatchesTheWholeBufferReader() throws {
        for data in try fixtures() {
            let stream = try OggOpus.read(data), info = try OggOpus.scan(ArraySource(data))
            XCTAssertEqual(try stream.digest(), try info.digest())
            XCTAssertEqual(stream.sampleCount, info.sampleCount); XCTAssertEqual(stream.durationMs, info.durationMs)
            XCTAssertEqual(stream.tags, info.tags)
        }
    }

    func testCorruptCrcIsRejectedWhileStreaming() throws {
        let data = try fixture()
        var changed = data
        changed[changed.count - 1] ^= 1 // the final page's payload
        let info = try OggOpus.scan(ArraySource(changed))
        XCTAssertFalse(info.validFraming)
        XCTAssertThrowsError(try info.digest())
        XCTAssertThrowsError(try OggOpus.rewrite(ArraySource(changed), tags: info.tags, to: ArraySink()))
        XCTAssertThrowsError(try OggOpus.scan(ArraySource(Array(data.dropLast()))))
    }

    func testFileDocumentsVerifyFromDiskAndHeadersOnlyStayUnverified() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("audio.opus"), target = dir.appendingPathComponent("doc.opus")
        try Data(try fixture()).write(to: audio)
        let transcript = Transcript([Word("spk_1", 0, 20, "Ciao")], language: "it")
        let doc = try CassiniDocument.create(audio, transcript: transcript, title: "Streamed", processing: JSONObject(),
                                             existing: nil, speakerLabels: [:], target: target)
        XCTAssertEqual("ok", doc.state)
        XCTAssertEqual("ok", CassiniDocument.read(target).state)
        let headers = CassiniDocument.read(target, verify: false)
        XCTAssertEqual("unverified", headers.state); XCTAssertEqual(transcript, headers.selected()?.transcript)
        XCTAssertEqual(try OggOpus.scan(audio).digest(), try OggOpus.scan(target).digest())
    }
}
