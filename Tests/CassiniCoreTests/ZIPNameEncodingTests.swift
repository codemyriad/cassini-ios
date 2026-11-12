import Foundation
import CryptoKit
import CZlib
import Testing
@testable import CassiniCore

@Suite struct ZIPNameEncodingTests {
    private let payload = Data("English sample".utf8)
    private let utf8 = Data("café.wav".utf8)
    private let cp437 = Data([0x63, 0x61, 0x66, 0x82, 0x2e, 0x77, 0x61, 0x76])

    private func member(_ raw: Data, flags: UInt16 = 0, localFlags: UInt16? = nil) -> ZIPAgyFixture.Member {
        var m = ZIPAgyFixture.Member("unused", payload)
        m.rawName = raw; m.flags = flags; m.localFlags = localFlags
        return m
    }

    private func read(_ archive: ZIPArchive, named name: String) throws -> Data {
        let entry = try #require(archive.entries.first { $0.name == name && $0.isFile })
        var result = Data()
        try archive.read(entry, remainingBytes: 1_000) { result.append($0) }
        return result
    }

    @Test func realUnflaggedDittoFixtureKeepsItsUnicodeNameAndPayload() throws {
        let url = try #require(Bundle.module.url(forResource: "finder-ditto-android", withExtension: "zip", subdirectory: "zip"))
        let data = try Data(contentsOf: url)
        #expect(data.count == 460)
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() ==
                "273cb72f566c6d17dc77e308c76e8ef80b99f0cfb0a9c54a2786011e9087ed4f")
        let archive = try ZIPArchive(url: url)
        #expect(archive.entries.filter { $0.isFile && !$0.isMetadata }.map(\.name) == ["Notes/café.opus"])
        #expect(try read(archive, named: "Notes/café.opus") == Data("audio".utf8))
    }

    @Test func unflaggedNamesAcceptUTF8AndGenuineLegacyCP437() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("names.zip")
            for raw in [utf8, cp437] {
                try ZIPAgyFixture.write([member(raw)], to: url)
                let archive = try ZIPArchive(url: url)
                #expect(archive.entries.map(\.name) == ["café.wav"])
                #expect(try read(archive, named: "café.wav") == payload)
            }
        }
    }

    @Test func validUTF8NamesAllowDifferentHarmlessEncodingFlags() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("flags.zip")
            for flags: (UInt16, UInt16) in [(0, 0x800), (0x800, 0), (0x800, 0x800)] {
                try ZIPAgyFixture.write([member(utf8, flags: flags.0, localFlags: flags.1)], to: url)
                let archive = try ZIPArchive(url: url)
                #expect(archive.entries.map(\.name) == ["café.wav"])
                #expect(try read(archive, named: "café.wav") == payload)
            }
        }
    }

    @Test func flaggedInvalidUTF8IsRefusedInEitherHeader() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("invalid.zip")
            for flags: (UInt16, UInt16) in [(0x800, 0), (0, 0x800), (0x800, 0x800)] {
                try ZIPAgyFixture.write([member(cp437, flags: flags.0, localFlags: flags.1)], to: url)
                #expect(throws: ZIPFailure.damaged) { try ZIPArchive(url: url) }
            }
        }
    }

    @Test func equalDecodedNamesStillRequireEqualRawHeaderBytes() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("disagreement.zip")
            var m = member(utf8)
            m.localRawName = cp437
            try ZIPAgyFixture.write([m], to: url)
            #expect(throws: ZIPFailure.damaged) { try ZIPArchive(url: url) }
        }
    }

    @Test func UTF8GuessDoesNotBypassUnsafePathsOrFinderClassification() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("paths.zip")
            for path in ["../café.wav", "/café.wav", "C:/café.wav", "folder/../café.wav"] {
                try ZIPAgyFixture.write([member(Data(path.utf8))], to: url)
                #expect(throws: ZIPFailure.unsafePaths) { try ZIPArchive(url: url) }
            }
            try ZIPAgyFixture.write([member(Data("__MACOSX/café.wav".utf8))], to: url)
            let archive = try ZIPArchive(url: url)
            #expect(archive.entries.count == 1 && archive.entries[0].isMetadata)
        }
    }

    @Test func unicodeExtraPresenceAndDecodedIdentityRemainStrict() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("unicode-extra.zip")
            var extra = Data(); extra.zip16(0x7075); extra.zip16(UInt16(5 + utf8.count)); extra.append(1)
            let crc = utf8.withUnsafeBytes { UInt32(CZlib.crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(utf8.count))) }
            extra.zip32(crc); extra.append(utf8)
            for present in [(true, true), (true, false), (false, true)] {
                var m = member(utf8)
                if present.0 { m.extra = extra }
                if present.1 { m.localExtra = extra }
                try ZIPAgyFixture.write([m], to: url)
                if present.0 && present.1 {
                    let archive = try ZIPArchive(url: url)
                    #expect(try read(archive, named: "café.wav") == payload)
                } else {
                    #expect(throws: ZIPFailure.damaged) { try ZIPArchive(url: url) }
                }
            }
        }
    }
}
