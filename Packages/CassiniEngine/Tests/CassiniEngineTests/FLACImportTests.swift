import Foundation
import Testing
import CassiniCore
import CassiniEngine
import CassiniEngineTesting

@Suite struct FLACImportTests {
    @Test(arguments: [48_000, 44_100]) func nativeAndExtensionlessCopy(rate: Int) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = FLACFixtures.native(rate: rate)
        for name in ["native.flac", "shared-audio"] {
            let source = folder.appendingPathComponent(name), destination = folder.appendingPathComponent("staged.tmp")
            try bytes.write(to: source)
            let info = try #require(try NativeFLAC.validateIfPresent(source))
            #expect(info.totalSamples == FLACFixtures.samples)
            let importer = CoordinatedFileImporter(storage: FakeStorage())
            _ = try await importer.copy(from: source, to: destination, maxBytes: 1 << 20, reserveBytes: 0)
            #expect(try Data(contentsOf: destination) == bytes)
            try FileManager.default.removeItem(at: destination)
        }
    }
    @Test func typeAndMIMEAdmission() throws {
        for mime in ["audio/flac", "audio/x-flac"] {
            try ImportPolicy.validate(header: FLACFixtures.native(), filename: "shared", fileBytes: nil,
                                      typeIdentifier: "org.xiph.flac", mimeType: mime)
            for bytes in FLACFixtures.invalid.prefix(4) {
                #expect(throws: FileImportError.cannotOpen) {
                    try ImportPolicy.validate(header: bytes, filename: "shared", fileBytes: nil,
                                              typeIdentifier: "org.xiph.flac", mimeType: mime)
                }
            }
            #expect(ImportPolicy.accepts(filename: "shared", typeIdentifier: "org.xiph.flac", mimeType: mime))
            #expect(!ImportPolicy.accepts(filename: "shared.mp3", typeIdentifier: "org.xiph.flac", mimeType: mime))
        }
        for mime in ["audio/ogg", "application/ogg", "audio/x-oggflac", "audio/x-flac+ogg"] {
            #expect(!ImportPolicy.accepts(filename: "native.flac", typeIdentifier: "org.xiph.flac", mimeType: mime))
        }
    }
    @Test func damagedStreamsNeverLeaveStaging() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for bytes in FLACFixtures.invalid {
            for name in ["broken.flac", "shared-audio"] {
                let source = folder.appendingPathComponent(name), destination = folder.appendingPathComponent("stage.tmp")
                try bytes.write(to: source)
                await #expect(throws: FileImportError.cannotOpen) {
                    try await CoordinatedFileImporter(storage: FakeStorage()).copy(from: source, to: destination, maxBytes: 1 << 20, reserveBytes: 0)
                }
                #expect(!FileManager.default.fileExists(atPath: destination.path))
                #expect(try Data(contentsOf: source) == bytes)
            }
        }
    }
}
