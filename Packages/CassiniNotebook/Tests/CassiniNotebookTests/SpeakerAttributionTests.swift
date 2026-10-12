import Foundation
import Testing
@testable import CassiniNotebook

/// Android's SpeakerAttributionTest and DiarizationTest, for passages: iOS keeps the transcript in note.json and
/// attributes passages, so the document cases become the ids and words of the passages.
@Suite struct SpeakerAttributionTests {
    func word(_ start: Double, _ end: Double, _ text: String = "w ") -> TimedWord { TimedWord(text: text, start: start, end: end) }
    func passage(_ words: [TimedWord]) -> TranscriptSegment {
        TranscriptSegment(text: words.map(\.text).joined().trimmingCharacters(in: .whitespaces), start: words.first?.start ?? 0,
                          end: words.last?.end ?? 0, words: words)
    }
    func turn(_ start: Double, _ end: Double, _ speaker: String) -> SpeakerTurn { SpeakerTurn(speakerID: speaker, start: start, end: end) }
    func speakers(_ transcript: [TranscriptSegment]) -> [String?] { transcript.flatMap { s in s.words.map { _ in s.speakerID } } }

    // ports: SpeakerAttributionTest#derivingLabelsKeepsASRProvenanceAndWordClock
    @Test func attributionKeepsTheWordsTheirTextAndTheirClock() {
        let words = [word(0, 1, "Hello "), word(1, 2, "Sam. "), word(2, 3, "Hi!")]
        let output = SpeakerAttribution.assign([passage(words)], turns: [turn(0, 1.8, "a"), turn(1.8, 3, "b")])
        #expect(output.map(\.speakerID) == ["a", "b"])
        #expect(output.flatMap(\.words) == words)
        #expect(output.map(\.text) == ["Hello Sam.", "Hi!"])
    }

    /// Stable ids: the first piece of a split passage keeps its id, later pieces get the same derived id every time.
    @Test func aSplitPassageKeepsItsIdAndRerunsGiveTheSameIds() {
        let source = passage([word(0, 1), word(1, 2), word(2, 3)])
        let turns = [turn(0, 1, "a"), turn(1, 2, "b"), turn(2, 3, "a")]
        let first = SpeakerAttribution.assign([source], turns: turns)
        #expect(first.count == 3)
        #expect(first[0].id == source.id)
        #expect(Set(first.map(\.id)).count == 3)
        #expect(SpeakerAttribution.assign([source], turns: turns).map(\.id) == first.map(\.id))
    }

    /// A passage spoken by one speaker is kept as it is, edited text and all.
    @Test func aPassageOfOneSpeakerKeepsItsIdAndItsEditedText() {
        var edited = passage([word(0, 1), word(1, 2)])
        edited.text = "Edited by hand"
        let output = SpeakerAttribution.assign([edited], turns: [turn(0, 5, "a")])
        #expect(output == [{ var s = edited; s.speakerID = "a"; return s }()])
    }

    // ports: SpeakerAttributionTest#eachPassHasItsOwnAnonymousSpeakerIds
    @Test func eachPassHasItsOwnAnonymousSpeakerIds() {
        let turns = [turn(0, 1, "S1"), turn(1, 2, "S2")]
        let prints = [SpeakerPrint(speakerID: "S1", model: "m", vector: [1], speechSeconds: 8)]
        let first = SpeakerAttribution.namespaced(turns: turns, prints: prints, prefix: UUID().uuidString + "_")
        let second = SpeakerAttribution.namespaced(turns: turns, prints: prints, prefix: UUID().uuidString + "_")
        #expect(Set(first.turns.map(\.speakerID)).isDisjoint(with: second.turns.map(\.speakerID)))
        #expect(first.prints[0].speakerID == first.turns[0].speakerID)
    }

    // ports: SpeakerAttributionTest#emptyOrInvalidDetectionsCannotReplaceTheTranscript
    @Test func emptyOrInvalidDetectionsCannotReplaceTheTranscript() {
        var note = Note(title: "Conversation")
        note.transcript = [passage([word(0, 1)])]
        let before = note
        for bad in [[], [turn(10, 0, "a")], [turn(.nan, 1, "a")]] {
            var copy = note
            copy.applySpeakerAnalysis(turns: bad, matches: [:], voiceNames: [:], autoName: false, stamp: VersionStamp(date: .now))
            #expect(copy.transcript == before.transcript)
            #expect(copy.speakers == before.speakers)
            #expect(copy.versions == nil)
            #expect(copy.speakerAnalysisFailure == .empty)
        }
    }

