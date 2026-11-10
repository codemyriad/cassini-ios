import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct TranscriptRenderInputTests {
    private func transcript() -> NoteTranscript {
        var note = Note(title: "Long", audioFilename: "audio.caf")
        note.speakers = [NoteSpeaker(id: "a", name: "Ada"), NoteSpeaker(id: "b", name: "Bruno")]
        note.transcript = (0..<180).map { passage in
            let start = Double(passage * 60)
            let words = (0..<120).map { index in
                TimedWord(text: index == 119 ? "end." : "word\(index)",
                          start: start + Double(index) * 0.5, end: start + Double(index) * 0.5 + 0.4)
            }
            return TranscriptSegment(text: words.map(\.text).joined(separator: " "), start: start, end: start + 60,
                                     speaker: passage % 2 == 0 ? "Ada" : "Bruno",
                                     speakerID: passage % 2 == 0 ? "a" : "b", words: words)
        }
        return NoteTranscripts.sealed(note)
    }

    @Test func aTickChangesOnlyTheOldAndNewActiveParagraphInputs() throws {
        let transcript = transcript()
        #expect(transcript.turns.count == 180)
        let first = transcript.turns[0].id, second = transcript.turns[1].id
        let last = transcript.turns[179].id
        var previous = transcript.turns.map { TurnRenderInput(turn: $0) }
        // Same-word ticks, crossings, backward seeks, offscreen paragraphs and clearing playback.
        let steps: [(Double?, Set<String>)] = [
            (1.6, [first]), (1.75, []), (2.1, [first]), (60.1, [first, second]),
            (60.2, []), (1.6, [first, second]), (179 * 60 + 1.6, [first, last]),
            (nil, [last]), (nil, [])
        ]
        for (position, expected) in steps {
            let active = position.flatMap { transcript.activeWord(at: $0) }
            let next = transcript.turns.map { TurnRenderInput(turn: $0, activeWord: active) }
            let changed = Set(zip(previous, next).compactMap { $0 == $1 ? nil : $1.turn.id })
            #expect(changed == expected, "position \(String(describing: position)) changed \(changed), expected \(expected)")
            previous = next
        }
    }

    @Test func inlineAndUnorderedWordsKeepTheParagraphLocalIndex() throws {
        let vector = try D84IntegrationVector.load("acknowledgment")
        var note = Note(title: "Inline words")
        note.transcript = TranscriptSegment.segments(of: vector.words)
        let transcript = NoteTranscripts.sealed(note)
        #expect(transcript.turns.contains { !$0.interjections.isEmpty })
        for turn in transcript.turns {
            for index in turn.words.indices {
                let active = WordRef(turnID: turn.id, index: index)
                for other in transcript.turns {
                    let input = TurnRenderInput(turn: other, activeWord: active)
                    #expect(input.activeIndex == (other.id == turn.id ? index : nil))
                }
            }
        }
    }

    @Test func contentAndPresentationChangesInvalidateTheComparedInput() throws {
        let turn = try #require(transcript().turns.first)
        let original = TurnRenderInput(turn: turn)
        var variants: [TurnRenderInput] = []
        var changed = original; changed.matches = [0..<4]; variants.append(changed)
        changed = original; changed.currentMatch = 0..<4; variants.append(changed)
        changed = original; changed.style = .draft; variants.append(changed)
        changed = original; changed.renamable = false; variants.append(changed)
        changed = original; changed.turn = turn.with(unsettledWordIndices: [1]); variants.append(changed)
        for variant in variants { #expect(variant != original) }
        // The same canonical words with a renamed speaker must also refresh the header and inline labels.
        var note = Note(title: "Rename", audioFilename: "audio.caf")
        note.speakers = [NoteSpeaker(id: "a", name: "Ada")]
        note.transcript = [.init(text: "Hello.", start: 0, end: 1, speakerID: "a")]
        let before = try #require(NoteTranscripts.sealed(note).turns.first)
        note.speakers?[0].name = "Adele"
        let after = try #require(NoteTranscripts.sealed(note).turns.first)
        #expect(before.id == after.id)
        #expect(TurnRenderInput(turn: before) != TurnRenderInput(turn: after))
    }
}
