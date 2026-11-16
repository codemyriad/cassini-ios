import CryptoKit
import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

@Suite struct ImportPolicyTests {
    @Test func resourceMatchesImmutableUpstreamPin() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        let pin = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("contracts/import-types/UPSTREAM.json"))) as? [String: String])
        let payload = try Data(contentsOf: root.appendingPathComponent("Packages/CassiniEngine/Sources/CassiniEngine/Resources/import-types.json"))
        #expect(pin["repository"] == "https://github.com/codemyriad/cassini-ux")
        #expect(pin["path"] == "contract/import-types.json")
        #expect(pin["commit"]?.count == 40)
        #expect(pin["sha256"] == SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined())
    }

    @Test func onlyDecidedExtensionsAndNarrowUTIsAreOffered() {
        #expect(ImportPolicy.entries.map(\.id) == ["opus-ogg", "mp3", "m4a", "wav", "flac"])
        for name in ["one.opus", "ONE.OGG", "one.mp3", "one.m4a", "one.wav", "one.flac"] {
            #expect(ImportPolicy.accepts(filename: name))
        }
        for ext in ["oga", "ogv", "ogx", "spx", "aac", "aiff", "caf", "mp4"] {
            #expect(!ImportPolicy.accepts(filename: "one." + ext))
        }
        #expect(!ImportPolicy.utis.contains("public.audio"))
        #expect(ImportPolicy.utis.contains("org.xiph.flac"))
    }

    private func page(_ payload: [UInt8], bos: Bool = true, serial: UInt8 = 1) -> [UInt8] {
        var head = [UInt8](repeating: 0, count: 28)
        head.replaceSubrange(0..<4, with: "OggS".utf8)
        head[5] = bos ? 2 : 0; head[14] = serial; head[26] = 1; head[27] = UInt8(payload.count)
        return head + payload
    }

    @Test(arguments: [true, false])
    func rejectsUnsupportedHeadersBeforeCreatingDestinationAndPreservesCaller(metadataKnown: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let opus = Array("OpusHead".utf8) + [1, 1] + [UInt8](repeating: 0, count: 9)
        let tags = page(Array("OpusTags".utf8) + [UInt8](repeating: 0, count: 8), bos: false)
        let invalid: [(String, [UInt8])] = [
            ("video.ogg", page([0x80] + Array("theora".utf8) + [UInt8](repeating: 0, count: 32)) + tags),
            ("vorbis.ogg", page([1] + Array("vorbis".utf8) + [UInt8](repeating: 0, count: 32)) + tags),
            ("speex.opus", page(Array("Speex   ".utf8) + [UInt8](repeating: 0, count: 32)) + tags),
            ("flac.ogg", page([0x7f] + Array("FLAC".utf8) + [UInt8](repeating: 0, count: 32)) + tags),
            ("native.mp3", Array("fLaC".utf8) + [UInt8](repeating: 0, count: 80)),
            ("caf.mp3", Array("caff".utf8) + [UInt8](repeating: 0, count: 80)),
            ("aiff.m4a", Array("FORM".utf8) + [0, 0, 0, 72] + Array("AIFF".utf8) + [UInt8](repeating: 0, count: 72)),
            ("adts.mp3", [0xff, 0xf1] + [UInt8](repeating: 0, count: 80)),
            ("multiplexed.ogg", page(opus) + page([0x80] + Array("theora".utf8), serial: 2)),
            ("truncated.opus", page(opus)),
            ("truncated.wav", Array("RIFF".utf8) + [0xff, 0xff, 0, 0] + Array("WAVE".utf8) + [UInt8](repeating: 0, count: 32)),
            ("video.ogv", page(opus) + tags),
        ]
        let importer = CoordinatedFileImporter(storage: FakeStorage(), sizeOf: { url in
            metadataKnown ? CoordinatedFileImporter.reportedSize(of: url) : nil
        })
        for (name, bytes) in invalid {
            let source = root.appendingPathComponent(name), destination = root.appendingPathComponent("copy")
            try Data(bytes).write(to: source)
            await #expect(throws: FileImportError.cannotOpen) {
                try await importer.copy(from: source, to: destination, maxBytes: 1 << 20, reserveBytes: 0)
            }
            #expect(!FileManager.default.fileExists(atPath: destination.path), "\(name)")
            #expect(try Data(contentsOf: source) == Data(bytes), "\(name)")
        }
        let source = root.appendingPathComponent("valid.ogg"), destination = root.appendingPathComponent("copy")
        let bytes = Data(try ImportFixtures.opus(packets: 100))
        try bytes.write(to: source)
        _ = try await importer.copy(from: source, to: destination, maxBytes: 1 << 20, reserveBytes: 0)
        #expect(try Data(contentsOf: destination) == bytes)
        #expect(try Data(contentsOf: source) == bytes)
    }

    @Test func malformedAndTruncatedOggProbesNeverCrash() throws {
        let bytes = Data(try ImportFixtures.opus(packets: 10))
        for length in 0..<min(bytes.count, 100) {
            _ = try? ImportPolicy.validate(header: Data(bytes.prefix(length)), filename: "one.ogg", fileBytes: Int64(length))
        }
        for segments in UInt8.min...UInt8.max {
            var probe = [UInt8](repeating: 0xff, count: 1024)
            probe.replaceSubrange(0..<4, with: "OggS".utf8); probe[4] = 0; probe[5] = 2; probe[26] = segments
            #expect(throws: FileImportError.cannotOpen) {
                try ImportPolicy.validate(header: Data(probe), filename: "bad.ogg", fileBytes: 1024)
            }
        }
    }
}
