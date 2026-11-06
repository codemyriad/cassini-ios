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
        let words = [Word("s1", 0, 1, "\"quoted\""), Word("s1", 1, 2, "back\\slash"), Word("s1", 2, 3, "and/or"), Word("s1", 3, 4, "café"),
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
        #expect(try WordBodyBudget.fitsHeader(transcript, sealing: ArraySource(silence())))
        let full = CassiniDocument(state: .ok, comments: ["X_FILL=" + String(repeating: "x", count: Int(WordBodyBudget.maxHeaderBytes) - 1024)])
        #expect(try !WordBodyBudget.fitsHeader(transcript, beside: full))
        let small = CassiniDocument(state: .ok, comments: ["X_FILL=x"])
        #expect(try WordBodyBudget.headerBytes(adding: transcript, to: small) > WordBodyBudget.headerBytes(adding: transcript, to: CassiniDocument(state: .ok)))
    }

    /** A fresh seal keeps the source's foreign comments, so an imported file's cover art takes header space. */
    @Test func aFreshSealCountsTheForeignCommentsOfItsSource() throws {
        let transcript = Transcript([Word("spk_1", 0, 20, "Hello")])
        // A source the reader accepts, with too little room left for even the manifest.
        let cover = "METADATA_BLOCK_PICTURE=" + String(repeating: "A", count: OggOpus.maxHeaderBytes - 512 - 23)
        let source = try silence([cover])
        try #require(CassiniDocument.read(source).state == .plainAudio)
        #expect(try !WordBodyBudget.fitsHeader(transcript, sealing: ArraySource(source)))
        #expect(throws: CassiniError.self) { _ = try CassiniDocument.create(source, transcript: transcript, title: "Import", processing: JSONObject()) }
        // Its own Cassini tags are replaced, so they do not count.
        let stale = try silence(["CASSINI_FILL=" + String(repeating: "x", count: OggOpus.maxHeaderBytes - 4096)])
        #expect(try WordBodyBudget.fitsHeader(transcript, sealing: ArraySource(stale)))
    }

    /** A fresh seal that carries a source's private data grows its manifest by that data, so a huge notes list does not fit. */
    @Test func aFreshSealCountsTheMembersItCarries() throws {
        let transcript = Transcript([Word("spk_1", 0, 20, "Hello")])
        func carrying(_ text: String) -> CassiniDocument {
            let notes = JSON.object(JSONObject([("notes", .array([.object(JSONObject([("atMs", .int(0)), ("text", .string(text))]))]))]))
            return CassiniDocument(state: .staleAudio, manifest: JSONObject([("kind", .string("cassini-portable-meeting")),
                                                                              ("x", .object(JSONObject([("gocassini.com", notes)])))]))
        }
        let audio = try silence()
        var source: ArraySource { ArraySource(audio) }
        let alone = try WordBodyBudget.headerBytes(adding: transcript, sealing: source)
        let small = carrying(noise(64 << 10))
        #expect(try WordBodyBudget.headerBytes(adding: transcript, sealing: source, carrying: small) > alone + (64 << 10))
        #expect(try WordBodyBudget.fitsHeader(transcript, sealing: source, carrying: small))
        #expect(try WordBodyBudget.headerBytes(adding: transcript, sealing: source, carrying: CassiniDocument(state: .plainAudio)) == alone)
        #expect(try !WordBodyBudget.fitsHeader(transcript, sealing: source, carrying: carrying(noise(Int(WordBodyBudget.maxHeaderBytes)))))
    }

    /**
     * Private data that gzip shrinks to almost nothing still makes the manifest the codec checks against its 16 MiB
     * limit, so it does not fit either, however small its tags would be.
     */
    @Test func aFreshSealRefusesCarriedDataTooLargeUncompressed() throws {
        let transcript = Transcript([Word("spk_1", 0, 20, "Hello")])
        let audio = try silence()
        func carrying(_ count: Int) -> CassiniDocument {
            CassiniDocument(state: .staleAudio, manifest: JSONObject([
                ("x", .object(JSONObject([("example.com", .string(String(repeating: "a", count: count)))]))),
            ]))
        }
        let large = carrying(Int(WordBodyBudget.maxCarriedBytes))
        #expect(try WordBodyBudget.headerBytes(adding: transcript, sealing: ArraySource(audio), carrying: large) < 1 << 20)
        #expect(try !WordBodyBudget.fitsHeader(transcript, sealing: ArraySource(audio), carrying: large))
        #expect(try WordBodyBudget.fitsHeader(transcript, sealing: ArraySource(audio), carrying: carrying(Int(WordBodyBudget.maxCarriedBytes) - 64)))
    }
}
