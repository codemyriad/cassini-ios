import CryptoKit
import Foundation

/** Where packets and pages come from: returns 0 only at the end of input. */
public protocol ByteSource: AnyObject {
    func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) throws -> Int
}

public protocol ByteSink: AnyObject {
    func write(_ bytes: [UInt8]) throws
}

public final class ArraySource: ByteSource {
    private let bytes: [UInt8]
    private var position = 0
    public init(_ bytes: [UInt8]) { self.bytes = bytes }
    public func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) throws -> Int {
        let n = min(count, bytes.count - position)
        bytes.withUnsafeBufferPointer { buffer.assign(from: $0.baseAddress! + position, count: n) }
        position += n
        return n
    }
}

public final class FileSource: ByteSource {
    private let stream: InputStream
    public init(_ url: URL) throws {
        guard let stream = InputStream(url: url) else { throw CassiniError("Cannot open \(url.path)") }
        stream.open()
        if let error = stream.streamError { throw error }
        self.stream = stream
    }
    deinit { stream.close() }
    public func read(into buffer: UnsafeMutablePointer<UInt8>, count: Int) throws -> Int {
        let n = stream.read(buffer, maxLength: count)
        if n < 0 { throw stream.streamError ?? CassiniError("Read failed") }
        return n
    }
}

public final class ArraySink: ByteSink {
    public private(set) var bytes: [UInt8] = []
    public init() {}
    public func write(_ bytes: [UInt8]) { self.bytes += bytes }
}

/** Buffered file output; [close] flushes and syncs so a returned document is on disk. */
public final class FileSink: ByteSink {
    private let handle: FileHandle
    private var buffer: [UInt8] = []
    public init(_ url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CassiniError("Cannot create \(url.path)") }
        handle = try FileHandle(forWritingTo: url)
    }
    public func write(_ bytes: [UInt8]) throws {
        buffer += bytes
        if buffer.count >= 1 << 16 { try flush() }
    }
    public func flush() throws { if !buffer.isEmpty { handle.write(Data(buffer)); buffer.removeAll(keepingCapacity: true) } }
    public func close() throws { try flush(); try handle.synchronize(); try handle.close() }
}

/** Streaming Ogg packet reader/muxer with bounded packets. Metadata and page layout never enter the audio digest. */
public enum OggOpus {
    /** The first page holds only OpusHead: a 27-byte page header, one lacing value, then the magic. */
    public static let headBytes = 36
    public static let maxHeaderBytes = 8 * 1024 * 1024

    public static func looksLikeOpus(_ head: [UInt8]) -> Bool {
        head.count >= headBytes && startsWith(head, "OggS") && head[26] == 1 && startsWith(Array(head[28...]), "OpusHead")
    }

    public struct Stream {
        public let head: [UInt8], tags: [UInt8], audio: [[UInt8]]
        public let finalGranule: Int64, validFraming: Bool
        public init(head: [UInt8], tags: [UInt8], audio: [[UInt8]], finalGranule: Int64, validFraming: Bool) {
            self.head = head; self.tags = tags; self.audio = audio; self.finalGranule = finalGranule; self.validFraming = validFraming
        }
        public var channels: Int { Int(head[9]) }
        public var preSkip: Int { u16(head, 10) }
        public var sampleCount: Int64 { min(audio.reduce(Int64(0)) { $0 + Int64((try? packetSamples($1)) ?? 0) }, finalGranule) - Int64(preSkip) }
        public var durationMs: Int64 { sampleCount * 1000 / 48000 }
        public func digest() throws -> String {
            try check(validFraming, "Opus audio cannot be verified")
            let hasher = try Hasher(head)
            for packet in audio { try hasher.add(packet) }
            return try hasher.finish(finalGranule)
        }
    }

    /** What a streaming pass learns: headers, shape, and the audio digest when framing and packets are sound. */
    public struct Info {
        public let head: [UInt8], tags: [UInt8], finalGranule: Int64, validFraming: Bool, sampleCount: Int64
        let audioDigest: String?
        public var channels: Int { Int(head[9]) }
        public var durationMs: Int64 { sampleCount * 1000 / 48000 }
        public func digest() throws -> String {
            guard let d = audioDigest else { throw CassiniError("Opus audio cannot be verified") }
            return d
        }
    }

