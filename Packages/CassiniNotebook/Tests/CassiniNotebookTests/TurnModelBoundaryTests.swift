import Foundation
import Testing
@testable import CassiniNotebook

/// Source-derived edges not present in the six shared vectors. References are to the pinned
/// gocassini viewer at 1111155, not to the Swift implementation under test.
@Suite struct TurnModelBoundaryTests {
    private func word(_ speaker: String?, _ start: Double, _ end: Double, _ text: String,
                      flagged: Bool = false) -> TurnModel.Word {
        .init(speaker: speaker, startMs: start, endMs: end, text: text, lowConfidenceSpeaker: flagged)
    }

    // MeetingView.svelte continuationRowKeys: same known speaker, <= 60_000 ms.
    @Test(arguments: [60_000.0, 60_001.0])
    func continuationIncludesExactlySixtySeconds(_ gap: Double) throws {
        let rows = TurnModel.rows(of: [word("ada", 0, 200, "First"),
                                      word("ada", 200 + gap, 400 + gap, "Later")])
        #expect(rows.count == 2)
        #expect(try #require(rows.last).continuation == (gap == 60_000))
    }

    @Test func unknownSpeakerUsesTheViewersFallbackIdentity() {
        let rows = TurnModel.rows(of: [word(nil, 0, 200, "First"), word(nil, 10_000, 10_200, "Later")])
        #expect(rows.count == 2)
        #expect(rows.map(\.speaker) == ["Unknown speaker", "Unknown speaker"])
        #expect(rows.map(\.continuation) == [false, true])
    }

    // overlap.ts repairTurnFinalWordInflation: conservative 1000 ms floor when reference
    // population has fewer than eight words; authoritative audio-bounded provenance bypasses repair.
    @Test func authoritativeEndsBypassLegacyPunctuationRepair() throws {
        let words = [word("ada", 0, 5000, "Wait.")]
        #expect(try #require(TurnModel.rows(of: words).first).endMs == 1000)
        #expect(try #require(TurnModel.rows(of: words, endsBoundedByAudio: true).first).endMs == 5000)
    }

    @Test func interiorPunctuationRepairRemovesInventedOverlap() throws {
        let words = [word("ada", 0, 5000, "Wait."), word("ben", 2000, 2400, "Yes"),
                     word("ada", 5000, 5200, "now")]
        let repaired = TurnModel.rows(of: words)
        #expect(repaired.allSatisfy { $0.over.isEmpty })
        let bounded = TurnModel.rows(of: words, endsBoundedByAudio: true)
        #expect(try #require(bounded.first { $0.speaker == "ada" }).over == ["ben"])
        #expect(try #require(bounded.first { $0.speaker == "ben" }).over == ["ada"])
    }

    // overlap.ts budgetsBySpeaker: >=8 non-candidate reference words permit the speaker's own
    // median; the punctuation candidate itself must never inflate that median.
    @Test func punctuationTailBudgetUsesEightReferenceWords() throws {
        var words = (0..<8).map { word("ada", Double($0 * 400), Double(($0 + 1) * 400), "word\($0)") }
        words.append(word("ada", 3200, 6200, "Done."))
        #expect(try #require(TurnModel.rows(of: words).last).endMs == 4800)
    }

    // transcript.ts isLikelyCrosstalkTurn: every canonical word, never a majority vote.
    @Test(arguments: [false, true])
    func crosstalkRequiresEveryOwnWord(_ secondFlagged: Bool) throws {
        let rows = TurnModel.rows(of: [word("ada", 0, 200, "First", flagged: true),
                                      word("ada", 200, 400, "second", flagged: secondFlagged)])
        #expect(try #require(rows.first).crosstalk == secondFlagged)
    }

