import Foundation

/// Reads complete PCM frames from AVAudioRecorder's growing CAF without opening it for writing.
/// The consumer supplies its own cursor and performs reads away from the main actor.
public enum LiveCAFReader {
    public struct Block: Sendable {
        public let firstFrame: UInt64
        public let pcm16LE: Data
        public var frameCount: Int { pcm16LE.count / 2 }
    }

    /// nil means the header or next frame has yet to reach disk.
    public static func read(_ url: URL, fromFrame: UInt64, limit: Int = 4_800) throws -> Block? {
        guard (1...48_000).contains(limit) else { throw CocoaError(.fileReadInvalidFileName) }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let size = try file.seekToEnd()
        try file.seek(toOffset: 0)
        guard let header = try file.read(upToCount: 8), header.count == 8 else { return nil }
        guard header.prefix(4) == Data("caff".utf8) else { throw CocoaError(.fileReadCorruptFile) }

        var offset: UInt64 = 8
        var pcm = false
        while offset <= size && size - offset >= 12 {
            try file.seek(toOffset: offset)
            guard let chunk = try file.read(upToCount: 12), chunk.count == 12 else { return nil }
            let length = Int64(bitPattern: bigEndian(chunk.dropFirst(4)))
            let body = offset + 12
            switch String(decoding: chunk.prefix(4), as: UTF8.self) {
            case "desc":
                guard length >= 32, let description = try file.read(upToCount: 32),
                      description.count == 32 else { return nil }
                let rate = Double(bitPattern: bigEndian(description.prefix(8)))
                let flags = bigEndian(description[12..<16])
                pcm = rate == 48_000 && description[8..<12] == Data("lpcm".utf8)
                    && flags == 2 && bigEndian(description[16..<20]) == 2
                    && bigEndian(description[20..<24]) == 1
                    && bigEndian(description[24..<28]) == 1 && bigEndian(description[28..<32]) == 16
                guard pcm else { throw CocoaError(.fileReadUnsupportedScheme) }
            case "data":
                guard pcm else { throw CocoaError(.fileReadCorruptFile) }
                guard size - body >= 4, length == -1 || length >= 4 else { return nil }
                let available = size - body - 4
                let bytes = length == -1 ? available : min(available, UInt64(length - 4))
                let complete = bytes / 2
                guard fromFrame < complete else { return nil }
                let count = Int(min(UInt64(limit), complete - fromFrame))
                try file.seek(toOffset: body + 4 + fromFrame * 2)
                guard let read = try file.read(upToCount: count * 2), read.count >= 2 else { return nil }
                return Block(firstFrame: fromFrame, pcm16LE: Data(read.prefix(read.count / 2 * 2)))
            default: break
            }
            guard length >= 0, UInt64(length) <= size - body else { return nil }
            offset = body + UInt64(length)
        }
        return nil
    }

    private static func bigEndian(_ bytes: Data.SubSequence) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}