    final class Hasher {
        private var hash = SHA256()
        private let preSkip: Int
        private var count: Int64 = 0
        private(set) var samples: Int64 = 0
        init(_ head: [UInt8]) throws {
            try check(head.count >= 19 && (1...15).contains(head[8]) && (1...2).contains(head[9]), "Invalid OpusHead")
            preSkip = u16(head, 10)
            hash.update(data: Array("org.cassini.opus-packets/1\u{0}".utf8))
            var zeroed = head
            for i in 12...15 { zeroed[i] = 0 }
            packet(UInt8(ascii: "H"), zeroed)
        }
        private func packet(_ marker: UInt8, _ bytes: [UInt8]) {
            hash.update(data: [marker]); hash.update(data: le64(Int64(bytes.count))); hash.update(data: bytes)
        }
        func add(_ bytes: [UInt8]) throws { samples += Int64(try packetSamples(bytes)); packet(UInt8(ascii: "A"), bytes); count += 1 }
        func sampleCount(_ finalGranule: Int64) -> Int64 { min(samples, finalGranule) - Int64(preSkip) }
        func finish(_ finalGranule: Int64) throws -> String {
            let sampleCount = self.sampleCount(finalGranule)
            try check(finalGranule >= Int64(preSkip) && sampleCount >= 0, "Invalid final granule")
            hash.update(data: [UInt8(ascii: "E")]); hash.update(data: le64(count)); hash.update(data: le64(sampleCount))
            return hex(Array(hash.finalize()))
        }
    }

    /** Reads one page at a time. Truncation or a broken page structure throws; framing and CRC faults clear [valid]. */
    public final class Reader {
        public private(set) var valid = true
        public private(set) var eos = false
        public private(set) var finalGranule: Int64 = -1
        public var complete: Bool { valid && eos && partial.isEmpty }
        private let input: ByteSource
        private var serial: UInt32?
        private var seq: UInt32 = 0
        private var packets = 0
        private var partial: [UInt8] = []
        private var ready: [[UInt8]] = []
        private var readyHead = 0
        private var header = [UInt8](repeating: 0, count: 27 + 255)

        public init(_ input: ByteSource) { self.input = input }

        private func fill(_ buffer: inout [UInt8], _ offset: Int, _ length: Int) throws -> Int {
            var got = 0
            try buffer.withUnsafeMutableBufferPointer { b in
                while got < length {
                    let n = try input.read(into: b.baseAddress! + offset + got, count: length - got)
                    if n <= 0 { break }
                    got += n
                }
            }
            return got
        }

        /** The next whole page, or nil at a clean end of input. */
        @discardableResult public func page() throws -> [UInt8]? {
            let got = try fill(&header, 0, 27)
            if got == 0 { return nil }
            try check(got == 27 && startsWith(header, "OggS"), "Truncated Ogg page")
            let count = Int(header[26])
            try check(try fill(&header, 27, count) == count, "Truncated Ogg page")
            var size = 0
            for i in 0..<count { size += Int(header[27 + i]) }
            var page = Array(header[0..<(27 + count)]) + [UInt8](repeating: 0, count: size)
            try check(try fill(&page, 27 + count, size) == size, "Truncated Ogg page")
            let flags = Int(page[5])
            let pageSerial = UInt32(bitPattern: u32(page, 14))
            let pageSeq = UInt32(bitPattern: u32(page, 18))
            if serial == nil { serial = pageSerial; if flags & 2 == 0 || pageSeq != 0 { valid = false } }
            if pageSerial != serial || pageSeq != seq || eos || page[4] != 0 { valid = false }
            seq &+= 1
            if (flags & 1 != 0) != !partial.isEmpty { valid = false }
            let expectedCrc = u32(page, 22)
            for i in 22...25 { page[i] = 0 }
            if crc(page) != expectedCrc { valid = false }
            put32(&page, 22, expectedCrc)
            var cursor = 27 + count
            for i in 0..<count {
                let length = Int(page[27 + i])
                try check(partial.count + length <= (packets < 2 ? maxHeaderBytes : 65536), "Ogg packet too large")
                partial += page[cursor..<(cursor + length)]; cursor += length
                if length < 255 {
                    ready.append(partial); partial = []; packets += 1
                    // OpusHead is alone on the BOS page; audio starts after the tags page.
                    if (packets == 1 || packets == 2) && i != count - 1 { valid = false }
                }
            }
            if flags & 4 != 0 { eos = true; finalGranule = i64(page, 6) }
            return page
        }

