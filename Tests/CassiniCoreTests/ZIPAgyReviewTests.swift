import Foundation
import CZlib
@testable import CassiniCore

/// Synthetic raw-deflate payload; headers are independent of the implementation's ZIP writer.
enum ZIPAgyFixture {
    struct Member {
        var name: String
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
    static func write(_ members: [Member], to url: URL) throws {
        var body = Data(), directory = Data()
        for member in members {
            let name = Data(member.name.utf8), offset = UInt32(body.count)
            let crc = member.body.withUnsafeBytes { UInt32(CZlib.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(member.body.count))) }
            body.zip32(0x04034b50); body.zip16(20); body.zip16(0x800); body.zip16(member.localMethod ?? member.method)
            body.zip16(0); body.zip16(0); body.zip32(crc); body.zip32(UInt32(member.packed.count)); body.zip32(member.size)
            body.zip16(UInt16(name.count)); body.zip16(UInt16(member.localExtra.count)); body.append(name); body.append(member.localExtra); body.append(member.packed)
            directory.zip32(0x02014b50); directory.zip16(20); directory.zip16(20); directory.zip16(0x800); directory.zip16(member.method)
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
