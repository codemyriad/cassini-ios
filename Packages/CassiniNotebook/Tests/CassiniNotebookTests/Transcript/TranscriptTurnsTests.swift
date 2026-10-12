import Foundation
import Testing
@testable import CassiniNotebook

@Suite struct TranscriptTurnsTests {
    private func w(_ speaker: String, _ startMs: Int, _ endMs: Int, _ text: String) -> TranscriptWord {
        TranscriptWord(speaker: speaker, start: Double(startMs) / 1000, end: Double(endMs) / 1000, text: text)
    }

    // ports: TranscriptTurnsTest#emptyTranscriptHasNoTurns
    @Test func anEmptyTranscriptHasNoTurns() {
        #expect(TranscriptTurns.of([]).isEmpty)
    }

    // ports: TranscriptTurnsTest#turnsAreMaximalRunsOfOneSpeaker
    @Test func turnsAreMaximalRunsOfOneSpeaker() {
        let turns = TranscriptTurns.of([
            w("a", 0, 300, "Sì,"), w("a", 400, 900, "certo."), w("b", 800, 1200, "Bene."),
            w("a", 1500, 1900, "Allora"), w("a", 2000, 2400, "giovedì."),
        ])
        #expect(turns.map(\.speaker) == ["a", "b", "a"])
        #expect(turns.map(\.text) == ["Sì, certo.", "Bene.", "Allora giovedì."])
        #expect(turns.map(\.start) == [0, 0.8, 1.5])
        #expect(turns.map(\.end) == [0.9, 1.2, 2.4])
    }

    // ports: TranscriptTurnsTest#aTurnEndsAtItsLastWordAndKeepsCanonicalOrder
    @Test func aTurnEndsAtItsLastWordAndKeepsTheOrder() {
        let turn = TranscriptTurns.of([w("a", 1000, 3000, "lunga"), w("a", 900, 1500, "breve")])
        #expect(turn.count == 1)
        #expect(turn[0].start == 1.0)
        #expect(turn[0].end == 1.5)
        #expect(turn[0].text == "lunga breve")
    }

    /// iOS: Apple's words carry their own spacing; a full stop given as a word of its own joins the word before.
    @Test func passagesKeepTheirSpacingAndAPassageWithoutTimesIsOneWord() {
        let timed = TranscriptSegment(text: "Hello world.", start: 0, end: 2, speakerID: "a", words: [
            TimedWord(text: "Hello", start: 0, end: 0.5), TimedWord(text: " world", start: 0.6, end: 1.2),
            TimedWord(text: ".", start: 1.2, end: 1.3),
        ])
        let trimmed = TranscriptSegment(text: "Ciao a tutti", start: 2, end: 3, speakerID: "a", words: [
            TimedWord(text: "Ciao", start: 2, end: 2.3), TimedWord(text: "a", start: 2.3, end: 2.4),
            TimedWord(text: "tutti", start: 2.4, end: 3),
        ])
        let plain = TranscriptSegment(text: "  An edited passage. ", start: 3, end: 5, speakerID: "b")
        let words = [timed, trimmed, plain].transcriptWords
        #expect(words.map(\.text) == ["Hello", "world", ".", "Ciao", "a", "tutti", "An edited passage."])
        #expect(words.map(\.segmentID) == [timed.id, timed.id, timed.id, trimmed.id, trimmed.id, trimmed.id, plain.id])
        let turns = TranscriptTurns.of(words)
        #expect(turns.map(\.text) == ["Hello world. Ciao a tutti", "An edited passage."])
        #expect(words.last?.start == 3)
    }
}

@Suite struct SpeakerTintTests {
    // ports: SpeakerTintTest#namedSpeakersCycleBlueTealViolet
    @Test func namedSpeakersCycleBlueTealViolet() {
        let order = ["a", "b", "c", "d", "e"]
        let tints = SpeakerTint.assign(order) { _ in false }
        #expect(order.map { tints[$0] } == [.blue, .teal, .violet, .blue, .teal])
    }

    // ports: SpeakerTintTest#placeholdersAreAmberAndTakeNoSlot
    @Test func placeholdersAreAmberAndTakeNoSlot() {
        let labels = ["s1": "Giulia", "s2": "Speaker 2", "s3": "Paolo Ferri", "s4": "Voce 4", "s5": "Anna"]
        let tints = SpeakerTint.assign(["s1", "s2", "s3", "s4", "s5"], labels: labels)
        #expect(tints == ["s1": .blue, "s2": .amber, "s3": .teal, "s4": .amber, "s5": .violet])
    }

    // ports: SpeakerTintTest#aSpeakerWithoutALabelIsAPlaceholder
    @Test func aSpeakerWithoutALabelIsAPlaceholder() {
        let tints = SpeakerTint.assign(["s1", "s2"], labels: ["s2": "Luca"])
        #expect(tints["s1"] == .amber)
        #expect(tints["s2"] == .blue)
    }

    // ports: SpeakerTintTest#theOrderIsTheGivenFirstTurnOrder
    @Test func theOrderIsTheGivenFirstTurnOrder() {
        let labels = ["a": "Anna", "b": "Bruno"]
        #expect(SpeakerTint.assign(["b", "a"], labels: labels)["b"] == .blue)
        #expect(SpeakerTint.assign(["b", "a"], labels: labels)["a"] == .teal)
    }

    // ports: SpeakerTintTest#theCycleWraps
    @Test func theCycleWraps() {
        #expect(SpeakerTint.named(0) == .blue)
        #expect(SpeakerTint.named(2) == .violet)
        #expect(SpeakerTint.named(3) == .blue)
    }
}
