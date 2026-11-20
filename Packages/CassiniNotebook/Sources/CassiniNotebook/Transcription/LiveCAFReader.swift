import CryptoKit
import Foundation

/// Pure read-only reader for PCM16LE mono `.caf` files (`FileHandle(forReadingFrom:)`), safe to run off the main actor
/// while `AVAudioRecorder` writes to the same file with zero shared locks or audio-callback hooks.
///
/// Supports both growing `.caf` files (whose `data` chunk size is `-1` / unknown until `AVAudioRecorder.stop()`
/// finalizes the header) and finalized `.caf` files.
public final class LiveCAFReader: @unchecked Sendable {
    /// Parsed immutable layout of a mono PCM16LE CAF file's `desc` and `data` chunks.
    public struct Layout: Hashable, Sendable {
        public let sampleRate: Int
        public let channels: Int
        public let bitsPerChannel: Int
        public let bytesPerFrame: Int
        /// Byte offset of frame 0 inside the `data` chunk (immediately after the 4-byte `mEditCount`).
        public let dataStartOffset: UInt64
        /// Declared byte length of PCM payload in the `data` chunk header, or nil when `-1` (growing capture).
        public let declaredDataBytes: UInt64?
    }

    public enum Error: Swift.Error, Equatable, Sendable {
        case notCAF
        case unsupportedFormat
        case incompleteHeader
        case outOfRange
        case shortRead
    }

    /// Conservative default safety margin behind the writer cursor while a recording is active (100 ms at 48 kHz).
    public static let defaultSafetyMarginFrames: UInt64 = 4_800
    /// Right half-width of the 97-tap 48 kHz -> 16 kHz FIR filter (`cassini-fir-48k-16k-v1`).
    public static let firLookaheadFrames: UInt64 = 48

    private static let fileHeaderSize: UInt64 = 8
    private static let chunkHeaderSize: UInt64 = 12
    private static let editCountSize: UInt64 = 4
    private static let lpcmFormatID: UInt32 = 0x6C70_636D // "lpcm"
    private static let linearPCMFormatFlagIsFloat: UInt32 = 1 << 0
    private static let linearPCMFormatFlagIsLittleEndian: UInt32 = 1 << 1

    public let url: URL
    public let layout: Layout
    private let handle: FileHandle

    public var sampleRate: Int { layout.sampleRate }
    public var bytesPerFrame: Int { layout.bytesPerFrame }

    /// Opens `url` strictly read-only (`FileHandle(forReadingFrom:)`) and parses its CAF `desc` and `data` chunks.
    public init(url: URL) throws {
        self.url = url
        let handle = try FileHandle(forReadingFrom: url)
        do {
            self.layout = try Self.parseLayout(handle)
            self.handle = handle
        } catch {
            try? handle.close()
            throw error
        }
    }

    deinit {
        try? handle.close()
    }

    /// Closes the underlying read-only file descriptor explicitly.
    public func close() {
        try? handle.close()
    }

    /// Total complete PCM16LE frames currently present in the `data` chunk on disk.
    /// For finalized CAF files with a declared `data` size, never exceeds the declared byte count.
    public func availableFrames() throws -> UInt64 {
        let fileSize = try handle.seekToEnd()
        guard fileSize >= layout.dataStartOffset else { return 0 }
        let onDiskBytes = fileSize - layout.dataStartOffset
        let usableBytes = layout.declaredDataBytes.map { min(onDiskBytes, $0) } ?? onDiskBytes
        return usableBytes / UInt64(layout.bytesPerFrame)
    }

    /// Highest frame index safely committed behind the writer cursor during an active recording.
    public func safeThroughFrame(safetyMarginFrames: UInt64 = LiveCAFReader.defaultSafetyMarginFrames) throws -> UInt64 {
        let total = try availableFrames()
        guard total > safetyMarginFrames else { return 0 }
        return total - safetyMarginFrames
    }

    /// Reads raw PCM16LE bytes for `[fromFrame ..< fromFrame + frameCount)`.
    public func readPCM16LEBytes(fromFrame: UInt64, frameCount: UInt64) throws -> Data {
        if frameCount == 0 { return Data() }
        let available = try availableFrames()
        guard fromFrame <= available, frameCount <= available - fromFrame else { throw Error.outOfRange }
        let byteOffset = layout.dataStartOffset + fromFrame * UInt64(layout.bytesPerFrame)
        let byteCount = Int(frameCount * UInt64(layout.bytesPerFrame))
        try handle.seek(toOffset: byteOffset)
        let data = try handle.read(upToCount: byteCount) ?? Data()
        guard data.count == byteCount else { throw Error.shortRead }
        return data
    }

