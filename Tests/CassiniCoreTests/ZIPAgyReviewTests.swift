import Foundation
import CZlib
@testable import CassiniCore

/// Synthetic raw-deflate payload; headers are independent of the implementation's ZIP writer.
enum ZIPAgyFixture {
    struct Member {
        var name: String
        var rawName: Data?
        var flags: UInt16 = 0x800
        var localFlags: UInt16?
        var body: Data
        var packed: Data
        var size: UInt32
        var method: UInt16 = 0
        var localMethod: UInt16?
        var extra = Data()
        var localExtra = Data()
        init(_ name: String, _ body: Data) { self.name = name; self.body = body; packed = body; size = UInt32(body.count) }
    }
    static func bomb(padded: Bool, forgedSize: Bool = true) -> Member {
        var member = Member("Bomb.wav", Data(repeating: 65, count: 500_000))
        member.method = 8
        member.packed = Data(base64Encoded: "7cGBAAAAAMMgtvlLHeRVAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAPBs")!
        if padded { member.packed.append(Data(count: 5_000 - member.packed.count)) }
        if forgedSize { member.size = 1 }
        return member
    }
    static func mixedCompressibility() throws -> Member {
        var bytes = Data(repeating: 0, count: 500_000), seed: UInt32 = 17
        for _ in 0..<16_000 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            bytes.append(UInt8(truncatingIfNeeded: seed >> 24))
        }
        var member = Member("Mixed.wav", bytes), stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
                            zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ZIPFailure.entry }
        defer { deflateEnd(&stream) }
        var packed = Data(count: Int(compressBound(uLong(bytes.count))))
        let rc = bytes.withUnsafeBytes { input in
            packed.withUnsafeMutableBytes { output in
                stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
                stream.avail_in = uInt(input.count)
                stream.next_out = output.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(output.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard rc == Z_STREAM_END else { throw ZIPFailure.entry }
        member.method = 8; member.packed = Data(packed.prefix(Int(stream.total_out)))
        return member
    }
    /// Measures the fixture independently of ZIPArchive's ratio checks.
    static func hasOverLimitPrefix(_ member: Member) throws -> Bool {
        var stream = z_stream(), exceeded = false
        guard inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw ZIPFailure.entry }
        defer { inflateEnd(&stream) }
        try member.packed.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(input.count)
            while true {
                var output = Data(count: ZIPArchive.chunkBytes)
                let rc = output.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                if rc != Z_STREAM_END && stream.total_in > 0 && stream.total_out > 100 * stream.total_in { exceeded = true }
                if rc == Z_STREAM_END { break }
                guard rc == Z_OK else { throw ZIPFailure.entry }
            }
        }
        return exceeded
    }
    static func write(_ members: [Member], to url: URL) throws {
        var body = Data(), directory = Data()
        for member in members {
            let name = member.rawName ?? Data(member.name.utf8), offset = UInt32(body.count)
            let crc = member.body.withUnsafeBytes { UInt32(CZlib.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(member.body.count))) }
            body.zip32(0x04034b50); body.zip16(20); body.zip16(member.localFlags ?? member.flags); body.zip16(member.localMethod ?? member.method)
            body.zip16(0); body.zip16(0); body.zip32(crc); body.zip32(UInt32(member.packed.count)); body.zip32(member.size)
            body.zip16(UInt16(name.count)); body.zip16(UInt16(member.localExtra.count)); body.append(name); body.append(member.localExtra); body.append(member.packed)
            directory.zip32(0x02014b50); directory.zip16(20); directory.zip16(20); directory.zip16(member.flags); directory.zip16(member.method)
            directory.zip16(0); directory.zip16(0); directory.zip32(crc); directory.zip32(UInt32(member.packed.count)); directory.zip32(member.size)
            directory.zip16(UInt16(name.count)); directory.zip16(UInt16(member.extra.count)); directory.zip16(0)
            directory.zip16(0); directory.zip16(0); directory.zip32(0); directory.zip32(offset); directory.append(name); directory.append(member.extra)
        }
        let start = UInt32(body.count); body.append(directory)
        body.zip32(0x06054b50); body.zip16(0); body.zip16(0); body.zip16(UInt16(members.count)); body.zip16(UInt16(members.count))
        body.zip32(UInt32(directory.count)); body.zip32(start); body.zip16(0)
        try body.write(to: url)
    }
}
import Testing