        /** The next whole packet, or nil once the input ends. */
        public func packet() throws -> [UInt8]? {
            while readyHead == ready.count {
                ready.removeAll(keepingCapacity: true); readyHead = 0
                if try page() == nil { return nil }
            }
            defer { readyHead += 1 }
            return ready[readyHead]
        }

        public func headers() throws -> (head: [UInt8], tags: [UInt8]) {
            guard let head = try packet(), let tags = try packet(), startsWith(head, "OpusHead"), startsWith(tags, "OpusTags") else {
                throw CassiniError("Not an Ogg Opus stream")
            }
            return (head, tags)
        }
    }

    public static func read(_ bytes: [UInt8], headersOnly: Bool = false) throws -> Stream {
        let reader = Reader(ArraySource(bytes))
        let (head, tags) = try reader.headers()
        if headersOnly { return Stream(head: head, tags: tags, audio: [], finalGranule: -1, validFraming: false) }
        var audio: [[UInt8]] = []
        while let packet = try reader.packet() { audio.append(packet) }
        return Stream(head: head, tags: tags, audio: audio, finalGranule: reader.finalGranule, validFraming: reader.complete)
    }

    public static func headers(_ input: ByteSource) throws -> (head: [UInt8], tags: [UInt8]) { try Reader(input).headers() }

    /** One pass over a whole stream, holding a single packet at a time. */
    public static func scan(_ input: ByteSource) throws -> Info {
        let reader = Reader(input)
        let (head, tags) = try reader.headers()
        let hasher = try? Hasher(head)
        var usable = hasher != nil
        while let packet = try reader.packet() {
            if usable { do { try hasher!.add(packet) } catch { usable = false } }
        }
        let digest = usable && reader.complete ? try? hasher!.finish(reader.finalGranule) : nil
        return Info(head: head, tags: tags, finalGranule: reader.finalGranule, validFraming: reader.complete,
                    sampleCount: hasher?.sampleCount(reader.finalGranule) ?? 0, audioDigest: digest)
    }

    public static func scan(_ url: URL) throws -> Info { try scan(FileSource(url)) }

    /** Lays out one packet per page group, exactly as every Cassini writer does, so equal packets give equal bytes. */
    final class Writer {
        private let out: ByteSink
        private let serial: Int32
        private var seq: Int32 = 0
        init(_ out: ByteSink, _ serial: Int32) { self.out = out; self.serial = serial }
        func packet(_ bytes: [UInt8], flags: Int, granule: Int64) throws {
            var laces = [Int](repeating: 255, count: bytes.count / 255)
            laces.append(bytes.count % 255)
            var offset = 0
            for (index, start) in stride(from: 0, to: laces.count, by: 255).enumerated() {
                let group = laces[start..<min(start + 255, laces.count)]
                let size = group.reduce(0, +)
                var page = [UInt8](repeating: 0, count: 27 + group.count + size)
                page.replaceSubrange(0..<4, with: Array("OggS".utf8))
                let last = offset + size == bytes.count && group.last! < 255
                page[5] = UInt8((index > 0 ? 1 : flags & 2) | (last ? flags & 4 : 0))
                page.replaceSubrange(6..<14, with: le64(last ? granule : -1))
                put32(&page, 14, serial); put32(&page, 18, seq); seq &+= 1
                page[26] = UInt8(group.count)
                for (i, n) in group.enumerated() { page[27 + i] = UInt8(n) }
                page.replaceSubrange((27 + group.count)..<page.count, with: bytes[offset..<(offset + size)])
                put32(&page, 22, crc(page))
                try out.write(page)
                offset += size
            }
        }
    }