    @Test(arguments: [false, true])
    func chipConfidenceDoesNotChangeHostConfidence(_ hostFlagged: Bool) throws {
        struct Fixture: Decodable {
            var items: [Item]
            struct Item: Decodable { var speaker: String?; var startMs: Double; var endMs: Double; var text: String }
        }
        let url = try #require(Bundle.module.url(forResource: "acknowledgment.words", withExtension: "json", subdirectory: "interjections"))
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let words = fixture.items.map {
            word($0.speaker, $0.startMs, $0.endMs, $0.text, flagged: $0.speaker == "ada" ? hostFlagged : !hostFlagged)
        }
        let rows = TurnModel.rows(of: words)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        let chip = try #require(row.members.first { $0.kind == .interjection })
        #expect(row.crosstalk == hostFlagged)
        #expect(chip.speaker == "ben")
        #expect(chip.crosstalk == !hostFlagged)
    }

    // overlap.ts minimum credible overlap is inclusive at 150 ms. Distinct speakers retain
    // canonical input order when their start times tie (stable chronological sorting).
    @Test(arguments: [149.0, 150.0])
    func credibleOverlapFloorIsInclusive(_ overlap: Double) throws {
        let rows = TurnModel.rows(of: [word("ben", 0, overlap, "First"), word("ada", 0, 1000, "Second")])
        #expect(rows.map(\.speaker) == ["ben", "ada"])
        #expect(try #require(rows.first).over == (overlap == 150 ? ["ada"] : []))
        #expect(try #require(rows.last).over == (overlap == 150 ? ["ben"] : []))
    }
    // overlap.ts budgetsBySpeaker: seven references are insufficient for a speaker median;
    // the meeting median is 600 ms, not the 250 ms last-resort fallback or Ada's 100 ms.
    @Test(arguments: [0, 7])
    func sparseSpeakerFallsBackToNondefaultMeetingMedian(_ referenceCount: Int) throws {
        var words = (0..<9).map { word("ben", Double($0 * 600), Double(($0 + 1) * 600), "reference\($0)") }
        words += (0..<referenceCount).map { word("ada", 6000 + Double($0 * 100), 6100 + Double($0 * 100), "short\($0)") }
        let replyStart = 6000 + Double(referenceCount * 100)
        words.append(word("ada", replyStart, 15_000, "Done."))
        let ada = try #require(TurnModel.rows(of: words).last { $0.speaker == "ada" })
        #expect(ada.endMs == replyStart + 2400) // No references or seven both use 4 * meeting median 600.
    }

    // With eight references Ada uses her own 400 ms median even though Ben's larger
    // population makes the meeting median 800 ms. Inflated punctuation candidates do not count.
    @Test func speakerMedianOverridesMeetingAndExcludesInflatedCandidates() throws {
        var words = (0..<10).map { word("ben", Double($0 * 800), Double(($0 + 1) * 800), "reference\($0)") }
        words += (0..<8).map { word("ada", 9000 + Double($0 * 400), 9400 + Double($0 * 400), "own\($0)") }
        words += (0..<10).map { word("ada", 12_200 + Double($0 * 5000), 17_200 + Double($0 * 5000), "Done.") }
        let adaRows = TurnModel.rows(of: words).filter { $0.speaker == "ada" }
        let last = try #require(adaRows.last)
        #expect(last.endMs == 58_800) // last candidate start 57_200 + 4 * 400
    }

    // measureSimultaneity orders ties by the viewer's zero-padded canonical string key.
    // Crossing six digits is lexical, so seg_1000000 sorts before seg_999999. Sparse internal
    // block ids exercise that boundary without allocating a million unrelated words.
    @Test func overlapTieUsesCanonicalStringKeysAcrossSixDigitBoundary() {
        func block(_ id: Int, _ speaker: String, _ start: Double, _ end: Double) -> TurnModel.Block {
            let item = word(speaker, start, end, speaker)
            var result = TurnModel.Block(id: id, speaker: speaker, startMs: start, endMs: end,
                                         text: speaker, words: [.init(index: id, word: item)])
            result.prepareSpans()
            return result
        }
        let blocks = [block(999_999, "ada", 0, 1000), block(1_000_000, "ben", 100, 1100),
                      block(1_000_001, "cy", 200, 900)]
        let runs = TurnModel.turnRuns(blocks)
        let over = TurnModel.competingSpeakers(runs, nested: [:])
        // Cy overlaps Ada and Ben equally (700 ms): Ben's lexical key wins this tie.
        #expect(over[2] == ["ben", "ada"])
    }

}
