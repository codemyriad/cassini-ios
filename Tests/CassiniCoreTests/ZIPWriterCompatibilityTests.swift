import Foundation
import Testing
@testable import CassiniCore

@Suite struct ZIPWriterCompatibilityTests {
    @Test(arguments: [ZIPWriterFixtures.ditto, ZIPWriterFixtures.sevenZip])
    func realMacWritersKeepUnicodeNamesAndPassStrictHeaderChecks(_ data: Data) throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("writer.zip")
            try data.write(to: url)
            let zip = try ZIPArchive(url: url)
            let audio = zip.entries.filter { $0.isFile && !$0.isMetadata }
            #expect(audio.map(\.name) == ["café.opus", "naïve.wav", "東京.wav"])
            #expect(zip.entries.contains { $0.isDirectory })
            for entry in zip.entries {
                var output = Data()
                try zip.read(entry, remainingBytes: 10_000) { output.append($0) }
                if entry.isDirectory { #expect(output.isEmpty) }
                else if !entry.isMetadata { #expect(output == Data("audio".utf8)) }
            }
            if data == ZIPWriterFixtures.ditto {
                #expect(zip.entries.contains { $0.isMetadata && !$0.isDirectory && $0.name == "._café.opus" })
            }
        }
    }

    @Test func unflaggedUTF8WinsAndLegacyCP437StillWorksInBothHeaders() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("names.zip")
            for (raw, expected) in [(Data("café.opus".utf8), "café.opus"),
                                    (Data("東京.wav".utf8), "東京.wav"),
                                    (Data([0x63, 0x61, 0x66, 0x82]) + Data(".opus".utf8), "café.opus")] {
                var member = ZIPAgyFixture.Member("unused", Data("audio".utf8))
                member.rawName = raw; member.flags = 0
                try ZIPAgyFixture.write([member], to: url)
                let zip = try ZIPArchive(url: url)
                #expect(zip.entries.map(\.name) == [expected])
                var output = Data()
                try zip.read(try #require(zip.entries.first), remainingBytes: 10) { output.append($0) }
                #expect(output == Data("audio".utf8))
            }
            var member = ZIPAgyFixture.Member("café.opus", Data())
            member.localFlags = 0 // The central header explicitly requests UTF-8; the local one does not.
            try ZIPAgyFixture.write([member], to: url)
            #expect(try ZIPArchive(url: url).entries.map(\.name) == ["café.opus"])
        }
    }

    @Test func flaggedInvalidUTF8NeverFallsBackAndUnflaggedPathsStayChecked() throws {
        try withTemporaryDirectory { folder in
            let url = folder.appendingPathComponent("names.zip")
            for flags: (UInt16, UInt16) in [(0x800, 0), (0, 0x800)] {
                var member = ZIPAgyFixture.Member("unused", Data())
                member.rawName = Data([0x63, 0x61, 0x66, 0x82]) + Data(".opus".utf8)
                member.flags = flags.0; member.localFlags = flags.1
                try ZIPAgyFixture.write([member], to: url)
                #expect(throws: ZIPFailure.damaged) { try ZIPArchive(url: url) }
            }
            var unsafe = ZIPAgyFixture.Member("../café.opus", Data())
            unsafe.flags = 0
            try ZIPAgyFixture.write([unsafe], to: url)
            #expect(throws: ZIPFailure.unsafePaths) { try ZIPArchive(url: url) }
        }
    }
}

