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
}
