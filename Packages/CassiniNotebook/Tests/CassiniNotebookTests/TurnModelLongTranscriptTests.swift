import Foundation
import Testing
@testable import CassiniNotebook

/// Mirrors Android LongExportTest/LongRun's supported note size: 11 h, 9,500 words/hour,
/// four speakers and a speaker change every 23 words. This checks the new model itself.
@Suite struct TurnModelLongTranscriptTests {
    @Test func elevenHourTranscriptKeepsEveryAtomAndReadableEndpointsWithinBudget() throws {
        let durationMs = 11 * 3_600_000
        let gap = 3_600_000 / 9500
        let words = (0..<(durationMs / gap)).map { index in
            TurnModel.Word(speaker: "speaker_\(1 + (index / 23) % 4)", startMs: Double(index * gap),
                           endMs: Double(index * gap + gap * 4 / 5), text: "word\(index)")
        }
        #expect(words.count == 104_761)
        let started = ContinuousClock.now
        let rows = TurnModel.rows(of: words)
        let elapsed = ContinuousClock.now - started
        // Android gives the three long export writers together 30 s. Use the same upper bound
        // for this projection; an accidental repeated scan of every word/block must not pass.
        #expect(elapsed < .seconds(30), "11-hour turn projection took \(elapsed)")
        #expect(rows.count == 4555)
        #expect(try #require(rows.first).startMs == 0)
        #expect(try #require(rows.last).endMs == 39_599_582)
        let members = rows.flatMap(\.members)
        let indices = members.flatMap(\.wordIndices)
        #expect(indices == Array(words.indices))
        #expect(members.allSatisfy { $0.kind == .words && !$0.text.isEmpty })
        #expect(rows.allSatisfy { !$0.members.isEmpty && $0.over.isEmpty })
        let body = members.map(\.text).joined(separator: " ")
        #expect(body.split(separator: " ").count == words.count)
        #expect(body.hasPrefix("word0 word1 word2 "))
        #expect(body.hasSuffix(" word104760"))
    }
}
