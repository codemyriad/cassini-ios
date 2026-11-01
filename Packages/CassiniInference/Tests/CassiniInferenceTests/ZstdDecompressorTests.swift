import CryptoKit
import Foundation
import Testing
import CassiniEngine
import CassiniInference
import libzstd

/// Android's ZstdModelTest: the seekable Zstandard of the speaker model download, through `ArtifactFetcher.decompress`
/// with `ZstdDecompressor`, decompresses to the verified artifact or leaves no model.
@Suite struct ZstdDecompressorTests {
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private let payload = Data((0..<600_000).map { UInt8($0 * 31 % 251) })
    private var artifact: Artifact {
        Artifact("model.onnx", Int64(payload.count), SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
    }

    private func compress(_ data: Data) -> Data {
        var output = [UInt8](repeating: 0, count: ZSTD_compressBound(data.count))
        let size = data.withUnsafeBytes { input in
            ZSTD_compress(&output, output.count, input.baseAddress, input.count, 3)
        }
        precondition(ZSTD_isError(size) == 0)
        return Data(output[0..<size])
    }

    /// Two frames and a trailing skippable seek table, like the seekable files on the model host.
    private func seekable(_ data: Data) -> Data {
        let half = data.count / 2
        var out = compress(data.prefix(half)) + compress(data.suffix(from: data.startIndex + half))
        let table = Data(count: 9 + 8)
        withUnsafeBytes(of: UInt32(0x184D_2A5E).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(table.count).littleEndian) { out.append(contentsOf: $0) }
        return out + table
    }

    private func write(_ bytes: Data) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("model.onnx.zst")
        try bytes.write(to: source)
        return source
    }

    // ports: ZstdModelTest#seekableZstandardDecompressesToTheVerifiedArtifact
    @Test func seekableZstandardDecompressesToTheVerifiedArtifact() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try write(seekable(payload))
        try ArtifactFetcher.decompress(source, artifact, into: folder, decoder: ZstdDecompressor())
        #expect(try Data(contentsOf: folder.appendingPathComponent(artifact.name)) == payload)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(artifact.sha256).part").path))
    }

    // ports: ZstdModelTest#wrongContentLeavesNoModel
    @Test func wrongContentLeavesNoModel() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var other = payload
        other[1000] &+= 1
        let source = try write(seekable(other))
        #expect(throws: ModelError(.modelVerify)) {
            try ArtifactFetcher.decompress(source, artifact, into: folder, decoder: ZstdDecompressor())
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["model.onnx.zst"])
    }

    // ports: ZstdModelTest#corruptStreamOrOversizedOutputLeavesNoModel
    @Test func corruptStreamOrOversizedOutputLeavesNoModel() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        var corrupt = seekable(payload)
        corrupt[20] &+= 7
        // A frame cut short: the stream ends inside it.
        let truncated = compress(payload).dropLast(4)
        for bytes in [corrupt, seekable(payload + Data(count: 10)), Data("not zstd".utf8), Data(truncated)] {
            let source = try write(bytes)
            #expect(throws: ModelError.self) {
                try ArtifactFetcher.decompress(source, artifact, into: folder, decoder: ZstdDecompressor())
            }
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(artifact.name).path))
            #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("\(artifact.sha256).part").path))
        }
    }

    /// The decoder hands the output over in blocks, never the whole file at once.
    @Test func theOutputComesInBlocks() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try write(seekable(payload))
        var blocks: [Int] = []
        try ZstdDecompressor().decompress(source) { blocks.append($0.count) }
        #expect(blocks.reduce(0, +) == payload.count)
        #expect(blocks.count > 1 && blocks.allSatisfy { $0 <= ZSTD_DStreamOutSize() })
    }
}