    /// Reads mono PCM16LE frames `[fromFrame ..< fromFrame + frameCount)` as Float32 in `[-1.0, 1.0)`,
    /// matching Core Audio's `Int16 -> Float32` conversion (`Float(sample) / 32768.0`).
    public func readFloats(fromFrame: UInt64, frameCount: UInt64) throws -> [Float] {
        let bytes = try readPCM16LEBytes(fromFrame: fromFrame, frameCount: frameCount)
        return Self.decodePCM16LEToFloats(bytes)
    }

    /// Incremental SHA-256 hasher over `[0 ..< hashedFrames)` of a growing CAF `data` chunk.
    /// Advances strictly over newly committed delta frames so repeated checkpoint commits stay O(N) overall,
    /// finalizing a value-type copy of `CryptoKit.SHA256` at each commit boundary without resetting state.
    public struct IncrementalPrefixHasher {
        private var hasher = SHA256()
        public private(set) var hashedFrames: UInt64 = 0
        public private(set) var totalBytesHashed: UInt64 = 0

        public init() {}

        /// Advances the running SHA-256 state to `committedFrames` and returns the lowercase 64-hex digest
        /// of `[0 ..< committedFrames)` without mutating the continuing hash state.
        public mutating func advance(
            to committedFrames: UInt64,
            using reader: LiveCAFReader,
            isCancelled: () -> Bool = { false }
        ) throws -> String {
            guard committedFrames > 0, committedFrames >= hashedFrames else { throw LiveCAFReader.Error.outOfRange }
            if committedFrames > hashedFrames {
                let available = try reader.availableFrames()
                guard committedFrames <= available else { throw LiveCAFReader.Error.outOfRange }
                let bytesPerFrame = UInt64(reader.layout.bytesPerFrame)
                let chunkBytes = 65_536 - (65_536 % Int(bytesPerFrame))
                var remainingFrames = committedFrames - hashedFrames
                try reader.handle.seek(toOffset: reader.layout.dataStartOffset + hashedFrames * bytesPerFrame)
                while remainingFrames > 0 {
                    if isCancelled() || Task.isCancelled { throw CancellationError() }
                    let toReadBytes = Int(min(remainingFrames * bytesPerFrame, UInt64(chunkBytes)))
                    guard let chunk = try reader.handle.read(upToCount: toReadBytes), chunk.count == toReadBytes else {
                        throw LiveCAFReader.Error.shortRead
                    }
                    hasher.update(data: chunk)
                    let framesReadNow = UInt64(toReadBytes) / bytesPerFrame
                    hashedFrames += framesReadNow
                    totalBytesHashed += UInt64(toReadBytes)
                    remainingFrames -= framesReadNow
                }
            }
            if isCancelled() || Task.isCancelled { throw CancellationError() }
            let snapshot = hasher
            return snapshot.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Computes lowercase 64-hex SHA-256 over raw PCM16LE bytes `[0 ..< committedFrames * bytesPerFrame)`
    /// inside the CAF `data` chunk, streaming in bounded chunks (64 KiB) to avoid large allocations.
    public func prefixSHA256(committedFrames: UInt64, isCancelled: () -> Bool = { false }) throws -> String {
        var hasher = IncrementalPrefixHasher()
        return try hasher.advance(to: committedFrames, using: self, isCancelled: isCancelled)
    }

    /// Inspects a finalized (or growing) CAF file read-only and returns its layout and frame count.
    public static func inspect(url: URL) throws -> (layout: Layout, totalFrames: UInt64) {
        let reader = try LiveCAFReader(url: url)
        defer { reader.close() }
        return (reader.layout, try reader.availableFrames())
    }

    /// Computes a `CheckpointState.PrefixExpectation` for a finalized `.caf` file against a checkpoint's
    /// `committedPrefix`, returning `nil` if the file is not a supported mono PCM16LE CAF file.
    public static func prefixExpectation(
        for url: URL,
        committedUnitCount: UInt64,
        clipsURL: URL? = nil
    ) -> CheckpointState.PrefixExpectation? {
        guard let reader = try? LiveCAFReader(url: url) else { return nil }
        defer { reader.close() }
        guard let totalFrames = try? reader.availableFrames() else { return nil }
        let digest: String
        if committedUnitCount > 0, totalFrames >= committedUnitCount,
           let computed = try? reader.prefixSHA256(committedFrames: committedUnitCount) {
            digest = computed
        } else {
            digest = ""
        }
        let lookahead = reader.sampleRate == 48_000 ? Int(Self.firLookaheadFrames) : 0
        var workFiles = CheckpointState.WorkFileBytes()
        if let clipsURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: clipsURL.path),
           let size = (attrs[.size] as? NSNumber)?.int64Value {
            workFiles.clipsBytes = size
        }
        return CheckpointState.PrefixExpectation(
            prefixKind: .cafPcm16LeFrames,
            sourceSampleRateHz: reader.sampleRate,
            resamplerLookaheadFrames: lookahead,
            finalizedUnitCount: totalFrames,
            prefixSha256: digest,
            workFiles: workFiles
        )
    }

