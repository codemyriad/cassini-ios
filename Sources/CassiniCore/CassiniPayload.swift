import CryptoKit
import CZlib
import Foundation

/** Strict payload boundary: single gzip member, declared lengths, checksums, UTF-8 and duplicate keys. */
public enum CassiniPayload {
    public static let mime = "application/vnd.cassini.portable-meeting+json"
    public static let wordMime = "application/vnd.cassini.transcript-words+json"
    public static let encoding = "base64url+gzip+utf8json"
    public static let maxRaw = 16 * 1024 * 1024

    static func sha(_ bytes: [UInt8]) -> String { OggOpus.hex(Array(SHA256.hash(data: bytes))) }

    static func base64url(_ bytes: [UInt8]) -> String {
        String(Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").filter { $0 != "=" })
    }

    public static func decode(_ chunks: [String], rawBytes: Int64, gzipBytes: Int64, sha256: String) throws -> String {
        try check((0...Int64(maxRaw)).contains(rawBytes) && (18...Int64(maxRaw)).contains(gzipBytes), "Payload size out of range")
        try check(fullMatch(sha256, "[0-9a-f]{64}"), "Invalid payload digest")
        let encoded = chunks.joined().filter { !" \t\r\n".contains($0) }
        try check(fullMatch(encoded, "[A-Za-z0-9_-]+={0,2}"), "Invalid base64url")
        let bare = encoded.filter { $0 != "=" }
        if bare.count != encoded.count { try check(encoded.count % 4 == 0, "Invalid base64url padding") }
        var standard = bare.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        try check(standard.count % 4 != 1, "Invalid base64url")
        standard += String(repeating: "=", count: (4 - standard.count % 4) % 4)
        guard let data = Data(base64Encoded: standard) else { throw CassiniError("Invalid base64url") }
        let compressed = [UInt8](data)
        try check(base64url(compressed) == bare, "Non-canonical base64url")
        try check(Int64(compressed.count) == gzipBytes, "Payload gzip size mismatch")
        let raw = try gunzip(compressed, limit: Int(rawBytes))
        try check(Int64(raw.count) == rawBytes && sha(raw) == sha256, "Payload digest mismatch")
        let text = try utf8(raw)
        _ = try JSON.parseObject(text)
        return text
    }

    public static func encode(prefix: String, mime: String, text: String) throws -> (ref: JSONObject, tags: [String]) {
        _ = try JSON.parseObject(text)
        let raw = Array(text.utf8)
        try check(raw.count <= maxRaw, "Payload too large")
        let compressed = try gzip(raw)
        let encoded = Array(base64url(compressed))
        let chunks = stride(from: 0, to: encoded.count, by: 4096).map { String(encoded[$0..<min($0 + 4096, encoded.count)]) }
        let digest = sha(raw)
        let ref = JSONObject([("prefix", .string(prefix)), ("mime", .string(mime)), ("encoding", .string(encoding)),
                              ("chunkCount", .int(chunks.count)), ("sha256", .string(digest)),
                              ("rawBytes", .int(raw.count)), ("gzipBytes", .int(compressed.count))])
        var tags = ["\(prefix)MIME=\(mime)", "\(prefix)ENCODING=\(encoding)", "\(prefix)CHUNK_COUNT=\(chunks.count)",
                    "\(prefix)SHA256=\(digest)", "\(prefix)RAW_BYTES=\(raw.count)", "\(prefix)GZIP_BYTES=\(compressed.count)"]
        for (i, chunk) in chunks.enumerated() { tags.append(prefix + String(format: "%03d", i) + "=" + chunk) }
        return (ref, tags)
    }

    static func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
        bytes.withUnsafeBufferPointer { UInt32(CZlib.crc32(0, $0.baseAddress, uInt($0.count))) }
    }

    static func gzip(_ raw: [UInt8]) throws -> [UInt8] {
        var stream = z_stream()
        try check(deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, 31, 8, Z_DEFAULT_STRATEGY,
                                zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK, "gzip unavailable")
        defer { deflateEnd(&stream) }
        var input = raw
        var out = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(raw.count))) + 32)
        let status: Int32 = input.withUnsafeMutableBufferPointer { inp in
            out.withUnsafeMutableBufferPointer { outp in
                stream.next_in = inp.baseAddress; stream.avail_in = uInt(inp.count)
                stream.next_out = outp.baseAddress; stream.avail_out = uInt(outp.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        try check(status == Z_STREAM_END, "gzip failed")
        return Array(out[0..<Int(stream.total_out)])
    }

    private static func gunzip(_ b: [UInt8], limit: Int) throws -> [UInt8] {
        try check(b.count >= 18 && b[0] == 31 && b[1] == 139 && b[2] == 8, "Not gzip")
        let flags = Int(b[3])
        try check(flags & 224 == 0, "Reserved gzip flags")
        var pos = 10
        if flags & 4 != 0 { try check(pos + 2 <= b.count, "Truncated gzip"); pos += 2 + OggOpus.u16(b, pos) }
        for flag in [8, 16] where flags & flag != 0 {
            while pos < b.count && b[pos] != 0 { pos += 1 }
            pos += 1
            try check(pos <= b.count, "Truncated gzip")
        }
        if flags & 2 != 0 {
            try check(pos + 2 <= b.count, "Truncated gzip")
            try check(Int(crc32(b[0..<pos]) & 65535) == OggOpus.u16(b, pos), "gzip header CRC mismatch")
            pos += 2
        }
        try check(pos <= b.count - 8, "Truncated gzip")
        var stream = z_stream()
        try check(inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK, "gzip unavailable")
        defer { inflateEnd(&stream) }
        var input = Array(b[pos...])
        var raw: [UInt8] = []
        raw.reserveCapacity(min(limit, 65536))
        var buffer = [UInt8](repeating: 0, count: 8192)
        var finished = false
        try input.withUnsafeMutableBufferPointer { inp in
            stream.next_in = inp.baseAddress; stream.avail_in = uInt(inp.count)
            while !finished {
                let (status, n): (Int32, Int) = buffer.withUnsafeMutableBufferPointer { outp in
                    stream.next_out = outp.baseAddress; stream.avail_out = uInt(outp.count)
                    let status = inflate(&stream, Z_NO_FLUSH)
                    return (status, outp.count - Int(stream.avail_out))
                }
                try check(status == Z_OK || status == Z_STREAM_END, "gzip data invalid")
                try check(raw.count + n <= limit, "Payload larger than declared")
                try check(n > 0 || status == Z_STREAM_END, "Truncated gzip")
                raw.append(contentsOf: buffer[0..<n])
                finished = status == Z_STREAM_END
            }
        }
        let trailer = b.count - Int(stream.avail_in)
        try check(trailer + 8 == b.count, "Trailing gzip data") // No concatenated members or ignored trailing bytes.
        try check(UInt32(bitPattern: OggOpus.u32(b, trailer)) == crc32(raw[...]), "gzip CRC mismatch")
        try check(UInt32(bitPattern: OggOpus.u32(b, trailer + 4)) == UInt32(truncatingIfNeeded: raw.count), "gzip size mismatch")
        return raw
    }
}
