import Foundation
import Testing
import CassiniNotebook

@Suite struct ImportTitlesTests {
    // ports: ImportRepositoryTest#titlesAndExtensionsFollowTheDisplayName
    @Test func titlesAndExtensionsFollowTheDisplayName() {
        #expect(ImportTitles.title(displayName: "Meeting.final.MP3") == "Meeting.final")
        #expect(ImportTitles.title(displayName: ".opus") == ".opus")
        #expect(ImportTitles.title(displayName: "  meeting  ") == "meeting")
        #expect(ImportTitles.title(displayName: nil) == ImportTitles.fallbackTitle)
        #expect(ImportTitles.title(displayName: "   ") == ImportTitles.fallbackTitle)
        #expect(ImportTitles.title(displayName: nil, fallback: "Imported audio") == "Imported audio")
        #expect(ImportTitles.title(displayName: String(repeating: "x", count: 300) + ".mp3").count == 200)
        #expect(ImportTitles.fileExtension(displayName: "Meeting.final.MP3", content: "mp3") == "mp3")
        #expect(ImportTitles.fileExtension(displayName: "voice", content: "m4a") == "m4a")
        #expect(ImportTitles.fileExtension(displayName: "a.opus", content: "mp3") == "mp3")
        #expect(ImportTitles.fileExtension(displayName: "a.tmp", content: "mp3") == "mp3")
        #expect(ImportTitles.fileExtension(displayName: "a.toolong", content: nil) == "bin")
        #expect(ImportTitles.fileExtension(displayName: nil, content: nil) == "bin")
    }

    @Test func anExtensionOutsideTheAllowedLettersIsNotUsed() {
        #expect(ImportTitles.fileExtension(displayName: "memo.m-4a", content: "m4a") == "m4a")
        #expect(ImportTitles.fileExtension(displayName: "memo.", content: "wav") == "wav")
        #expect(ImportTitles.fileExtension(displayName: "memo.wav", content: "wav") == "wav")
        #expect(ImportTitles.fileExtension(displayName: "memo.M4A", content: nil) == "m4a")
    }
}

@Suite struct ImportClassifierTests {
    private func bytes(_ text: String, padTo count: Int = 16) -> [UInt8] {
        Array(text.utf8) + [UInt8](repeating: 0, count: max(0, count - text.utf8.count))
    }

    @Test func containersAreKnownByTheirFirstBytes() {
        #expect(ImportClassifier.sniff(bytes("RIFF\0\0\0\0WAVEfmt ")) == .other(fileExtension: "wav"))
        #expect(ImportClassifier.sniff(bytes("FORM\0\0\0\0AIFF")) == .other(fileExtension: "aiff"))
        #expect(ImportClassifier.sniff(bytes("caff")) == .other(fileExtension: "caf"))
        #expect(ImportClassifier.sniff(bytes("fLaC")) == .other(fileExtension: "flac"))
        #expect(ImportClassifier.sniff(bytes("\0\0\0\u{20}ftypM4A ")) == .other(fileExtension: "m4a"))
        #expect(ImportClassifier.sniff(bytes("\0\0\0\u{20}ftyp3gp4")) == .other(fileExtension: "3gp"))
        #expect(ImportClassifier.sniff(bytes("ID3\u{4}")) == .other(fileExtension: "mp3"))
        #expect(ImportClassifier.sniff([0xFF, 0xFB, 0x90, 0x64]) == .other(fileExtension: "mp3"))
        #expect(ImportClassifier.sniff([0xFF, 0xF1, 0x50, 0x80]) == .other(fileExtension: "aac"))
        #expect(ImportClassifier.sniff(bytes("#!AMR\n")) == .other(fileExtension: "amr"))
        #expect(ImportClassifier.sniff(bytes("not audio at all")) == .other(fileExtension: nil))
        #expect(ImportClassifier.sniff([]) == .other(fileExtension: nil))
    }

    @Test func oggOpusIsToldApartFromOtherOgg() throws {
        let opus = try PortableFixtures.silence(packets: 1)
        #expect(ImportClassifier.sniff(Array(opus.prefix(ImportClassifier.sniffBytes))) == .oggOpus)
        var vorbis = Array(opus.prefix(ImportClassifier.sniffBytes))
        vorbis.replaceSubrange(28..<36, with: Array("\u{1}vorbis\0".utf8))
        #expect(ImportClassifier.sniff(vorbis) == .other(fileExtension: "ogg"))
    }
}