    /// Converts little-endian signed 16-bit PCM bytes to Float32 samples (`Float(i16) / 32768.0`).
    public static func decodePCM16LEToFloats(_ bytes: Data) -> [Float] {
        let count = bytes.count / 2
        guard count > 0 else { return [] }
        var output = [Float](repeating: 0, count: count)
        let scale: Float = 1.0 / 32768.0
        bytes.withUnsafeBytes { raw in
            guard let ptr = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for i in 0..<count {
                let lo = UInt16(ptr[i * 2])
                let hi = UInt16(ptr[i * 2 + 1])
                let sample = Int16(bitPattern: lo | (hi << 8))
                output[i] = Float(sample) * scale
            }
        }
        return output
    }

    private static func parseLayout(_ handle: FileHandle) throws -> Layout {
        let fileSize = try handle.seekToEnd()
        guard fileSize >= fileHeaderSize else { throw Error.incompleteHeader }
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: Int(fileHeaderSize)),
              header.count == Int(fileHeaderSize),
              header.prefix(4) == Data("caff".utf8) else {
            throw Error.notCAF
        }

        var offset = fileHeaderSize
        var parsedDesc: (sampleRate: Int, channels: Int, bitsPerChannel: Int, bytesPerFrame: Int)?

        while offset + chunkHeaderSize <= fileSize {
            try handle.seek(toOffset: offset)
            guard let chunk = try handle.read(upToCount: Int(chunkHeaderSize)),
                  chunk.count == Int(chunkHeaderSize) else {
                throw Error.incompleteHeader
            }
            let type = String(decoding: chunk.prefix(4), as: UTF8.self)
            let rawSize = Int64(bitPattern: chunk.bigEndianUInt64(at: 4))
            let bodyStart = offset + chunkHeaderSize

            if type == "desc" {
                guard rawSize >= 32, fileSize >= bodyStart + 32,
                      let desc = try handle.read(upToCount: 32), desc.count == 32 else {
                    throw Error.incompleteHeader
                }
                let rateBits = desc.bigEndianUInt64(at: 0)
                let rateDouble = Double(bitPattern: rateBits)
                let formatID = desc.bigEndianUInt32(at: 8)
                let formatFlags = desc.bigEndianUInt32(at: 12)
                let bytesPerPacket = desc.bigEndianUInt32(at: 16)
                let framesPerPacket = desc.bigEndianUInt32(at: 20)
                let channelsPerFrame = desc.bigEndianUInt32(at: 24)
                let bitsPerChannel = desc.bigEndianUInt32(at: 28)

                guard rateDouble.isFinite, rateDouble > 0, rateDouble <= 1_000_000, rateDouble.rounded() == rateDouble,
                      formatID == lpcmFormatID,
                      (formatFlags & linearPCMFormatFlagIsFloat) == 0,
                      (formatFlags & linearPCMFormatFlagIsLittleEndian) != 0,
                      framesPerPacket == 1,
                      channelsPerFrame == 1,
                      bitsPerChannel == 16,
                      bytesPerPacket == 2 else {
                    throw Error.unsupportedFormat
                }
                parsedDesc = (Int(rateDouble), Int(channelsPerFrame), Int(bitsPerChannel), Int(bytesPerPacket))
            } else if type == "data" {
                guard let desc = parsedDesc else { throw Error.unsupportedFormat }
                guard fileSize >= bodyStart + editCountSize else { throw Error.incompleteHeader }
                let declared: UInt64?
                if rawSize == -1 {
                    declared = nil
                } else if rawSize >= Int64(editCountSize) {
                    declared = UInt64(rawSize) - editCountSize
                } else {
                    throw Error.incompleteHeader
                }
                return Layout(
                    sampleRate: desc.sampleRate,
                    channels: desc.channels,
                    bitsPerChannel: desc.bitsPerChannel,
                    bytesPerFrame: desc.bytesPerFrame,
                    dataStartOffset: bodyStart + editCountSize,
                    declaredDataBytes: declared
                )
            }

            guard rawSize >= 0 else { throw Error.unsupportedFormat }
            let nextOffset = bodyStart.addingReportingOverflow(UInt64(rawSize))
            guard !nextOffset.overflow else { throw Error.incompleteHeader }
            offset = nextOffset.partialValue
        }

        throw Error.incompleteHeader
    }
}

private extension Data {
    func bigEndianUInt64(at index: Int) -> UInt64 {
        self[startIndex + index ..< startIndex + index + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }

    func bigEndianUInt32(at index: Int) -> UInt32 {
        self[startIndex + index ..< startIndex + index + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
}
