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
        var attributes: UInt32 = 0
        var crc: UInt32?
        var flags: UInt16 = 0x800
        var localName: String?
        var localSignature: UInt32 = 0x04034b50
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
    // Python zlib: 200000 'A' bytes, raw deflate + Z_SYNC_FLUSH, then invalid BTYPE=3 and padding.
    static func corruptTailBomb() -> Member {
        var member = Member("Bomb.wav", Data(repeating: 65, count: 200_000))
        member.method = 8; member.size = 1
        member.packed = Data(base64Encoded: "7MExAQAAAMKgbOtfygz+QAEAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAArwEAAP//")!
        member.packed.append(7)
        member.packed.append(Data(count: 10_000 - member.packed.count))
        return member
    }
    static func unicodePath(raw: String, path: String) -> Data {
        let name = Data(raw.utf8), path = Data(path.utf8)
        let crc = name.withUnsafeBytes { UInt32(CZlib.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(name.count))) }
        var extra = Data(); extra.zip16(0x7075); extra.zip16(UInt16(5 + path.count)); extra.append(1)
        extra.zip32(crc); extra.append(path); return extra
    }
    static func write(_ members: [Member], to url: URL) throws {
        var body = Data(), directory = Data()
        for member in members {
            let name = Data(member.name.utf8), localName = Data((member.localName ?? member.name).utf8), offset = UInt32(body.count)
            let crc = member.crc ?? member.body.withUnsafeBytes { UInt32(CZlib.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(member.body.count))) }
            body.zip32(member.localSignature); body.zip16(20); body.zip16(member.flags); body.zip16(member.localMethod ?? member.method)
            body.zip16(0); body.zip16(0); body.zip32(crc); body.zip32(UInt32(member.packed.count)); body.zip32(member.size)
            body.zip16(UInt16(localName.count)); body.zip16(UInt16(member.localExtra.count)); body.append(localName); body.append(member.localExtra); body.append(member.packed)
            directory.zip32(0x02014b50); directory.zip16(20); directory.zip16(20); directory.zip16(member.flags); directory.zip16(member.method)
            directory.zip16(0); directory.zip16(0); directory.zip32(crc); directory.zip32(UInt32(member.packed.count)); directory.zip32(member.size)
            directory.zip16(UInt16(name.count)); directory.zip16(UInt16(member.extra.count)); directory.zip16(0)
            directory.zip16(0); directory.zip16(0); directory.zip32(member.attributes); directory.zip32(offset); directory.append(name); directory.append(member.extra)
        }
        let start = UInt32(body.count); body.append(directory)
        body.zip32(0x06054b50); body.zip16(0); body.zip16(0); body.zip16(UInt16(members.count)); body.zip16(UInt16(members.count))
        body.zip32(UInt32(directory.count)); body.zip32(start); body.zip16(0)
        try body.write(to: url)
    }
}
