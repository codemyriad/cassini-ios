import Foundation
import Darwin
import CoreFoundation
import CZlib

public enum ZipArchiveError: Error, Sendable, Equatable {
    case damaged, encrypted, unsafePaths, tooLarge, empty
}

public struct ZipEntry: Hashable, Sendable {
    public let name: String
    public var baseName: String { name.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init) ?? name }
    public let uncompressedSize: Int64
    public let compressedSize: Int64
    public let isDirectory: Bool
    fileprivate let offset: UInt64
    fileprivate let crc: UInt32
    fileprivate let method: UInt16
}

public struct ZipSource: Sendable {
    public let url: URL
    public let name: String
    public init(url: URL, name: String) { self.url = url; self.name = name }
}

/// A bounded, fully inspected ZIP directory. No path from the archive is used as a filesystem path.
/// Entry bodies are streamed only on demand; every local header and descriptor is checked before init returns.
public struct ZipArchive: Sendable {
    public static let maxEntries = 2_000
    public static let maxUncompressedBytes: UInt64 = 20_000_000_000
    public static let bufferBytes = 65_536
    public let entries: [ZipEntry]
    private let knownEntries: Set<ZipEntry>
    private let url: URL
    private let fileSize: UInt64

    public init(url: URL) throws {
        let file = try ZIPFile(url)
        defer { file.close() }
        self.url = url
        fileSize = file.size
        let inspected = try Self.inspect(file)
        entries = inspected
        knownEntries = Set(inspected)
    }

