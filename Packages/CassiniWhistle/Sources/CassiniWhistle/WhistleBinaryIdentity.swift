import CryptoKit
import Foundation

/// The code/data pin survives Apple distribution re-signing and symbol stripping. Apple's loader also validates
/// the complete code signature (including link-edit metadata) before any constructor executes. Read-only parsing.
public enum WhistleBinaryIdentity {
    public static func digest(_ data: Data) throws -> String {
        func u32(_ at: Int) throws -> UInt32 {
            guard at >= 0, at <= data.count - 4 else { throw WhistleError.integrity }
            return (0..<4).reduce(0) { $0 | UInt32(data[at+$1]) << (8*$1) }
        }
        func u64(_ at: Int) throws -> UInt64 {
            UInt64(try u32(at)) | UInt64(try u32(at+4)) << 32
        }
        guard data.count >= 32, try u32(0) == 0xfeedfacf, try u32(4) == 0x100000c,
              try u32(12) == 6 else { throw WhistleError.integrity }
        let count = Int(try u32(16)), size = Int(try u32(20))
        guard count <= 1024, size <= data.count-32 else { throw WhistleError.integrity }
        var hashed = Data("cassini-whistle-sections-v1\0".utf8)
        hashed.append(data[4..<16])
        var at = 32, sections = 0
        for _ in 0..<count {
            let cmd = try u32(at), length = Int(try u32(at+4))
            guard length >= 8, length % 8 == 0, length <= 32+size-at else { throw WhistleError.integrity }
            if cmd == 0x19 {
                guard length >= 72 else { throw WhistleError.integrity }
                let n = Int(try u32(at+64))
                guard n <= (length-72)/80, length == 72+n*80 else { throw WhistleError.integrity }
                for i in 0..<n {
                    let s = at+72+i*80, flags = try u32(s+64)
                    if [UInt32(1), 0xc, 0x12].contains(flags & 0xff) { continue }
                    let amount = try u64(s+40), offset = Int(try u32(s+48))
                    guard offset >= 32+size, offset <= data.count, amount <= UInt64(data.count-offset) else {
                        throw WhistleError.integrity
                    }
                    hashed.append(data[s..<s+32]); hashed.append(data[s+40..<s+48])
                    hashed.append(data[s+64..<s+68]); hashed.append(data[offset..<offset+Int(amount)])
                    sections += 1
                }
            } else if [UInt32(0xc), 0xd, 0x80000018, 0x8000001c, 0x8000001f, 0x20, 0x80000023, 0x32, 0x1b, 0x2a].contains(cmd) {
                var little = UInt32(length).littleEndian
                withUnsafeBytes(of: &little) { hashed.append(contentsOf: $0) }
                hashed.append(data[at..<at+length])
            } else if cmd == 0x2c {
                guard length >= 24 else { throw WhistleError.integrity }
                guard try u32(at+16) == 0 else { throw WhistleError.encryptedRuntime }
                var little = UInt32(length).littleEndian
                withUnsafeBytes(of: &little) { hashed.append(contentsOf: $0) }
                hashed.append(data[at..<at+length])
            } else if ![UInt32(2),0xb,0x1d,0x26,0x29,0x80000022,0x80000033,0x80000034].contains(cmd) {
                throw WhistleError.integrity
            }
            at += length
        }
        guard at == 32+size, sections > 0 else { throw WhistleError.integrity }
        return SHA256.hash(data: hashed).map { String(format: "%02x", $0) }.joined()
    }
}
