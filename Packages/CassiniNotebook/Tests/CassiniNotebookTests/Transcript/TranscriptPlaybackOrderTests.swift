import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct TranscriptPlaybackOrderTests {
    /// Canonical item order is not chronological: the first atom is last in the audio, and
    /// atoms 1 and 2 have the same start. Exercise the index consumed by ReadingTranscript,
    /// then the Note screen's real word-tap command rather than a separate test-only lookup.
    @Test func unorderedCanonicalWordsAndEqualStartsKeepPlaybackAndTapTargets() throws {
        let words: [TranscriptFixtures.W] = [
            .init("ada", 1000, 1200, "Later"),
            .init("ben", 0, 200, "First"),
            .init("cy", 0, 300, "Together"),
            .init("ada", 500, 700, "Middle")
        ]
        let note = TranscriptFixtures.note(words)
        #expect(note.transcriptWords.map(\.text) == ["Later", "First", "Together", "Middle"])
        let sealed = NoteTranscripts.sealed(note)
        let draft = NoteTranscripts.draft(words.map {
            DraftWord(speaker: $0.speaker ?? "", startMs: Int64($0.startMs), endMs: Int64($0.endMs), text: $0.text)
        }, tentativeFromMs: nil)
        for transcript in [sealed, draft] {
            #expect(transcript.activeWord(at: -0.001) == nil)
            // Equal starts choose the last canonical atom, irrespective of display/turn order.
            let cases: [(TimeInterval, Int)] = [(0, 2), (0.499, 2), (0.5, 3), (0.999, 3), (1, 0), (2, 0)]
            for (position, expectedSource) in cases {
                let active = try #require(transcript.activeWord(at: position))
                let turn = try #require(transcript.turn(active.turnID))
                #expect(turn.words[active.index].sourceIndex == expectedSource)
                #expect(turn.words[active.index].text == words[expectedSource].text)
            }
            // Every displayed atom still seeks to its own source time, including the equal-start
            // atom that is not chosen as active and the earliest canonical atom rendered last.
            for turn in transcript.turns {
                for index in turn.words.indices {
                    let source = turn.words[index].sourceIndex
                    var screen = NoteScreenState()
                    screen.follow.dragged(playing: true)
                    #expect(!screen.follow.following)
                    let effect = screen.wordTapped(.init(turnID: turn.id, index: index), in: transcript)
                    #expect(effect == .seekAndPlay(Double(words[source].startMs) / 1000))
                    #expect(screen.follow.following)
                }
            }
        }
    }
}