@Suite struct ZIPAgyReviewTests {
    @Test func runtimeRatioUsesActualOutputAndActualCompressedInputBeforePadding() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("bomb.zip")
            for padded in [false, true] {
                try ZIPAgyFixture.write([ZIPAgyFixture.bomb(padded: padded, forgedSize: !padded)], to: url)
                let zip = try ZIPArchive(url: url)
                var observed = 0
                #expect(throws: ZIPFailure.tooLarge) {
                    try zip.read(zip.entries[0], remainingBytes: 1_000_000, observed: { observed += $0 }) { _ in }
                }
                #expect(observed == (padded ? 500_000 : ZIPArchive.chunkBytes), "Refuse as soon as the observed ratio crosses the bound")
            }
        }
    }
    @Test func mixedCompressibilityIsJudgedByTheCompleteStreamNotItsHighlyCompressiblePrefix() throws {
        try withTemporaryDirectory { folder in
            let member = try ZIPAgyFixture.mixedCompressibility()
            #expect(member.body.count < member.packed.count * 100)
            #expect(try ZIPAgyFixture.hasOverLimitPrefix(member), "An intermediate prefix must actually exceed 100:1")
            let url = folder.appendingPathComponent("mixed.zip")
            try ZIPAgyFixture.write([member], to: url)
            let zip = try ZIPArchive(url: url)
            var output = Data()
            let count = try zip.read(zip.entries[0], remainingBytes: UInt64(member.body.count)) { output.append($0) }
            #expect(count == member.body.count)
            #expect(output == member.body)
        }
    }

    @Test func prematureEOFStillChecksConsumedRatioBeforeReportingCorruption() throws {
        try withTemporaryDirectory { folder in
            var member = ZIPAgyFixture.Member("Bomb.wav", Data(repeating: 65, count: 200_000))
            member.method = 8; member.size = 1
            let prefix = Data(base64Encoded: "7MExAQAAAMKgbOtfygz+QAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAArwEAAP//")!
            member.packed = prefix + Data(count: 10_000 - prefix.count)
            let url = folder.appendingPathComponent("truncated.zip")
            try ZIPAgyFixture.write([member], to: url)
            let zip = try ZIPArchive(url: url)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: zip.entries[0].offset + UInt64(prefix.count)); try handle.close()
            var observed = 0
            #expect(throws: ZIPFailure.tooLarge) {
                try zip.read(zip.entries[0], remainingBytes: 1_000_000, observed: { observed += $0 }) { _ in }
            }
            #expect(observed == 200_000, "The unfinished deflate prefix must expand before EOF")
        }
    }

    @Test func unreadableDirectoryStreamsAreDamagedForDirectReadersToo() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("directory.zip")
            for packed in [Data([7]), Data([3, 0, 0])] {
                var member = ZIPAgyFixture.Member("Folder/", Data()); member.method = 8; member.packed = packed
                try ZIPAgyFixture.write([member], to: url)
                let zip = try ZIPArchive(url: url)
                #expect(throws: ZIPFailure.damaged) { try zip.read(zip.entries[0], remainingBytes: 100) { _ in } }
            }
        }
    }

    @Test func forgedExpandedSizeKeepsDrainingIntoTheGlobalBudgetWithoutPublishingExcess() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("forged.zip")
            try ZIPAgyFixture.write([ZIPAgyFixture.bomb(padded: true)], to: url)
            let zip = try ZIPArchive(url: url, limits: .init(expandedBytes: 100_000, ratio: 1_000_000))
            var observed = 0, delivered = 0
            #expect(throws: ZIPFailure.tooLarge) {
                try zip.read(zip.entries[0], remainingBytes: 100_000, observed: { observed += $0 }) { delivered += $0.count }
            }
            #expect(observed == ZIPArchive.chunkBytes)
            #expect(delivered == 0)
        }
    }
    @Test func AESMethodsAndExtraFieldsOnEitherHeaderRefuseTheArchive() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("encrypted.zip")
            for kind in 0..<4 {
                var member = ZIPAgyFixture.Member("English.wav", Data())
                switch kind {
                case 0: member.method = 99
                case 1: member.localMethod = 99
                case 2: member.extra = Data([1, 0x99, 0, 0])
                default: member.localExtra = Data([1, 0x99, 0, 0])
                }
                try ZIPAgyFixture.write([member], to: url)
                #expect(throws: ZIPFailure.encrypted) { try ZIPArchive(url: url) }
            }
        }
    }
    @Test func colonAndWindowsRelativeNamesNormalizeButAbsoluteAndParentPathsFail() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("names.zip")
            try ZIPAgyFixture.write([.init("10:30 Standup.wav", Data()), .init("Meetings\\Standup.wav", Data())], to: url)
            let zip = try ZIPArchive(url: url)
            #expect(zip.entries.map(\.name) == ["10:30 Standup.wav", "Standup.wav"])
            for path in ["C:Meeting.wav", "C:\\Meetings\\x.wav", "\\\\server\\x.wav", "Meetings\\..\\x.wav"] {
                #expect(throws: ZIPFailure.unsafePaths) { try ZIPArchive.checkPath(path) }
            }
        }
    }
    @Test func classic65535IsTooLargeAndZIP64LocatorZeroIsSingleDisk() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("count.zip")
            var legacy = Data(); legacy.zip32(0x06054b50); legacy.zip16(0); legacy.zip16(0); legacy.zip16(.max); legacy.zip16(.max)
            legacy.zip32(0); legacy.zip32(0); legacy.zip16(0); try legacy.write(to: url)
            #expect(throws: ZIPFailure.tooLarge) { try ZIPArchive(url: url) }
            let source = folder.appendingPathComponent("empty"); try Data().write(to: source)
            let writer = try StoredZIPWriter(url: url); try writer.add(file: source, name: "English.wav"); try writer.finish()
            var bytes = try Data(contentsOf: url)
            let locator = bytes.count - 22 - 20
            for i in 0..<4 { bytes[locator + 16 + i] = 0 }
            try bytes.write(to: url)
            #expect(try ZIPArchive(url: url).entries.count == 1)
            bytes[locator + 16] = 2; try bytes.write(to: url)
            #expect(throws: ZIPFailure.damaged) { try ZIPArchive(url: url) }
        }
    }
}
