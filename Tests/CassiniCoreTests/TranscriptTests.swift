@testable import CassiniCore
import Testing

@Suite struct TranscriptTests {
    // ports: TranscriptTest#sessionRoundTripPreservesLanguageAndOverlappingTurnOrder
    @Test func sessionRoundTripPreservesLanguageAndOverlappingTurnOrder() throws {
        let original = Transcript([Word("a", 2000, 2500, "perché?"), Word("b", 1000, 2200, "Ciao.")], language: "it")
        #expect(try Transcript.fromJSON(original.json()) == original)
    }

    // ports: TranscriptTest#restoredBodyTreatsNullItemsAsEmptyWithoutAssumingALanguage
    @Test func restoredBodyTreatsNullItemsAsEmptyWithoutAssumingALanguage() throws {
        let restored = try Transcript.fromJSON(#"{"format":"cassini.words.v1","items":null,"wordCount":0,"futureHint":true}"#)
        #expect(restored.words.isEmpty)
        #expect(restored.language == "")
    }

    // ports: TranscriptTest#rejectsCorruptPersistedWordExtents
    @Test func rejectsCorruptPersistedWordExtents() {
        #expect(throws: CassiniError.self) {
            try Transcript.fromJSON(#"{"format":"cassini.words.v1","items":[{"speaker":"a","startMs":900,"endMs":100,"text":"ciao"}]}"#)
        }
    }

    // ports: TranscriptTest#italianPiecesAndDelayedPunctuationKeepAcousticExtent
    @Test func italianPiecesAndDelayedPunctuationKeepAcousticExtent() throws {
        let transcript = try Transcript.fromTokens(["▁C", "iao", ",", "▁per", "ché", "?", "▁Sì", "."],
                                                   timestamps: [0.1, 0.2, 1.5, 1.5, 1.6, 3, 3, 5],
                                                   durations: [0.1, 0.1, 0, 0.1, 0.2, 0, 0.2, 0])
        #expect(transcript.words.map(\.text) == ["Ciao,", "perché?", "Sì."])
        #expect(transcript.words.map(\.startMs) == [100, 1500, 3000])
        #expect(transcript.words.map(\.endMs) == [300, 1800, 3200])
        let json = try JSON.parseObject(transcript.json())
        #expect(json["format"] == .string("cassini.words.v1"))
        // Speech recognition does not report a language; the format reads an absent one as "nobody said".
        #expect(!json.has("language"))
        #expect(try json.number("wordCount") == 3)
        #expect(try json.array("items")[1].object?["text"] == .string("perché?"))
    }

    // ports: TranscriptTest#blankBoundaryAndApostropheDoNotBecomeExtraWords
    @Test func blankBoundaryAndApostropheDoNotBecomeExtraWords() throws {
        let transcript = try Transcript.fromTokens(["▁", "l", "'", "acqua", "▁è", "▁fredda", "."],
                                                   timestamps: [0, 0.1, 0.15, 0.2, 0.5, 0.7, 1], durations: Array(repeating: 0.1, count: 7))
        #expect(transcript.words.map(\.text) == ["l'acqua", "è", "fredda."])
        #expect(transcript.words.allSatisfy { $0.endMs >= $0.startMs })
    }

    // ports: TranscriptTest#preservesSpeakerTurnOrderEvenWithOverlappingSpeakers
    @Test func preservesSpeakerTurnOrderEvenWithOverlappingSpeakers() throws {
        let transcript = Transcript([Word("a", 2000, 2500, "Sì."), Word("b", 1000, 2200, "Ciao.")])
        let items = try JSON.parseObject(transcript.json()).array("items")
        #expect(items[0].object?["speaker"] == .string("a"))
        #expect(try items[1].object?.number("startMs") == 1000)
    }

    // ports: TranscriptTest#silenceExportsAnEmptyValidBody
    @Test func silenceExportsAnEmptyValidBody() throws {
        let json = try JSON.parseObject(try Transcript.fromTokens([], timestamps: [], durations: []).json())
        #expect(try json.number("wordCount") == 0)
        #expect(try json.array("items").isEmpty)
    }

    // ports: TranscriptTest#rejectsMissingAlignment
    @Test func rejectsMissingAlignment() {
        #expect(throws: CassiniError.self) { try Transcript.fromTokens(["▁ciao"], timestamps: [], durations: []) }
    }

    // ports: TranscriptTest#rejectsNonfiniteAlignment
    @Test func rejectsNonfiniteAlignment() {
        #expect(throws: CassiniError.self) { try Transcript.fromTokens(["▁ciao"], timestamps: [.nan], durations: [0.1]) }
    }

    // ports: TranscriptTest#rejectsBackwardTimes
    @Test func rejectsBackwardTimes() {
        #expect(throws: CassiniError.self) { try Transcript.fromTokens(["▁ciao", "▁ciao"], timestamps: [1, 0.5], durations: [0.1, 0.1]) }
    }

    /// iOS only: Android decides speech with `isLetterOrDigit`, so a superscript, fraction or Roman numeral piece is a
    /// mark and does not stretch the word's end, though it still raises the cap.
    @Test func onlyLettersAndDecimalDigitsAreSpeech() throws {
        let words = try Transcript.timedWordsFromTokens(["▁m", "²", "▁Ⅻ", "▁3", "½"], timestamps: [1, 3, 4, 5, 6],
                                                        durations: [0.2, 0.1, 0.1, 0.1, 0.1])
        #expect(words.map(\.word.text) == ["m²", "Ⅻ", "3½"])
        #expect(words.map(\.word.endMs) == [1200, 4000, 5100])
        #expect(words.map(\.capMs) == [3100, 4000, 6100])
    }

    @Test func theBodyIsCompactJsonAndALanguageIsKeptWhenKnown() {
        let transcript = Transcript([Word("spk_1", 0, 20, "Ciao")], language: "it")
        #expect(transcript.json() == #"{"format":"cassini.words.v1","language":"it","wordCount":1,"items":[{"speaker":"spk_1","startMs":0,"endMs":20,"text":"Ciao"}]}"#)
        #expect(Transcript([]).json() == #"{"format":"cassini.words.v1","wordCount":0,"items":[]}"#)
    }
}