    /// `onChunk` runs before each output write, so callers can enforce their free-space reserve.
    public func extract(_ entry: ZipEntry, to destination: URL, maxBytes: Int64,
                        onChunk: @Sendable (_ bytesAboutToWrite: Int) throws -> Void = { _ in }) throws -> Int64 {
        guard knownEntries.contains(entry), !entry.isDirectory, maxBytes >= 0 else { throw ZipArchiveError.damaged }
        guard entry.uncompressedSize <= maxBytes else { throw ZipArchiveError.tooLarge }
        let file = try ZIPFile(url)
        defer { file.close() }
        guard file.size == fileSize else { throw ZipArchiveError.damaged }
        var output: FileHandle?
        var created = false
        do {
            try Task.checkCancellation()
            // Exclusive creation: never overwrite a caller's existing file, including a symlink.
            output = try ZIPCodec.create(destination); created = true
            var count: UInt64 = 0
            var crc: UInt32 = 0
            func emit(_ data: Data) throws {
                try Task.checkCancellation()
                count += UInt64(data.count)
                guard count <= UInt64(entry.uncompressedSize), count <= UInt64(maxBytes),
                      count <= Self.maxUncompressedBytes else { throw ZipArchiveError.tooLarge }
                guard UInt64(entry.compressedSize) == 0 ? count == 0 : (count + 99) / 100 <= UInt64(entry.compressedSize) else {
                    throw ZipArchiveError.tooLarge
                }
                crc = ZIPCodec.crc(data, previous: crc)
                try onChunk(data.count)
                try Task.checkCancellation()
                try output?.write(contentsOf: data)
            }
            if entry.method == 0 {
                var offset = entry.offset
                var remaining = UInt64(entry.compressedSize)
                while remaining > 0 {
                    try Task.checkCancellation()
                    let chunk = try file.read(offset, Int(min(remaining, UInt64(Self.bufferBytes))))
                    try emit(chunk)
                    offset += UInt64(chunk.count); remaining -= UInt64(chunk.count)
                }
            } else {
                try Self.inflate(file, entry, emit: emit)
            }
            try Task.checkCancellation()
            guard count == UInt64(entry.uncompressedSize), crc == entry.crc else { throw ZipArchiveError.damaged }
            try output?.synchronize()
            try output?.close(); output = nil
            return Int64(count)
        } catch {
            try? output?.close()
            if created { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }

    private static func inflate(_ file: ZIPFile, _ entry: ZipEntry, emit: (Data) throws -> Void) throws {
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, zlibVersion(), Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw ZipArchiveError.damaged
        }
        defer { inflateEnd(&stream) }
        var offset = entry.offset
        var remaining = UInt64(entry.compressedSize)
        var buffer = [UInt8](repeating: 0, count: bufferBytes)
        var ended = false
        while remaining > 0, !ended {
            try Task.checkCancellation()
            var input = [UInt8](try file.read(offset, Int(min(remaining, UInt64(bufferBytes)))))
            offset += UInt64(input.count); remaining -= UInt64(input.count)
            try input.withUnsafeMutableBufferPointer { bytes in
                stream.next_in = bytes.baseAddress; stream.avail_in = uInt(bytes.count)
                repeat {
                    try Task.checkCancellation()
                    let before = stream.avail_in
                    let (status, written) = buffer.withUnsafeMutableBufferPointer { output -> (Int32, Int) in
                        stream.next_out = output.baseAddress; stream.avail_out = uInt(output.count)
                        let status = CZlib.inflate(&stream, Z_NO_FLUSH)
                        return (status, output.count - Int(stream.avail_out))
                    }
                    if status == Z_BUF_ERROR, stream.avail_in == 0, remaining > 0 { break }
                    guard status == Z_OK || status == Z_STREAM_END else { throw ZipArchiveError.damaged }
                    if written > 0 { try emit(Data(buffer.prefix(written))) }
                    if status == Z_STREAM_END {
                        guard stream.avail_in == 0, remaining == 0 else { throw ZipArchiveError.damaged }
                        ended = true; break
                    }
                    guard written > 0 || stream.avail_in < before else { throw ZipArchiveError.damaged }
                } while stream.avail_in > 0 || stream.avail_out == 0
            }
        }
        guard ended else { throw ZipArchiveError.damaged }
    }

    private static func inspect(_ file: ZIPFile) throws -> [ZipEntry] {
        try Task.checkCancellation()
        guard file.size >= 22 else { throw ZipArchiveError.damaged }
        let tailStart = file.size - min(file.size, 65_557)
        let tail = try file.read(tailStart, Int(file.size - tailStart))
        var endIndex: Int?
        for index in stride(from: tail.count - 22, through: 0, by: -1) {
            if tail.u32(index) == 0x06054b50, index + 22 + Int(tail.u16(index + 20)) == tail.count {
                endIndex = index; break
            }
        }
        guard let endIndex else { throw ZipArchiveError.damaged }
        let end = tailStart + UInt64(endIndex)
        guard tail.u16(endIndex + 4) == 0, tail.u16(endIndex + 6) == 0,
              tail.u16(endIndex + 8) == tail.u16(endIndex + 10) else { throw ZipArchiveError.damaged }
        var count = UInt64(tail.u16(endIndex + 10))
        var directorySize = UInt64(tail.u32(endIndex + 12))
        var directoryOffset = UInt64(tail.u32(endIndex + 16))
        var directoryEnd = end
        if count == 0xffff || directorySize == 0xffff_ffff || directoryOffset == 0xffff_ffff {
            guard end >= 20 else { throw ZipArchiveError.damaged }
            let locator = try file.read(end - 20, 20)
            guard locator.u32(0) == 0x07064b50, locator.u32(4) == 0, locator.u32(16) == 1 else { throw ZipArchiveError.damaged }
            let offset = locator.u64(8)
            let record = try file.read(offset, 56)
            guard record.u32(0) == 0x06064b50, record.u64(4) >= 44,
                  record.u64(4) <= end - 20,
                  offset <= end - 20 - record.u64(4), offset + 12 + record.u64(4) == end - 20,
                  record.u32(16) == 0, record.u32(20) == 0,
                  record.u64(24) == record.u64(32) else { throw ZipArchiveError.damaged }
            count = record.u64(32); directorySize = record.u64(40); directoryOffset = record.u64(48)
            directoryEnd = offset
        }
        guard count <= UInt64(maxEntries) else { throw ZipArchiveError.tooLarge }
        guard directoryOffset <= directoryEnd, directorySize == directoryEnd - directoryOffset else { throw ZipArchiveError.damaged }
        var position = directoryOffset
        var total: UInt64 = 0
        var entries: [ZipEntry] = []
        var ranges: [(UInt64, UInt64)] = []
        for _ in 0..<Int(count) {
            try Task.checkCancellation()
            guard position <= directoryEnd, directoryEnd - position >= 46 else { throw ZipArchiveError.damaged }
            let header = try file.read(position, 46)
            guard header.u32(0) == 0x02014b50 else { throw ZipArchiveError.damaged }
            let flags = header.u16(8), method = header.u16(10)
            try ZIPCodec.flags(flags, method: method)
            let nameLength = Int(header.u16(28)), extraLength = Int(header.u16(30)), commentLength = Int(header.u16(32))
            let length = UInt64(46 + nameLength + extraLength + commentLength)
            guard length <= directoryEnd - position else { throw ZipArchiveError.damaged }
            let nameBytes = try file.read(position + 46, nameLength)
            let name = try ZIPCodec.name(nameBytes, utf8: flags & 0x800 != 0)
            try ZIPCodec.safe(name)
            let extra = try file.read(position + 46 + UInt64(nameLength), extraLength)
            let sizes = try ZIPCodec.sizes(extra, uncompressed: UInt64(header.u32(24)), compressed: UInt64(header.u32(20)),
                                           offset: UInt64(header.u32(42)), disk: UInt64(header.u16(34)))
            guard sizes.disk == 0, sizes.offset < directoryOffset else { throw ZipArchiveError.damaged }
            guard sizes.uncompressed <= maxUncompressedBytes - total else { throw ZipArchiveError.tooLarge }
            total += sizes.uncompressed
            guard sizes.compressed <= UInt64(Int64.max) else { throw ZipArchiveError.damaged }
            guard sizes.compressed == 0 ? sizes.uncompressed == 0 : (sizes.uncompressed + 99) / 100 <= sizes.compressed
            else { throw ZipArchiveError.tooLarge }
            let mode = header.u32(38) >> 16
            guard mode & 0xf000 != 0xa000 else { throw ZipArchiveError.unsafePaths }
            let directory = name.hasSuffix("/") || name.hasSuffix("\\")
            guard !directory || sizes.uncompressed == 0 else { throw ZipArchiveError.damaged }
            if method == 0, sizes.compressed != sizes.uncompressed { throw ZipArchiveError.damaged }
            let local = try file.read(sizes.offset, 30)
            guard local.u32(0) == 0x04034b50 else { throw ZipArchiveError.damaged }
            try ZIPCodec.flags(local.u16(6), method: local.u16(8))
            guard local.u16(6) == flags, local.u16(8) == method else { throw ZipArchiveError.damaged }
            let localNameLength = Int(local.u16(26)), localExtraLength = Int(local.u16(28))
            guard localNameLength == nameLength else { throw ZipArchiveError.damaged }
            let localName = try file.read(sizes.offset + 30, localNameLength)
            guard localName == nameBytes else { throw ZipArchiveError.damaged }
            let dataOffset = sizes.offset + UInt64(30 + localNameLength + localExtraLength)
            guard dataOffset <= directoryOffset, sizes.compressed <= directoryOffset - dataOffset else { throw ZipArchiveError.damaged }
            let localExtra = try file.read(sizes.offset + 30 + UInt64(localNameLength), localExtraLength)
            let localSizes = try ZIPCodec.sizes(localExtra, uncompressed: UInt64(local.u32(22)), compressed: UInt64(local.u32(18)))
            var bodyEnd = dataOffset + sizes.compressed
            if flags & 8 == 0 {
                guard local.u32(14) == header.u32(16), localSizes.compressed == sizes.compressed,
                      localSizes.uncompressed == sizes.uncompressed else { throw ZipArchiveError.damaged }
            } else {
                guard local.u32(14) == 0 || local.u32(14) == header.u32(16),
                      localSizes.compressed == 0 || localSizes.compressed == sizes.compressed,
                      localSizes.uncompressed == 0 || localSizes.uncompressed == sizes.uncompressed else { throw ZipArchiveError.damaged }
                let wide = local.u32(18) == 0xffff_ffff || local.u32(22) == 0xffff_ffff ||
                    sizes.compressed >= 0xffff_ffff || sizes.uncompressed >= 0xffff_ffff
                // The signature is optional, and its magic can also be the actual CRC. Validate
                // complete candidate layouts against the central CRC and sizes instead of guessing
                // the layout from the first four bytes alone.
                var descriptorSize: Int?
                for signed in [false, true] {
                    let size = (wide ? 20 : 12) + (signed ? 4 : 0)
                    guard UInt64(size) <= directoryOffset - bodyEnd else { continue }
                    let descriptor = try file.read(bodyEnd, size)
                    let base = signed ? 4 : 0
                    if signed, descriptor.u32(0) != 0x08074b50 { continue }
                    guard descriptor.u32(base) == header.u32(16),
                          (wide ? descriptor.u64(base + 4) : UInt64(descriptor.u32(base + 4))) == sizes.compressed,
                          (wide ? descriptor.u64(base + 12) : UInt64(descriptor.u32(base + 8))) == sizes.uncompressed else { continue }
                    descriptorSize = size; break
                }
                guard let descriptorSize else { throw ZipArchiveError.damaged }
                bodyEnd += UInt64(descriptorSize)
            }
            ranges.append((sizes.offset, bodyEnd))
            entries.append(ZipEntry(name: name, uncompressedSize: Int64(sizes.uncompressed), compressedSize: Int64(sizes.compressed),
                                    isDirectory: directory, offset: dataOffset, crc: header.u32(16), method: method))
            position += length
        }
        guard position == directoryEnd else { throw ZipArchiveError.damaged }
        let ordered = ranges.sorted { $0.0 < $1.0 }
        for index in 1..<max(1, ordered.count) {
            guard ordered[index - 1].1 <= ordered[index].0 else { throw ZipArchiveError.damaged }
        }
        return entries
    }
}

private final class ZIPFile {
    let handle: FileHandle
    let size: UInt64
    init(_ url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
    }
    func close() { try? handle.close() }
    func read(_ offset: UInt64, _ count: Int) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw ZipArchiveError.damaged }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw ZipArchiveError.damaged }
        return data
    }
}