    public static func randomSerial() -> Int32 { Int32.random(in: .min ... .max) }

    /**
     * [mux] as packets arrive: holds one packet back so the last one carries EOS. Packets past [finalGranule]
     * (encoder flush) are dropped; [finish] fails unless the packets cover it.
     */
    public final class Muxer {
        private let writer: Writer
        private let finalGranule: Int64
        private var pending: [UInt8]?
        private var granule: Int64 = 0
        public init(_ out: ByteSink, head: [UInt8], tags: [UInt8], finalGranule: Int64, serial: Int32 = randomSerial()) throws {
            try check(tags.count <= maxHeaderBytes && finalGranule > 0, "Invalid Opus headers")
            writer = Writer(out, serial); self.finalGranule = finalGranule
            try writer.packet(head, flags: 2, granule: 0); try writer.packet(tags, flags: 0, granule: 0)
        }
        public var full: Bool { granule >= finalGranule }
        public func add(_ packet: [UInt8]) throws {
            if full { return }
            if let p = pending { try writer.packet(p, flags: 0, granule: granule) }
            pending = packet; granule += Int64(try packetSamples(packet))
        }
        public func finish() throws {
            try check(full, "Opus packets do not cover the final granule")
            try writer.packet(pending!, flags: 4, granule: finalGranule); pending = nil
        }
    }

    /**
     * Live capture: the final length is unknown until [finish]. Every page written so far is a valid prefix, so a
     * file cut short after a flush still decodes up to its last whole page.
     */
    public final class LiveMuxer {
        private let writer: Writer
        private var pending: [UInt8]?
        public private(set) var granule: Int64 = 0
        public let preSkip: Int
        public init(_ out: ByteSink, head: [UInt8], tags: [UInt8], serial: Int32 = randomSerial()) throws {
            try check(tags.count <= maxHeaderBytes, "OpusTags too large")
            writer = Writer(out, serial); preSkip = u16(head, 10)
            try writer.packet(head, flags: 2, granule: 0); try writer.packet(tags, flags: 0, granule: 0)
        }
        public var empty: Bool { pending == nil }
        public func add(_ packet: [UInt8]) throws {
            let samples = try packetSamples(packet)
            if let p = pending { try writer.packet(p, flags: 0, granule: granule) }
            pending = packet; granule += Int64(samples)
        }
        /** Ends the stream at [finalGranule], clamped to what the packets cover; nil keeps every sample. */
        public func finish(finalGranule: Int64? = nil) throws {
            guard let last = pending else { throw CassiniError("No Opus audio packets") }
            let low = min(Int64(preSkip), granule)
            try writer.packet(last, flags: 4, granule: max(low, min(granule, finalGranule ?? granule))); pending = nil
        }
    }

    public static func mux(_ stream: Stream, tags: [UInt8], serial: Int32 = randomSerial()) throws -> [UInt8] {
        try check(stream.validFraming && tags.count <= maxHeaderBytes && !stream.audio.isEmpty, "Cannot mux this stream")
        let out = ArraySink()
        let writer = Writer(out, serial)
        try writer.packet(stream.head, flags: 2, granule: 0); try writer.packet(tags, flags: 0, granule: 0)
        var granule: Int64 = 0
        for (i, bytes) in stream.audio.enumerated() {
            granule += Int64(try packetSamples(bytes))
            let last = i == stream.audio.count - 1
            try writer.packet(bytes, flags: last ? 4 : 0, granule: last ? stream.finalGranule : granule)
        }
        return out.bytes
    }

