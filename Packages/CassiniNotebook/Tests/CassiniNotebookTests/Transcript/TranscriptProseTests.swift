import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct TranscriptProseTests {
    private func acknowledgment() throws -> NoteTurn {
        let vector = try D84IntegrationVector.load("acknowledgment")
        let segments = TranscriptSegment.segments(of: vector.words)
        var note = Note(title: "Weekly check-in")
        note.transcript = segments
        note.speakers = [NoteSpeaker(id: "ada", name: "Ada"), NoteSpeaker(id: "ben", name: "Ben")]
        return try #require(NoteTranscripts.sealed(note).turns.first)
    }

    private func link(at offset: Int, in prose: AttributedString) -> URL? {
        let characters = prose.characters
        let start = characters.index(characters.startIndex, offsetBy: offset)
        return prose[start..<characters.index(after: start)].link
    }

    @Test func chipPrefixWordsAndSuffixUseTheirOwnSeekTargets() throws {
        let turn = try acknowledgment(), chip = try #require(turn.interjections.first)
        let prose = turn.linkedText()
        #expect(String(prose.characters) == turn.text)
        let first = chip.wordRange.lowerBound, last = chip.wordRange.upperBound - 1
        for offset in chip.textRange.lowerBound..<turn.offsets[first] {
            #expect(link(at: offset, in: prose) == URL(string: "cassini-word:\(first)"))
            #expect(turn.word(atOffset: offset) == first)
        }
        for index in chip.wordRange {
            for offset in turn.range(ofWord: index) {
                #expect(link(at: offset, in: prose) == URL(string: "cassini-word:\(index)"))
            }
        }
        for offset in turn.range(ofWord: last).upperBound..<chip.textRange.upperBound {
            #expect(link(at: offset, in: prose) == URL(string: "cassini-word:\(last)"))
        }
    }

    @Test func activeChipAtomHasNoLinkToOverrideItsHighlight() throws {
        let turn = try acknowledgment(), chip = try #require(turn.interjections.first)
        for active in chip.wordRange {
            let prose = turn.linkedText(activeWord: active)
            for offset in turn.range(ofWord: active) { #expect(link(at: offset, in: prose) == nil) }
            // Label and suffix remain seekable even while their target word is active.
            #expect(link(at: chip.nameRange.lowerBound, in: prose)
                    == URL(string: "cassini-word:\(chip.wordRange.lowerBound)"))
            #expect(link(at: chip.textRange.upperBound - 1, in: prose)
                    == URL(string: "cassini-word:\(chip.wordRange.upperBound - 1)"))
            for other in chip.wordRange where other != active {
                #expect(link(at: turn.offsets[other], in: prose) == URL(string: "cassini-word:\(other)"))
            }
        }
    }
}
