#if DEBUG
import Foundation

/// Generated constant-signal RFC 9639 streams: three independently checksummed 4096-sample frames.
/// No encoder, recordings or model files are needed by the tests.
public enum FLACFixtures {
    public static let samples = 12_288
    public static let frameBytes = 11
    public static let audioOffset = 42 + 4 + 8192
    public static func native(rate: Int = 48_000, frames: Int = 3) -> Data {
        precondition((1...65_535).contains(frames))
        var h = [UInt8](repeating: 0, count: 42)
        h.replaceSubrange(0..<8, with: [0x66, 0x4c, 0x61, 0x43, 0, 0, 0, 34])
        h[8] = 0x10; h[10] = 0x10
        let packed = UInt64(rate) << 44 | UInt64(15) << 36 | UInt64(frames * 4096)
        for i in 0..<8 { h[18 + i] = UInt8(truncatingIfNeeded: packed >> (56 - 8 * i)) }
        // Use padded metadata and fixed block/rate codes, as production encoders do.
        h += [0x81, 0, 0x20, 0] + [UInt8](repeating: 0, count: 8192)
        for number in 0..<frames {
            var frame: [UInt8] = [0xff, 0xf8, rate == 48_000 ? 0xca : 0xc9, 0x08]
            // FLAC's UTF-8 frame number, including multi-byte numbers in long cancellation fixtures.
            if number < 0x80 { frame.append(UInt8(number)) }
            else if number < 0x800 {
                frame += [0xc0 | UInt8(number >> 6), 0x80 | UInt8(number & 63)]
            } else {
                frame += [0xe0 | UInt8(number >> 12), 0x80 | UInt8(number >> 6 & 63), 0x80 | UInt8(number & 63)]
            }
            var crc8: UInt8 = 0
            for b in frame {
                crc8 ^= b
                for _ in 0..<8 { crc8 = crc8 & 0x80 != 0 ? (crc8 &<< 1) ^ 7 : crc8 &<< 1 }
            }
            frame += [crc8, 0, 0x12, 0x34]
            var crc16: UInt16 = 0
            for b in frame {
                crc16 ^= UInt16(b) << 8
                for _ in 0..<8 { crc16 = crc16 & 0x8000 != 0 ? (crc16 &<< 1) ^ 0x8005 : crc16 &<< 1 }
            }
            frame += [UInt8(crc16 >> 8), UInt8(crc16 & 255)]
            h += frame
        }
        return Data(h)
    }
    public static var invalid: [Data] {
        let valid = native()
        var zeroRate = valid; zeroRate[18] = 0; zeroRate[19] = 0; zeroRate[20] &= 15
        var badMetadata = valid; badMetadata[43] = 0xff
        var badBlockType = valid; badBlockType[4] = 1
        var badBlockLength = valid; badBlockLength[7] = 33
        var badFrameCRC = valid; badFrameCRC[badFrameCRC.count - 1] ^= 1
        var zeroTotalMetadata = Data(valid.prefix(audioOffset))
        zeroTotalMetadata[21] &= 0xf0
        for i in 22...25 { zeroTotalMetadata[i] = 0 }
        return [Data(valid.prefix(41)), zeroRate,
                Data("OggS".utf8) + Data([0x7f]) + Data("FLAC".utf8),
                Data("ID3".utf8) + valid,
                Data(valid.prefix(audioOffset)), Data(valid.prefix(audioOffset + frameBytes)), Data(valid.prefix(audioOffset + frameBytes + 10)), badMetadata, badBlockType, badBlockLength, badFrameCRC, zeroTotalMetadata]
    }
}
#endif
