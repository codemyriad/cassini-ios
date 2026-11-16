import AVFoundation
import Foundation

/// Native FLAC admission and completeness checks. Memory stays bounded independently of recording length.
public enum NativeFLAC {
    public struct StreamInfo: Sendable {
        public let sampleRate: Int
        public let channels: Int
        public let totalSamples: Int64
    }

    private struct Identity: Hashable {
        let path: String
        let inode: UInt64
        let size: UInt64
        let modified: Date

        init(_ url: URL) throws {
            path = url.standardizedFileURL.path
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            guard let inode = attributes[.systemFileNumber] as? NSNumber,
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date else { throw invalid() }
            self.inode = inode.uint64Value
            self.size = size.uint64Value
            self.modified = modified
        }
    }

    // Bounded FIFO: no file handles or audio buffers are retained. Never hold the lock across IO or callbacks.
    private final class ValidationCache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [Identity] = []
        func contains(_ identity: Identity) -> Bool { lock.withLock { entries.contains(identity) } }
        func insert(_ identity: Identity) {
            lock.withLock {
                entries.removeAll { $0.path == identity.path }
                if entries.count >= 128 { entries.removeFirst() }
                entries.append(identity)
            }
        }
        #if DEBUG
        var observers: [String: @Sendable (ValidationEvent) -> Void] = [:]
        #endif
    }
    private static let cache = ValidationCache()

    /// Rename an admitted staging file without losing its validation. Only the path may change.
    public static func moveValidatedFile(from source: URL, to destination: URL) throws {
        let before = try Identity(source)
        let validated = cache.contains(before)
        try FileManager.default.moveItem(at: source, to: destination)
        let after = try Identity(destination)
        if validated, before.inode == after.inode, before.size == after.size, before.modified == after.modified {
            cache.insert(after)
        }
    }

    #if DEBUG
    public enum ValidationEvent: Sendable { case checkingFrames, decoding, complete }
    /// Per-file observation keeps parallel tests independent. Callbacks run outside the cache lock.
    public static func observeValidation(at url: URL, _ observer: (@Sendable (ValidationEvent) -> Void)?) {
        cache.lock.withLock { cache.observers[url.standardizedFileURL.path] = observer }
    }
    private static func observe(_ event: ValidationEvent, at url: URL) {
        let observer = cache.lock.withLock { cache.observers[url.standardizedFileURL.path] }
        observer?(event)
    }
    #endif

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
        try checkCancellation()
        let identity = try Identity(url)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let probe = try handle.read(upToCount: 42) ?? Data()
        guard probe.starts(with: Data("fLaC".utf8)) else {
            if url.pathExtension.lowercased() == "flac" { throw invalid() }
            return nil
        }
        let info = try header(probe)
        guard try Identity(url) == identity else { throw invalid() }
        if cache.contains(identity) { return info }
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
        #if DEBUG
        observe(.checkingFrames, at: url)
        #endif
        let framedSamples = try validateFrames(handle, start: offset, end: end, info: info,
                                              bitsPerSample: (Int(probe[20] & 1) << 4 | Int(probe[21] >> 4)) + 1,
                                              checkCancellation: checkCancellation)
        // Apple's length is taken from STREAMINFO even for incomplete files. Count actual decoded frames.
        let file = try AVAudioFile(forReading: url)
        guard file.processingFormat.sampleRate == Double(info.sampleRate),
              file.processingFormat.channelCount == info.channels,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192) else { throw invalid() }
        #if DEBUG
        observe(.decoding, at: url)
        #endif
        var decoded: Int64 = 0
        while info.totalSamples == 0 || decoded < file.length {
            try checkCancellation()
            buffer.frameLength = 0
            do {
                try file.read(into: buffer, frameCount: info.totalSamples == 0 ? 8192 : AVAudioFrameCount(min(8192, file.length - decoded)))
            } catch {
                // With an unknown STREAMINFO length Apple may report EOF as eofErr (or return
                // false without NSError). Accept that zero-frame read only after every checksummed
                // frame's samples have actually decoded; an early error still rejects the stream.
                guard info.totalSamples == 0, buffer.frameLength == 0, decoded > 0,
                      decoded == framedSamples else { throw error }
                break
            }
            if buffer.frameLength == 0 { break }
            decoded += Int64(buffer.frameLength)
        }
        guard decoded > 0, decoded == framedSamples,
              info.totalSamples == 0 || decoded == info.totalSamples else { throw invalid() }
        try checkCancellation()
        // Do not cache a file replaced or edited while validation was running.
        guard try Identity(url) == identity else { throw invalid() }
        cache.insert(identity)
        #if DEBUG
        observe(.complete, at: url)
        #endif
        return info
    }

    /// Walk the RFC 9639 subframe grammar to find exact frame boundaries. Searching for sync bytes
    /// or checking a concatenated CRC can miss damaged headers/footers (Apple can skip those frames).
    /// Only a 64 KiB input window is retained; no PCM or residual values need to be reconstructed here.
    private static func validateFrames(_ handle: FileHandle, start: UInt64, end: UInt64, info: StreamInfo,
                                       bitsPerSample: Int, checkCancellation: () throws -> Void) throws -> Int64 {
        var window: [UInt8] = [], index = 0
        var position = start
        var crc: UInt16 = 0
        var current = 0, remaining = 0
        func byte() throws -> UInt8 {
            guard position < end else { throw invalid() }
            if index == window.count {
                try checkCancellation()
                window = Array(try handle.read(upToCount: Int(min(65536, end - position))) ?? Data())
                index = 0
                guard !window.isEmpty else { throw invalid() }
            }
            let value = window[index]
            index += 1; position += 1
            crc = (crc &<< 8) ^ crc16Table[Int((crc >> 8) ^ UInt16(value))]
            return value
        }
        func bits(_ count: Int) throws -> Int {
            var value = 0, needed = count
            while needed > 0 {
                if remaining == 0 { current = Int(try byte()); remaining = 8 }
                let take = min(remaining, needed)
                remaining -= take; needed -= take
                value = value << take | (current >> remaining & ((1 << take) - 1))
            }
            return value
        }
        func skip(_ count: Int) throws {
            var left = count
            while left > 0 { let take = min(left, 8); _ = try bits(take); left -= take }
        }
        func residual(block: Int, order: Int) throws {
            let method = try bits(2)
            guard method <= 1 else { throw invalid() }
            let width = method + 4
            let partitions = 1 << (try bits(4))
            guard block % partitions == 0, block / partitions > order else { throw invalid() }
            for partition in 0..<partitions {
                let count = block / partitions - (partition == 0 ? order : 0)
                let parameter = try bits(width)
                if parameter == (1 << width) - 1 {
                    try skip(count * bits(5))
                } else {
                    for _ in 0..<count {
                        while try bits(1) == 0 {} // unary quotient, bounded by the file and cancellation windows
                        try skip(parameter)
                    }
                }
            }
        }
        var samples: Int64 = 0
        while position < end {
            try checkCancellation()
            crc = 0
            var h: [UInt8] = []
            for _ in 0..<5 { h.append(try byte()) }
            let numberBytes = h[4] < 0x80 ? 1 : (~h[4]).leadingZeroBitCount
            guard (1...7).contains(numberBytes) else { throw invalid() }
            for _ in 1..<numberBytes { h.append(try byte()) }
            let blockCode = h[2] >> 4, rateCode = h[2] & 15
            if blockCode == 6 { h.append(try byte()) }
            if blockCode == 7 { h.append(try byte()); h.append(try byte()) }
            if rateCode == 12 { h.append(try byte()) }
            if rateCode == 13 || rateCode == 14 { h.append(try byte()); h.append(try byte()) }
            h.append(try byte())
            guard validFrameHeader(h) else { throw invalid() }
            let block = blockSamples(h)
            let assignment = Int(h[3] >> 4)
            let channels = assignment < 8 ? assignment + 1 : 2
            guard channels == info.channels else { throw invalid() }
            let sampleCode = Int(h[3] >> 1 & 7)
            let depth = [bitsPerSample, 8, 12, 0, 16, 20, 24, 32][sampleCode]
            for channel in 0..<channels {
                var width = depth
                if (assignment == 8 || assignment == 10) && channel == 1 || assignment == 9 && channel == 0 {
                    width += 1
                }
                guard try bits(1) == 0 else { throw invalid() }
                let type = try bits(6)
                if try bits(1) == 1 {
                    var wasted = 1
                    while try bits(1) == 0 {
                        wasted += 1
                        guard wasted < width else { throw invalid() }
                    }
                    width -= wasted
                }
                guard width > 0 else { throw invalid() }
                switch type {
                case 0: try skip(width)
                case 1: try skip(block * width)
                case 8...12:
                    let order = type - 8
                    guard order <= block else { throw invalid() }
                    try skip(order * width)
                    try residual(block: block, order: order)
                case 32...63:
                    let order = type - 31
                    guard order <= block else { throw invalid() }
                    try skip(order * width)
                    let precision = try bits(4) + 1
                    guard precision <= 15, try bits(5) < 16 else { throw invalid() }
                    try skip(order * precision)
                    try residual(block: block, order: order)
                default: throw invalid()
                }
            }
            if remaining > 0 { guard try bits(remaining) == 0 else { throw invalid() } }
            _ = try byte(); _ = try byte()
            guard crc == 0 else { throw invalid() }
            samples += Int64(block)
        }
        guard samples > 0 else { throw invalid() }
        return samples
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

    /// Called only after the entire variable-length header passed its CRC-8 check.
    private static func blockSamples(_ h: [UInt8]) -> Int {
        let code = Int(h[2] >> 4)
        switch code {
        case 1: return 192
        case 2...5: return 576 << (code - 2)
        case 6, 7:
            let numberBytes = h[4] < 0x80 ? 1 : (~h[4]).leadingZeroBitCount
            let index = 4 + numberBytes
            return code == 6 ? Int(h[index]) + 1 : (Int(h[index]) << 8 | Int(h[index + 1])) + 1
        default: return 256 << (code - 8)
        }
    }

    private static let crc16Table: [UInt16] = (0..<256).map { value in
        var crc = UInt16(value) << 8
        for _ in 0..<8 { crc = crc & 0x8000 != 0 ? (crc &<< 1) ^ 0x8005 : crc &<< 1 }
        return crc
    }

    private static func invalid() -> Error { CassiniError("Incomplete or invalid native FLAC audio") }
}
