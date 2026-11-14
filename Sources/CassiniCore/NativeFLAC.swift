import AVFoundation
import Foundation

/// Native FLAC admission and completeness checks. Memory stays bounded independently of recording length.
public enum NativeFLAC {
    public struct StreamInfo: Sendable {
        public let sampleRate: Int
        public let channels: Int
        public let totalSamples: Int64
    }

    public static func header(_ data: Data) throws -> StreamInfo {
        let h = Array(data)
        guard h.count >= 42, h.starts(with: Array("fLaC".utf8)), h[4] & 0x7f == 0,
              h[5] == 0, h[6] == 0, h[7] == 34 else { throw invalid() }
        let rate = Int(h[18]) << 12 | Int(h[19]) << 4 | Int(h[20] >> 4)
        let channels = Int((h[20] >> 1) & 7) + 1
        let bits = Int(h[20] & 1) << 4 | Int(h[21] >> 4)
        guard rate > 0, (1...8).contains(channels), (3...31).contains(bits) else { throw invalid() }
        var samples = Int64(h[21] & 15)
        for byte in h[22...25] { samples = samples << 8 | Int64(byte) }
        return StreamInfo(sampleRate: rate, channels: channels, totalSamples: samples)
    }

    /// Returns nil for another container; rejects any damaged native FLAC, including a zero-frame stream.
    @discardableResult public static func validateIfPresent(_ url: URL, checkCancellation: () throws -> Void = { try Task.checkCancellation() }) throws -> StreamInfo? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let probe = try handle.read(upToCount: 42) ?? Data()
        guard probe.starts(with: Data("fLaC".utf8)) else {
            if url.pathExtension.lowercased() == "flac" { throw invalid() }
            return nil
        }
        let info = try header(probe)
        let size = try handle.seekToEnd()
        var offset: UInt64 = 4
        while true {
            try checkCancellation()
            guard offset + 4 <= size else { throw invalid() }
            try handle.seek(toOffset: offset)
            let h = Array(try handle.read(upToCount: 4) ?? Data())
            guard h.count == 4, h[0] & 0x7f != 127 else { throw invalid() }
            let length = UInt64(h[1]) << 16 | UInt64(h[2]) << 8 | UInt64(h[3])
            offset += 4 + length
            guard offset <= size else { throw invalid() }
            if h[0] & 0x80 != 0 { break }
        }
        var end = size
        if size >= offset + 128 {
            try handle.seek(toOffset: size - 128)
            if try handle.read(upToCount: 3) == Data("TAG".utf8) { end -= 128 }
        }
        guard end > offset else { throw invalid() }
        try handle.seek(toOffset: offset)
        let frame = Array(try handle.read(upToCount: Int(min(32, end - offset))) ?? Data())
        guard validFrameHeader(frame) else { throw invalid() }
        // Each complete frame has zero CRC-16 residue (including its footer). Concatenating complete
        // frames preserves that residue. Exclude the optional ID3v1 trailer, never an ID3v2 prefix.
        try handle.seek(toOffset: offset)
        var crc: UInt16 = 0
        while offset < end {
            try checkCancellation()
            let chunk = try handle.read(upToCount: Int(min(65536, end - offset))) ?? Data()
            guard !chunk.isEmpty else { throw invalid() }
            for byte in chunk {
                crc = (crc &<< 8) ^ crc16Table[Int((crc >> 8) ^ UInt16(byte))]
            }
            offset += UInt64(chunk.count)
        }
        guard crc == 0 else { throw invalid() }
        // Apple's length is taken from STREAMINFO even for incomplete files. Count actual decoded frames.
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == Double(info.sampleRate),
              file.processingFormat.channelCount == info.channels,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { throw invalid() }
        var decoded: Int64 = 0
        while decoded < file.length {
            try checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, file.length - decoded)))
            if buffer.frameLength == 0 { break }
            decoded += Int64(buffer.frameLength)
        }
        guard decoded > 0, info.totalSamples == 0 || decoded == info.totalSamples else { throw invalid() }
        return info
    }

    /// RFC 9639 frame header, including the variable UTF-8 number, optional block/rate fields and CRC-8.
    static func validFrameHeader(_ h: [UInt8]) -> Bool {
        guard h.count >= 6, h[0] == 0xff, h[1] & 0xfe == 0xf8,
              h[2] >> 4 != 0, h[2] & 15 != 15, h[3] & 1 == 0,
              h[3] >> 4 <= 10, (h[3] >> 1) & 7 != 3 else { return false }
        var index = 4
        let first = h[index]
        let count: Int
        if first < 0x80 { count = 1 }
        else {
            count = first.leadingZeroBitCount == 0 ? (~first).leadingZeroBitCount : 0
            guard (2...7).contains(count) else { return false }
        }
        guard index + count <= h.count else { return false }
        if count > 1 {
            for byte in h[(index + 1)..<(index + count)] where byte & 0xc0 != 0x80 { return false }
        }
        index += count
        if h[2] >> 4 == 6 { index += 1 }
        if h[2] >> 4 == 7 { index += 2 }
        if h[2] & 15 == 12 { index += 1 }
        if [13, 14].contains(h[2] & 15) { index += 2 }
        guard index < h.count else { return false }
        var crc: UInt8 = 0
        for byte in h[0..<index] {
            crc ^= byte
            for _ in 0..<8 { crc = crc & 0x80 != 0 ? (crc &<< 1) ^ 7 : crc &<< 1 }
        }
        return crc == h[index]
    }

    private static let crc16Table: [UInt16] = (0..<256).map { value in
        var crc = UInt16(value) << 8
        for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x8005 : crc &<< 1 }
        return crc
    }

    private static func invalid() -> Error { CassiniError("Incomplete or invalid native FLAC audio") }
}
