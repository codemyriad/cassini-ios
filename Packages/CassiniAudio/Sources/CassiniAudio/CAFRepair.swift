import Foundation

/// Repairs a CAF capture that was not closed: Core Audio writes the size of the `data` chunk when the file is closed,
/// so a capture cut short by a crash or a kill says it holds more (or an unknown amount of) audio than it does. The
/// repair sets the size to the whole frames on disk and cuts a trailing partial frame. Nothing else in the file
/// changes, and a file that is already consistent is left byte for byte as it is.
public enum CAFRepair {
    public enum Outcome: Hashable, Sendable {
        /// The file is not a CAF file; nothing was changed.
        case notCAF
        /// The `data` chunk size already matches the audio on disk.
        case clean
        /// The `data` chunk size was set to the audio on disk.
        case repaired
        /// A CAF file this repair cannot handle (no `data` chunk, or packets of varying size); nothing was changed.
        case unsupported
    }

    private static let fileHeaderSize: UInt64 = 8
    private static let chunkHeaderSize: UInt64 = 12
    /// `mEditCount`, at the start of the `data` chunk.
    private static let editCountSize: UInt64 = 4

    public static func repair(_ url: URL) throws -> Outcome {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        try handle.seek(toOffset: 0)
        guard fileSize >= fileHeaderSize, let header = try handle.read(upToCount: Int(fileHeaderSize)),
              header.prefix(4) == Data("caff".utf8) else { return .notCAF }

        var offset = fileHeaderSize
        var bytesPerPacket: UInt32?
        while offset + chunkHeaderSize <= fileSize {
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: Int(chunkHeaderSize)), chunk.count == Int(chunkHeaderSize) else { break }
            let type = String(decoding: chunk.prefix(4), as: UTF8.self)
            let size = Int64(bitPattern: chunk.bigEndianUInt64(at: 4))
            let bodyStart = offset + chunkHeaderSize
            if type == "desc", size >= 32, let desc = try handle.read(upToCount: 32), desc.count == 32 {
                bytesPerPacket = desc.bigEndianUInt32(at: 16)
            }
            if type == "data" {
                guard let bytesPerPacket, bytesPerPacket > 0, fileSize >= bodyStart + editCountSize else { return .unsupported }
                let available = fileSize - bodyStart - editCountSize
                let whole = available / UInt64(bytesPerPacket) * UInt64(bytesPerPacket)
                // A size that fits on disk and holds whole packets is the closed file's own; other chunks may follow it.
                if size >= Int64(editCountSize), UInt64(size) - editCountSize <= available,
                   (UInt64(size) - editCountSize) % UInt64(bytesPerPacket) == 0 { return .clean }
                try handle.seek(toOffset: offset + 4)
                try handle.write(contentsOf: Data(bigEndian: whole + editCountSize))
                if whole < available { try handle.truncate(atOffset: bodyStart + editCountSize + whole) }
                try handle.synchronize()
                return .repaired
            }
            // Only the `data` chunk may have an unknown size (-1), and it is the last one.
            guard size >= 0 else { return .unsupported }
            offset = bodyStart + UInt64(size)
        }
        return .unsupported
    }
}

private extension Data {
    func bigEndianUInt64(at index: Int) -> UInt64 {
        self[startIndex + index ..< startIndex + index + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }

    func bigEndianUInt32(at index: Int) -> UInt32 {
        self[startIndex + index ..< startIndex + index + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    init(bigEndian value: UInt64) {
        self = Swift.withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
