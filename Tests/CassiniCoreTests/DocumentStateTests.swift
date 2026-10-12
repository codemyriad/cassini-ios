@testable import CassiniCore
import Foundation
import Testing

@Suite struct DocumentStateTests {
    // ports: DocumentStateTest#everyReaderStateHasAType
    @Test func everyReaderStateHasAType() {
        let codes = ["plain-audio", "unknown-cassini-format", "invalid-cassini-metadata", "unverified", "stale-audio", "ok"]
        #expect(codes.compactMap { DocumentState(rawValue: $0)?.code } == codes)
        #expect(DocumentState(rawValue: "ok") == .ok)
        #expect(DocumentState.allCases.map(\.code) == codes + ["unreadable"])
    }

    // ports: DocumentStateTest#aFileThatCannotBeReadIsUnreadableNotPlainAudio
    @Test func aFileThatCannotBeReadIsUnreadableNotPlainAudio() throws {
        try withTemporaryDirectory { dir in
            let missing = dir.appendingPathComponent("gone.opus")
            #expect(CassiniDocument.read(missing).state == .plainAudio)
            let checked = CassiniDocument.readChecked(missing)
            #expect(checked.state == .unreadable)
            #expect(checked.warnings.count == 1 && checked.warnings.allSatisfy { !$0.isEmpty })
            #expect(CassiniDocument.readChecked(dir).state == .unreadable)
        }
    }

    // ports: DocumentStateTest#aReadableFileReadsAsBefore
    @Test func aReadableFileReadsAsBefore() throws {
        try withTemporaryDirectory { dir in
            let wav = dir.appendingPathComponent("audio.wav")
            try Data("RIFF0000WAVE".utf8).write(to: wav)
            #expect(CassiniDocument.readChecked(wav).state == .plainAudio)
            #expect(CassiniDocument.read(wav) == CassiniDocument.readChecked(wav))
            let opus = dir.appendingPathComponent("doc.opus")
            try Data(try CassiniDocument.create(silence(), transcript: Transcript([Word("spk_1", 0, 20, "Ciao")]), title: "Checked",
                                                processing: JSONObject())).write(to: opus)
            #expect(CassiniDocument.readChecked(opus).state == .ok)
        }
    }

    // As Android `AudioFiles.isCassini`: true, false, or nil when the headers or comments do not parse.
    @Test func aFileNamesCassiniOnlyByItsFormatComment() throws {
        try withTemporaryDirectory { dir in
            func file(_ bytes: [UInt8], _ name: String) throws -> URL {
                let url = dir.appendingPathComponent(name)
                try Data(bytes).write(to: url)
                return url
            }
            let document = try CassiniDocument.create(silence(), transcript: Transcript([Word("spk_1", 0, 20, "Ciao")]),
                                                      title: "Named", processing: JSONObject())
            #expect(try CassiniDocument.namesCassiniFormat(file(document, "doc.opus")) == true)
            #expect(try CassiniDocument.namesCassiniFormat(file(silence(["cassini_format=x"]), "lower.opus")) == true)
            #expect(try CassiniDocument.namesCassiniFormat(file(silence(["CASSINI_PROFILE=ogg-opus"]), "plain.opus")) == false)
            // A vendor length past the end of the OpusTags packet: the comments cannot be read.
            let broken = Array("OpusTags".utf8) + [0xFF, 0xFF, 0xFF, 0x7F]
            let stream = OggOpus.Stream(head: opusHead, tags: broken, audio: [[0xF8, 0xFF, 0xFE]], finalGranule: 960, validFraming: true)
            #expect(try CassiniDocument.namesCassiniFormat(file(OggOpus.mux(stream, tags: broken), "broken.opus")) == nil)
            #expect(try CassiniDocument.namesCassiniFormat(file(Array("RIFF0000WAVE".utf8), "audio.wav")) == nil)
            #expect(throws: (any Error).self) { try CassiniDocument.namesCassiniFormat(dir.appendingPathComponent("gone.opus")) }
        }
    }
}
