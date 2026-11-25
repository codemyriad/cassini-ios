import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct BookmarkPreviewTests {
    typealias F = TranscriptFixtures

    @Test func emptyTranscriptReturnsNil() {
        #expect(NoteTranscript.empty.bookmarkPreview(at: 5.0) == nil)
    }

    @Test func findsSpeakerAndWordsAtTime() {
        let note = F.note([
            F.W("a", 1_000, 1_300, "Good"),
            F.W("a", 1_400, 1_800, "morning"),
            F.W("a", 1_900, 2_300, "everyone"),
            F.W("a", 2_400, 2_600, "let"),
            F.W("a", 2_700, 2_900, "us"),
            F.W("a", 3_000, 3_400, "start"),
            F.W("b", 5_000, 5_400, "Sounds"),
            F.W("b", 5_500, 5_800, "good"),
            F.W("b", 5_900, 6_000, "to"),
            F.W("b", 6_100, 6_400, "me"),
        ], speakers: [
            NoteSpeaker(id: "a", name: "Alex"),
            NoteSpeaker(id: "b", name: "Sam"),
        ])
        let transcript = NoteTranscripts.sealed(note, voices: [], suggestions: [])

        let atFirst = transcript.bookmarkPreview(at: 1.5)
        #expect(atFirst?.speaker == .named("Alex"))
        #expect(atFirst?.words == "morning everyone let us start")

        let atSecond = transcript.bookmarkPreview(at: 5.6)
        #expect(atSecond?.speaker == .named("Sam"))
        #expect(atSecond?.words == "good to me")

        let beforeFirst = transcript.bookmarkPreview(at: 0.2)
        #expect(beforeFirst?.speaker == .named("Alex"))
        #expect(beforeFirst?.words.hasPrefix("Good morning") == true)
    }

    @Test func longTranscriptLookupScalesNearLinearly() throws {
        let count = 20_000
        let words = (0..<count).map { i in
            F.W("a", i * 500, i * 500 + 400, "word\(i)")
        }
        let note = F.note(words, speakers: [NoteSpeaker(id: "a", name: "Alex")])
        let transcript = NoteTranscripts.sealed(note, voices: [], suggestions: [])
        let (_, elapsed) = try measureThreadCPU {
            for probe in stride(from: 0, to: count, by: 20) {
                let preview = transcript.bookmarkPreview(at: Double(probe) * 0.5 + 0.1)
                #expect(preview?.speaker == .named("Alex"))
                #expect(preview?.words.hasPrefix("word\(probe)") == true)
            }
        }
        #expect(elapsed < .seconds(1), "1000 bookmark previews over 20k words should be well under 1 s CPU time")
    }
}