    // ports: DiarizationTest#majorityOverlapWinsAndIdsFollowFirstAppearance
    @Test func majorityOverlapWins() {
        let output = SpeakerAttribution.assign([passage([word(0.1, 0.4), word(0.9, 1.3), word(1.1, 1.5)])],
                                               turns: [turn(0, 1, "x7"), turn(1, 2, "x3")])
        #expect(speakers(output) == ["x7", "x3", "x3"])
    }

    // ports: DiarizationTest#aWordInAGapTakesTheNearestTurn
    @Test func aWordInAGapTakesTheNearestTurn() {
        let output = SpeakerAttribution.assign([passage([word(1.1, 1.2), word(1.7, 1.8)])], turns: [turn(0, 1, "a"), turn(2, 3, "b")])
        #expect(speakers(output) == ["a", "b"])
    }

    // ports: DiarizationTest#noValidTurnsLeavesTheWordsAlone
    @Test func noValidTurnsLeavesTheWordsAlone() {
        let transcript = [passage([word(0, 0.01)])]
        #expect(SpeakerAttribution.assign(transcript, turns: []) == transcript)
        #expect(SpeakerAttribution.assign(transcript, turns: [turn(-1, 0.01, "a"), turn(0.01, 0, "b"), turn(0, 0, "b")]) == transcript)
    }

    // ports: DiarizationTest#disjointTurnsAreSummedPerSpeaker
    @Test func disjointTurnsAreSummedPerSpeaker() {
        let output = SpeakerAttribution.assign([passage([word(0, 0.05), word(0.11, 0.15), word(0.05, 0.3)])],
                                               turns: [turn(0, 0.1, "a"), turn(0.1, 0.2, "b"), turn(0.2, 0.4, "a")])
        #expect(speakers(output) == ["a", "b", "a"])
    }

    // ports: DiarizationTest#overlappingCopiesCannotDoubleCountTheSameSpeaker
    @Test func overlappingCopiesCannotDoubleCountTheSameSpeaker() {
        let turns = [turn(0, 0.4, "a"), turn(0.2, 0.5, "a"), turn(1, 1.6, "b"), turn(1.6, 1.7, "b")]
        let output = SpeakerAttribution.assign([passage([word(0, 0.01), word(1.01, 1.02), word(0, 1.7)])], turns: turns)
        #expect(speakers(output) == ["a", "b", "b"])
    }

    // ports: DiarizationTest#equalOverlapsAndGapTiesAreIndependentOfNativeOrder
    @Test func equalOverlapsAndGapTiesAreIndependentOfTheTurnOrder() {
        let turns = [turn(0, 0.1, "x8"), turn(0.2, 0.3, "x1")]
        let transcript = [passage([word(0, 0.01), word(0.2, 0.21), word(0.05, 0.25), word(0.15, 0.15)])]
        let output = SpeakerAttribution.assign(transcript, turns: turns)
        #expect(output == SpeakerAttribution.assign(transcript, turns: turns.reversed()))
        #expect(speakers(output) == ["x8", "x1", "x8", "x8"])
    }

    /// A passage without words is attributed as a whole.
    @Test func aPassageWithoutWordsIsAttributedAsAWhole() {
        let output = SpeakerAttribution.assign([TranscriptSegment(text: "Imported", start: 0, end: 4)], turns: [turn(0, 1, "a"), turn(1, 4, "b")])
        #expect(output.map(\.speakerID) == ["b"])
    }

    @Test func isolatedSpeechSubtractsOnlyOverlapAndNeverDoubleCounts() {
        let turns = [turn(0, 10, "a"), turn(5, 12, "a"), turn(3, 4, "b"), turn(8, 9, "b")]
        #expect(SpeakerAttribution.isolatedSeconds(speakerID: "a", turns: turns) == 10)
        #expect(SpeakerAttribution.isolatedSeconds(speakerID: "b", turns: turns) == 0)
    }
}