private enum ZIPCodec {
    static func create(_ destination: URL) throws -> FileHandle {
        let descriptor = destination.withUnsafeFileSystemRepresentation { path in
            path.map { Darwin.open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) } ?? -1
        }
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    static func flags(_ flags: UInt16, method: UInt16) throws {
        if flags & 0x2041 != 0 { throw ZipArchiveError.encrypted }
        guard method == 0 || method == 8, flags & ~UInt16(0x080e) == 0 else { throw ZipArchiveError.damaged }
    }
    static func safe(_ name: String) throws {
        let path = name.replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !(path.count >= 2 && path[path.index(after: path.startIndex)] == ":"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else { throw ZipArchiveError.unsafePaths }
    }
    static func name(_ data: Data, utf8: Bool) throws -> String {
        let encoding = utf8 ? String.Encoding.utf8 : String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        guard let text = String(data: data, encoding: encoding) else { throw ZipArchiveError.damaged }
        return text
    }
    static func sizes(_ data: Data, uncompressed: UInt64, compressed: UInt64, offset: UInt64 = 0, disk: UInt64 = 0) throws
        -> (uncompressed: UInt64, compressed: UInt64, offset: UInt64, disk: UInt64) {
        var cursor = 0
        var zip64: Data?
        while cursor < data.count {
            guard data.count - cursor >= 4 else { throw ZipArchiveError.damaged }
            let id = data.u16(cursor), length = Int(data.u16(cursor + 2)); cursor += 4
            guard length <= data.count - cursor else { throw ZipArchiveError.damaged }
            if id == 1 {
                guard zip64 == nil else { throw ZipArchiveError.damaged }
                zip64 = Data(data[cursor..<cursor + length])
            }
            cursor += length
        }
        var next = 0
        func value(_ initial: UInt64, sentinel: UInt64, width: Int) throws -> UInt64 {
            guard initial == sentinel else { return initial }
            guard let zip64, width <= zip64.count - next else { throw ZipArchiveError.damaged }
            defer { next += width }
            return width == 8 ? zip64.u64(next) : UInt64(zip64.u32(next))
        }
        return try (value(uncompressed, sentinel: 0xffff_ffff, width: 8), value(compressed, sentinel: 0xffff_ffff, width: 8),
                    value(offset, sentinel: 0xffff_ffff, width: 8), value(disk, sentinel: 0xffff, width: 4))
    }
    static func crc(_ data: Data, previous: UInt32 = 0) -> UInt32 {
        data.withUnsafeBytes { bytes in UInt32(CZlib.crc32(uLong(previous), bytes.bindMemory(to: UInt8.self).baseAddress, uInt(data.count))) }
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
    func u64(_ offset: Int) -> UInt64 { UInt64(u32(offset)) | UInt64(u32(offset + 4)) << 32 }
}

extension ZipArchive {
    // Pure record construction also permits testing a >4 GiB offset without a giant fixture.
    static func centralDirectoryRecord(name: Data, size: UInt64, localOffset: UInt64, crc: UInt32,
                                       forceZIP64: Bool = false) -> Data {
        let wideSize = forceZIP64 || size >= 0xffff_ffff
        let wideOffset = localOffset >= 0xffff_ffff
        var extra = Data()
        if wideSize || wideOffset {
            var payload = Data()
            if wideSize { payload.put64(size); payload.put64(size) }
            if wideOffset { payload.put64(localOffset) }
            extra.put16(1); extra.put16(UInt16(payload.count)); extra.append(payload)
        }
        var central = Data(); central.put32(0x02014b50); central.put16(45)
        central.put16(wideSize || wideOffset ? 45 : 20)
        central.put16(0x0808); central.put16(0); central.put16(0); central.put16(0x21); central.put32(crc)
        central.put32(wideSize ? 0xffff_ffff : UInt32(size)); central.put32(wideSize ? 0xffff_ffff : UInt32(size))
        central.put16(UInt16(name.count)); central.put16(UInt16(extra.count)); central.put16(0)
        central.put16(0); central.put16(0); central.put32(0)
        central.put32(wideOffset ? 0xffff_ffff : UInt32(localOffset))
        central.append(name); central.append(extra)
        return central
    }

    /// Streams original bytes into a ZIP with method STORED. Entry names must already be unique base names.
    public static func write(_ sources: [ZipSource], to destination: URL) throws {
        try write(sources, to: destination, onChunk: nil)
    }

    static func write(_ sources: [ZipSource], to destination: URL, onChunk: (@Sendable () -> Void)?,
                      forceZIP64: Bool = false) throws {
        guard sources.count <= maxEntries else { throw ZipArchiveError.tooLarge }
        guard !sources.isEmpty else { throw ZipArchiveError.empty }
        var names: Set<Data> = []
        for source in sources {
            try ZIPCodec.safe(source.name)
            guard !source.name.contains("/"), !source.name.contains("\\"), !source.name.isEmpty,
                  source.name.utf8.count <= 65_535, names.insert(Data(source.name.utf8)).inserted else {
                throw ZipArchiveError.unsafePaths
            }
        }
        var output: FileHandle?
        var created = false
        do {
            try Task.checkCancellation()
            output = try ZIPCodec.create(destination); created = true
            var position: UInt64 = 0
            var total: UInt64 = 0
            var directory: [Data] = []
            func emit(_ data: Data) throws {
                try Task.checkCancellation()
                try output?.write(contentsOf: data)
                position += UInt64(data.count)
            }
            for source in sources {
                try Task.checkCancellation()
                let input = try ZIPFile(source.url)
                defer { input.close() }
                guard input.size <= maxUncompressedBytes - total else { throw ZipArchiveError.tooLarge }
                total += input.size
                let wide = forceZIP64 || input.size >= 0xffff_ffff
                let localOffset = position
                let name = Data(source.name.utf8)
                var extra = Data()
                if wide { extra.put16(1); extra.put16(16); extra.put64(input.size); extra.put64(input.size) }
                // A descriptor follows the bytes, so the CRC needs no second pass over the source.
                var local = Data()
                local.put32(0x04034b50); local.put16(wide ? 45 : 20); local.put16(0x0808); local.put16(0)
                local.put16(0); local.put16(0x21); local.put32(0)
                local.put32(wide ? 0xffff_ffff : 0); local.put32(wide ? 0xffff_ffff : 0)
                local.put16(UInt16(name.count)); local.put16(UInt16(extra.count))
                local.append(name); local.append(extra)
                try emit(local)
                var crc: UInt32 = 0
                var offset: UInt64 = 0
                while offset < input.size {
                    try Task.checkCancellation()
                    let chunk = try input.read(offset, Int(min(input.size - offset, UInt64(bufferBytes))))
                    crc = ZIPCodec.crc(chunk, previous: crc)
                    try emit(chunk); offset += UInt64(chunk.count)
                    onChunk?()
                }
                // Detect a source changed during export, including growth, instead of silently truncating it.
                guard try input.handle.seekToEnd() == input.size else { throw ZipArchiveError.damaged }
                var descriptor = Data(); descriptor.put32(0x08074b50); descriptor.put32(crc)
                if wide { descriptor.put64(input.size); descriptor.put64(input.size) }
                else { descriptor.put32(UInt32(input.size)); descriptor.put32(UInt32(input.size)) }
                try emit(descriptor)
                directory.append(centralDirectoryRecord(name: name, size: input.size, localOffset: localOffset,
                                                        crc: crc, forceZIP64: forceZIP64))
            }
            let directoryOffset = position
            for entry in directory { try emit(entry) }
            let directorySize = position - directoryOffset
            if forceZIP64 || directoryOffset >= 0xffff_ffff || directorySize >= 0xffff_ffff {
                let recordOffset = position
                var record = Data(); record.put32(0x06064b50); record.put64(44); record.put16(45); record.put16(45)
                record.put32(0); record.put32(0); record.put64(UInt64(sources.count)); record.put64(UInt64(sources.count))
                record.put64(directorySize); record.put64(directoryOffset)
                try emit(record)
                var locator = Data(); locator.put32(0x07064b50); locator.put32(0); locator.put64(recordOffset); locator.put32(1)
                try emit(locator)
            }
            var end = Data(); end.put32(0x06054b50); end.put16(0); end.put16(0)
            end.put16(forceZIP64 ? 0xffff : UInt16(sources.count)); end.put16(forceZIP64 ? 0xffff : UInt16(sources.count))
            end.put32(directorySize >= 0xffff_ffff ? 0xffff_ffff : UInt32(directorySize))
            end.put32(directoryOffset >= 0xffff_ffff ? 0xffff_ffff : UInt32(directoryOffset)); end.put16(0)
            try emit(end)
            try Task.checkCancellation()
            try output?.synchronize(); try output?.close(); output = nil
        } catch {
            try? output?.close()
            if created { try? FileManager.default.removeItem(at: destination) }
            throw error
        }
    }
}

private extension Data {
    mutating func put16(_ value: UInt16) { append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8)) }
    mutating func put32(_ value: UInt32) { put16(UInt16(truncatingIfNeeded: value)); put16(UInt16(truncatingIfNeeded: value >> 16)) }
    mutating func put64(_ value: UInt64) { put32(UInt32(truncatingIfNeeded: value)); put32(UInt32(truncatingIfNeeded: value >> 32)) }
}
