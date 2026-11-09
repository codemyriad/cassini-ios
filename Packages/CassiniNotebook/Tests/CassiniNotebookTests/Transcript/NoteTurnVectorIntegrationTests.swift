import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct NoteTurnVectorIntegrationTests {
    @Test(arguments: ["acknowledgment", "competing", "monologue", "overlapping-turns", "brief-reply", "seam-gap"])
    func sealedAndDraftUseViewerRowsAndCanonicalPlayback(_ fixture: String) throws {
        let url = try #require(Bundle.module.url(forResource: fixture + ".words.json", withExtension: nil,
                                                 subdirectory: "interjections"))
        let input = try JSONDecoder().decode(Input.self, from: Data(contentsOf: url))
        let words = input.items
        let note = TranscriptFixtures.note(words.map {
            .init($0.speaker, $0.startMs, $0.endMs, $0.text)
        }, speakers: ["ada", "ben", "cy"].map { NoteSpeaker(id: $0, name: $0.capitalized) })
        let sealed = NoteTranscripts.sealed(note)
        let rows = TurnModel.rows(of: words.map {
            .init(speaker: $0.speaker, startMs: Double($0.startMs), endMs: Double($0.endMs), text: $0.text)
        })
        let tentativeMs: Int64 = 3_600
        let draft = NoteTranscripts.draft(words.map {
            DraftWord(speaker: $0.speaker ?? "", startMs: Int64($0.startMs), endMs: Int64($0.endMs), text: $0.text)
        }, tentativeFromMs: tentativeMs, labels: ["ada": "Ada", "ben": "Ben", "cy": "Cy"])
        for rendered in [sealed, draft] {
            #expect(rendered.turns.count == rows.count)
            for (turn, row) in zip(rendered.turns, rows) {
                let indices = row.members.flatMap(\.wordIndices)
                #expect(turn.id == "w\(indices.min()!)")
                #expect(turn.speakerID == row.speaker)
                #expect(turn.continuation == row.continuation)
                #expect(turn.start == row.startMs / 1000)
                #expect(turn.over.map(\.label) == row.over.map(\.capitalized))
                #expect(turn.words.map(\.sourceIndex) == indices)
                #expect(turn.words.map(\.text) == indices.map { words[$0].text })
                let text = row.members.map { member in
                    member.kind == .interjection
                        ? "(\((member.speaker ?? "").capitalized): \(member.text))" : member.text
                }.joined(separator: " ")
                #expect(turn.text == text)
                for index in turn.words.indices {
                    #expect(String(Array(turn.text)[turn.range(ofWord: index)]) == turn.words[index].text)
                    #expect(turn.word(atOffset: turn.offsets[index]) == index)
                    #expect(rendered.wordStart(.init(turnID: turn.id, index: index)) == turn.words[index].start)
                }
            }
            // Reading order may keep later host words before an earlier competing turn. Audio lookup
            // still picks the latest canonical word start, with canonical order breaking equal-time ties.
            for word in words {
                let at = Double(word.startMs) / 1000
                let expected = words.indices.filter { words[$0].startMs <= word.startMs }.max {
                    words[$0].startMs == words[$1].startMs ? $0 < $1 : words[$0].startMs < words[$1].startMs
                }!
                let ref = try #require(rendered.activeWord(at: at))
                let turn = try #require(rendered.turn(ref.turnID))
                #expect(turn.words[ref.index].sourceIndex == expected)
            }
        }
        for turn in draft.turns {
            #expect(turn.unsettledWordIndices == Set(turn.words.indices.filter {
                words[turn.words[$0].sourceIndex].endMs > tentativeMs
            }))
        }
        if fixture == "acknowledgment" {
            let turn = try #require(sealed.turns.first)
            let chip = try #require(turn.interjections.first)
            #expect(String(Array(turn.text)[chip.textRange]) == "(Ben: Sounds good.)")
            #expect(String(Array(turn.text)[chip.nameRange]) == "Ben")
            #expect(turn.word(atOffset: chip.nameRange.lowerBound) == chip.wordRange.lowerBound)
            let hit = try #require(TranscriptSearch.matches(sealed.turns, query: "sounds good").first)
            #expect(turn.word(atOffset: hit.range.lowerBound) == chip.wordRange.lowerBound)
            #expect(SearchFields(note).body.text == turn.text)
        }
    }

    @Test func unknownRowsKeepUnassignedSpeakerActionsAndViewerContinuation() {
        let note = TranscriptFixtures.note([.init(nil, 0, 200, "First"), .init(nil, 10_000, 10_200, "Later")])
        let turns = NoteTranscripts.sealed(note).turns
        #expect(turns.map(\.speakerID) == [nil, nil])
        #expect(turns.map(\.name) == [.unknown, .unknown])
        #expect(turns.map(\.continuation) == [false, true])
        #expect(turns.allSatisfy { $0.nameableSpeakerID == nil })
    }

    @Test func storedMillisecondsSurviveSecondsAdaptersExactly() {
        let note = TranscriptFixtures.note([.init("ada", 1001, 1013, "Exact")])
        let rows = TranscriptTurns.rows(of: note.transcriptWords)
        #expect(rows.first?.startMs == 1001)
        #expect(rows.first?.endMs == 1013)
        #expect(NoteTranscripts.sealed(note).turns.first?.start == 1.001)
    }

    private struct Input: Decodable {
        var items: [Word]
        struct Word: Decodable {
            var speaker: String?
            var startMs: Int
            var endMs: Int
            var text: String
        }
    }
}
