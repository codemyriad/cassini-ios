@testable import CassiniCore
import Testing

@Suite struct WordBodyBudgetTests {
    func actual(_ words: [Word], language: String = "") -> Int64 { Int64(Transcript(words, language: language).json().utf8.count) }

    // ports: WordBodyBudgetTest#theCountIsAnUpperBoundWithinOnePercent
    @Test func theCountIsAnUpperBoundWithinOnePercent() {
        let words = LongRun().words(LongRun.hourMs)
        let real = actual(words)
        let counted = WordBodyBudget.bytes(words)
        #expect(counted >= real)
        #expect(counted <= real + real / 100)
        #expect(WordBodyBudget.bytes(words, language: "it") >= actual(words, language: "it"))
    }

    // ports: WordBodyBudgetTest#escapesAndWideCharactersCountAsTheyAreWritten
    @Test func escapesAndWideCharactersCountAsTheyAreWritten() {
        let words = [Word("s1", 0, 1, "\"quoted\""), Word("s1", 1, 2, "back\\slash"), Word("s1", 2, 3, "e/o"), Word("s1", 3, 4, "giovedì"),
                     Word("s1", 4, 5, "東京"), Word("s1", 5, 6, "😀"), Word("s1", 6, 7, "a\u{1}b"), Word("s1", 7, 8, "a\nb")]
        #expect(WordBodyBudget.bytes(words) >= actual(words))
        let one = WordBodyBudget.bytes([Word("s1", 0, 0, "abc")])
        #expect(one == WordBodyBudget.bytes([]) + WordBodyBudget.itemBytes + 2 + 1 + 1 + 3)
    }

    // ports: WordBodyBudgetTest#eightHoursOfSpeechFitAndFourteenDoNot
    @Test func tenHoursOfSpeechFitAndEighteenDoNot() {
        #expect(WordBodyBudget.fits(LongRun().words(10 * LongRun.hourMs)))
        #expect(!WordBodyBudget.fits(LongRun().words(18 * LongRun.hourMs)))
    }

    /**
     * A body at the budget is accepted by the payload codec and stays well inside the header limit once encoded. A
     * compact body holds more words than Android's pretty-printed one, so its tags take up to a third of the limit.
     */
    // ports: WordBodyBudgetTest#aBodyAtTheBudgetEncodes
    @Test func aBodyAtTheBudgetEncodes() throws {
        let all = LongRun().words(18 * LongRun.hourMs)
        var low = 0, high = all.count
        while low < high {
            let mid = (low + high + 1) / 2
            if WordBodyBudget.fits(Array(all[0..<mid])) { low = mid } else { high = mid - 1 }
        }
        let words = Array(all[0..<low])
        let body = Transcript(words).json()
        #expect(body.utf8.count <= CassiniPayload.maxRaw)
        let (ref, tags) = try CassiniPayload.encode(prefix: "CASSINI_TX_WORDS_PAYLOAD_", mime: CassiniPayload.wordMime, text: body)
        #expect(try ref.number("chunkCount") <= 4096)
        #expect(tags.reduce(0) { $0 + $1.utf8.count + 4 } < OggOpus.maxHeaderBytes / 3)
        #expect((130_000...160_000).contains(words.count), "\(words.count) words")
    }

    @Test func aVariantFitsTheHeaderOnlyWhileTheTagsLeaveRoom() throws {
        let transcript = Transcript(LongRun().words(LongRun.hourMs / 60))
        #expect(try WordBodyBudget.fitsHeader(transcript, beside: nil))
        let full = CassiniDocument(state: .ok, comments: ["X_FILL=" + String(repeating: "x", count: Int(WordBodyBudget.maxHeaderBytes) - 1024)])
        #expect(try !WordBodyBudget.fitsHeader(transcript, beside: full))
        let small = CassiniDocument(state: .ok, comments: ["X_FILL=x"])
        #expect(try WordBodyBudget.headerBytes(adding: transcript, to: small) > WordBodyBudget.headerBytes(adding: transcript, to: nil))
    }
}