    /**
     * [mux] without holding the audio: copies [input]'s packets behind new [tags], renumbering pages and
     * recomputing CRCs. Returns what it read, digest included; a damaged source throws after partial output.
     */
    @discardableResult
    public static func rewrite(_ input: ByteSource, tags: [UInt8], to out: ByteSink, serial: Int32 = randomSerial()) throws -> Info {
        try check(tags.count <= maxHeaderBytes, "OpusTags too large")
        let reader = Reader(input)
        let (head, oldTags) = try reader.headers()
        let hasher = try Hasher(head)
        let writer = Writer(out, serial)
        try writer.packet(head, flags: 2, granule: 0); try writer.packet(tags, flags: 0, granule: 0)
        guard var previous = try reader.packet() else { throw CassiniError("No Opus audio packets") }
        var granule: Int64 = 0
        while true {
            try hasher.add(previous); granule += Int64(try packetSamples(previous))
            guard let next = try reader.packet() else {
                try check(reader.complete, "Damaged Ogg stream")
                try writer.packet(previous, flags: 4, granule: reader.finalGranule)
                break
            }
            try writer.packet(previous, flags: 0, granule: granule)
            previous = next
        }
        return Info(head: head, tags: oldTags, finalGranule: reader.finalGranule, validFraming: true,
                    sampleCount: hasher.sampleCount(reader.finalGranule), audioDigest: try hasher.finish(reader.finalGranule))
    }

    @discardableResult
    public static func rewrite(_ source: URL, tags: [UInt8], to target: URL, serial: Int32 = randomSerial()) throws -> Info {
        let sink = try FileSink(target)
        let info = try rewrite(FileSource(source), tags: tags, to: sink, serial: serial)
        try sink.close()
        return info
    }

    public static func packetSamples(_ packet: [UInt8]) throws -> Int {
        try check(!packet.isEmpty, "Empty Opus packet")
        let toc = Int(packet[0])
        let code = (toc >> 3) & 3
        let perFrame: Int
        if toc & 128 != 0 { perFrame = (48000 << code) / 400 }
        else if toc & 96 == 96 { perFrame = toc & 8 != 0 ? 960 : 480 }
        else if code == 3 { perFrame = 2880 }
        else { perFrame = (48000 << code) / 100 }
        let frames: Int
        switch toc & 3 {
        case 0: frames = 1
        case 1, 2: frames = 2
        default: try check(packet.count >= 2, "Truncated Opus packet"); frames = Int(packet[1]) & 63
        }
        try check(frames > 0 && frames * perFrame <= 5760, "Invalid Opus packet")
        return frames * perFrame
    }

    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var value = UInt32(index) << 24
        for _ in 0..<8 { value = (value << 1) ^ (value & 0x8000_0000 != 0 ? 0x04c1_1db7 : 0) }
        return value
    }
    public static func crc(_ bytes: [UInt8]) -> Int32 {
        var c: UInt32 = 0
        for b in bytes { c = (c << 8) ^ table[Int(((c >> 24) ^ UInt32(b)) & 255)] }
        return Int32(bitPattern: c)
    }
    public static func u16(_ b: [UInt8], _ p: Int) -> Int { Int(b[p]) | Int(b[p + 1]) << 8 }
    public static func u32(_ b: [UInt8], _ p: Int) -> Int32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(b[p + i]) << (8 * UInt32(i)) }
        return Int32(bitPattern: v)
    }
    public static func i64(_ b: [UInt8], _ p: Int) -> Int64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(b[p + i]) << (8 * UInt64(i)) }
        return Int64(bitPattern: v)
    }
    public static func put32(_ b: inout [UInt8], _ p: Int, _ v: Int32) {
        let u = UInt32(bitPattern: v)
        for i in 0..<4 { b[p + i] = UInt8(truncatingIfNeeded: u >> (8 * UInt32(i))) }
    }
    public static func le64(_ v: Int64) -> [UInt8] {
        let u = UInt64(bitPattern: v)
        return (0..<8).map { UInt8(truncatingIfNeeded: u >> (8 * UInt64($0))) }
    }
    public static func hex(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }
    static func startsWith(_ b: [UInt8], _ value: String) -> Bool {
        let v = Array(value.utf8)
        return b.count >= v.count && Array(b[0..<v.count]) == v
    }
}