/// Real writer output, not ZIPArchive/StoredZIPWriter output. Every audio-named file contains only "audio".
/// Generated on macOS with three files under meetings/: café.opus, naïve.wav, 東京.wav.
/// ditto: /usr/bin/ditto -c -k --sequesterRsrc --keepParent meetings finder-ditto.zip
/// The café file has a synthetic FinderInfo attribute, producing a genuine __MACOSX AppleDouble sidecar.
/// macOS 27.2.1 (26B131); 7-Zip 26.06: 7zz a -tzip sevenzip.zip meetings (default options).
/// Keep original local/central extras and encoding flags: these bytes exercise real-writer compatibility.
private enum ZIPWriterFixtures {
    static let ditto = Data(base64Encoded: """
        UEsDBAoAAAAAAAAIbF0AAAAAAAAAAAAAAAAJABAAbWVldGluZ3MvVVgMAIAB9WqAAfVq9QEUAFBLAwQUAAgACAAACGxdAAAAAAAA
        AAAAAAAAEwAQAG1lZXRpbmdzL2NhZsOpLm9wdXNVWAwAgAH1aoAB9Wr1ARQASyxNycwHAFBLBwiVNn0YBwAAAAUAAABQSwMECgAA
        AAAAuUhsXQAAAAAAAAAAAAAAAAkAEABfX01BQ09TWC9VWAwAXnP1al5z9Wr1ARQAUEsDBAoAAAAAALlIbF0AAAAAAAAAAAAAAAAS
        ABAAX19NQUNPU1gvbWVldGluZ3MvVVgMAF5z9Wpec/Vq9QEUAFBLAwQUAAgACAAACGxdAAAAAAAAAAAAAAAAHgAQAF9fTUFDT1NY
        L21lZXRpbmdzLy5fY2Fmw6kub3B1c1VYDACAAfVqgAH1avUBFABjYBVjZ2BiYPBNTFbwD1aIUIACkBgDJxAbAbEbEIP4FUDMEOIa
        EVJSUlHCgBM4hoQEQZkVMF3oAABQSwcIT0n0bDkAAAB4AAAAUEsDBBQACAAIAAAIbF0AAAAAAAAAAAAAAAATABAAbWVldGluZ3Mv
        bmHDr3ZlLndhdlVYDACAAfVqgAH1avUBFABLLE3JzAcAUEsHCJU2fRgHAAAABQAAAFBLAwQUAAgACAAACGxdAAAAAAAAAAAAAAAA
        EwAQAG1lZXRpbmdzL+adseS6rC53YXZVWAwAgAH1aoAB9Wr1ARQASyxNycwHAFBLBwiVNn0YBwAAAAUAAABQSwECFQMKAAAAAAAA
        CGxdAAAAAAAAAAAAAAAACQAMAAAAAAAAAABA7UEAAAAAbWVldGluZ3MvVVgIAIAB9WqAAfVqUEsBAhUDFAAIAAgAAAhsXZU2fRgH
        AAAABQAAABMADAAAAAAAAAAAQKSBNwAAAG1lZXRpbmdzL2NhZsOpLm9wdXNVWAgAgAH1aoAB9WpQSwECFQMKAAAAAAC5SGxdAAAA
        AAAAAAAAAAAACQAMAAAAAAAAAABA/UGPAAAAX19NQUNPU1gvVVgIAF5z9Wpec/VqUEsBAhUDCgAAAAAAuUhsXQAAAAAAAAAAAAAA
        ABIADAAAAAAAAAAAQP1BxgAAAF9fTUFDT1NYL21lZXRpbmdzL1VYCABec/VqXnP1alBLAQIVAxQACAAIAAAIbF1PSfRsOQAAAHgA
        AAAeAAwAAAAAAAAAAECkgQYBAABfX01BQ09TWC9tZWV0aW5ncy8uX2NhZsOpLm9wdXNVWAgAgAH1aoAB9WpQSwECFQMUAAgACAAA
        CGxdlTZ9GAcAAAAFAAAAEwAMAAAAAAAAAABApIGbAQAAbWVldGluZ3MvbmHDr3ZlLndhdlVYCACAAfVqgAH1alBLAQIVAxQACAAI
        AAAIbF2VNn0YBwAAAAUAAAATAAwAAAAAAAAAAECkgfMBAABtZWV0aW5ncy/mnbHkuqwud2F2VVgIAIAB9WqAAfVqUEsFBgAAAAAH
        AAcAEQIAAEsCAAAAAA==
        """, options: .ignoreUnknownCharacters)!
    static let sevenZip = Data(base64Encoded: """
        UEsDBBQAAAAAAAAIbF0AAAAAAAAAAAAAAAAJAAAAbWVldGluZ3MvUEsDBAoAAAgAAAAIbF2VNn0YBQAAAAUAAAATAAAAbWVldGlu
        Z3MvY2Fmw6kub3B1c2F1ZGlvUEsDBAoAAAgAAAAIbF2VNn0YBQAAAAUAAAATAAAAbWVldGluZ3MvbmHDr3ZlLndhdmF1ZGlvUEsD
        BAoAAAgAAAAIbF2VNn0YBQAAAAUAAAATAAAAbWVldGluZ3Mv5p2x5LqsLndhdmF1ZGlvUEsBAj8DFAAAAAAAAAhsXQAAAAAAAAAA
        AAAAAAkAJAAAAAAAAAAQgO1BAAAAAG1lZXRpbmdzLwoAIAAAAAAAAQAYAABAoMI4ct0BAAAAAAAAAAAAAAAAAAAAAFBLAQI/AwoA
        AAgAAAAIbF2VNn0YBQAAAAUAAAATACQAAAAAAAAAIICkgScAAABtZWV0aW5ncy9jYWbDqS5vcHVzCgAgAAAAAAABABgAAECgwjhy
        3QEAAAAAAAAAAAAAAAAAAAAAUEsBAj8DCgAACAAAAAhsXZU2fRgFAAAABQAAABMAJAAAAAAAAAAggKSBXQAAAG1lZXRpbmdzL25h
        w692ZS53YXYKACAAAAAAAAEAGAAAQKDCOHLdAQAAAAAAAAAAAAAAAAAAAABQSwECPwMKAAAIAAAACGxdlTZ9GAUAAAAFAAAAEwAk
        AAAAAAAAACCApIGTAAAAbWVldGluZ3Mv5p2x5LqsLndhdgoAIAAAAAAAAQAYAABAoMI4ct0BAAAAAAAAAAAAAAAAAAAAAFBLBQYA
        AAAABAAEAIoBAADJAAAAAAA=
        """, options: .ignoreUnknownCharacters)!
}
