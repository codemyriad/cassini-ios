import Foundation
import CassiniEngine
import libzstd

/// Zstandard for `ArtifactFetcher.fetchCompressed` (Android's `ZstdInputStream` of zstd-jni): the diarizer comes as
/// seekable Zstandard, which is ordinary frames plus a skippable seek-table frame that the streaming decoder skips.
/// The input is read and the output handed to the sink in blocks, so neither file is held in memory. A stream that is
/// not Zstandard, is damaged, or ends inside a frame throws `ZstdDecompressor.Failure`.
public struct ZstdDecompressor: Decompressing {
    /// The facebook/zstd commit Package.swift pins: the v1.5.7 tag, the release zstd-jni 1.5.7-22 bundles.
    public static let revision = "f8745da6ff1ad1e7bab384bd1f9d742439278e99"

    public struct Failure: Error, Hashable, Sendable, CustomStringConvertible {
        public var description: String
    }

    public init() {}

    public func decompress(_ source: URL, into sink: (Data) throws -> Void) throws {
        guard let stream = ZSTD_createDStream() else { throw Failure(description: "No decompression stream") }
        defer { ZSTD_freeDStream(stream) }
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let outputSize = ZSTD_DStreamOutSize()
        var output = [UInt8](repeating: 0, count: outputSize)
        // Bytes still expected to end the frame in progress; 0 between frames.
        var pending = 0
        var sawInput = false
        while let block = try handle.read(upToCount: ZSTD_DStreamInSize()), !block.isEmpty {
            try Task.checkCancellation()
            sawInput = true
            try block.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                var input = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: 0)
                while input.pos < input.size {
                    let produced = try output.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Int in
                        var out = ZSTD_outBuffer(dst: buffer.baseAddress, size: buffer.count, pos: 0)
                        let result = ZSTD_decompressStream(stream, &out, &input)
                        if ZSTD_isError(result) != 0 {
                            throw Failure(description: String(cString: ZSTD_getErrorName(result)))
                        }
                        pending = result
                        return out.pos
                    }
                    if produced > 0 { try sink(Data(output[0..<produced])) }
                }
            }
        }
        // Flush what the decoder still holds once the input has ended.
        while pending > 0 {
            var input = ZSTD_inBuffer(src: nil, size: 0, pos: 0)
            let produced = try output.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) -> Int in
                var out = ZSTD_outBuffer(dst: buffer.baseAddress, size: buffer.count, pos: 0)
                let result = ZSTD_decompressStream(stream, &out, &input)
                if ZSTD_isError(result) != 0 { throw Failure(description: String(cString: ZSTD_getErrorName(result))) }
                pending = result
                return out.pos
            }
            guard produced > 0 else { break }
            try sink(Data(output[0..<produced]))
        }
        guard sawInput else { throw Failure(description: "Empty input") }
        guard pending == 0 else { throw Failure(description: "The stream ends inside a frame") }
    }
}
