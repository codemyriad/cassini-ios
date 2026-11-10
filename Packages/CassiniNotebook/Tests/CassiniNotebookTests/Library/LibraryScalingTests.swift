import Foundation
import Testing
@testable import CassiniNotebook

/// The Library's keystroke work grows linearly: a note's preview in its words, the index and the rows in the notes.
/// Calling-thread CPU of the same work at two sizes, four times apart, so no budget depends on how fast the machine
/// is (D88). The hosted LibraryScreenTests check holds the absolute frame budget at 1,000 notes.
///
/// Linear work costs 4x; the bound allows 2.5x per doubling (6.25x), and a quadratic step costs up to 16x. Grouping
/// a paragraph used to join all of its words again after each word: a 140-word preview then cost 10.1-10.3x a
/// 35-word one (rows 11.6-13.9x), against 4.0-5.2x (rows 4.5-5.5x) since (macOS 27, Debug, a loaded machine). The
/// keystroke measures 3.5-4.5x; a scan of the index per note made it 14.9x. The smaller size is large enough that
/// what every call pays whatever its size (a 1-word preview costs about 8% of a 35-word one) does not hide the growth.
@Suite struct LibraryScalingTests {
    static let vocabulary = ["delivery", "Thursday", "price", "supplier", "order", "warehouse", "meeting", "budget"]
    static let bound = 6.25

    /// One passage of `count` words, as in the thousand-note check: one paragraph, so up to 140 words a single block
    /// (the grouping's limit) that the old rejoin made quadratic.
    static func passage(_ count: Int, note: Int = 0) -> String {
        (0..<count).map { vocabulary[($0 * 7 + note) % vocabulary.count] + "\(note % 13)" }.joined(separator: " ")
    }

    static func note(_ index: Int, words: Int) -> Note {
        var note = Note(title: "Note \(index) \(vocabulary[index % vocabulary.count])",
                        createdAt: Date(timeIntervalSince1970: 1_791_452_460 - Double(index) * 3_600))
        note.transcript = [TranscriptSegment(text: passage(words, note: index), start: 0, end: Double(words) / 2)]
        note.status = .ready
        return note
    }

    @Test func aPreviewCostsLinearlyInItsWords() throws {
        let small = Self.note(0, words: 35), large = Self.note(0, words: 140)
        #expect(try #require(large.transcriptPreview).text.count > 100, "the large passage fills a preview")
        try Self.expectLinear("a preview", sizes: ("35 words", "140 words"), repeats: 10,
                              small: { _ = small.transcriptPreview }, large: { _ = large.transcriptPreview })
    }

    @Test func aPassagesRowsCostLinearlyInItsWords() throws {
        let words = { (count: Int) in
            (0..<count).map { index in
                TurnModel.Word(speaker: nil, startMs: Double(index) * 500, endMs: Double(index) * 500 + 400,
                               text: Self.vocabulary[(index * 7) % Self.vocabulary.count] + "0")
            }
        }
        let small = words(35), large = words(140)
        #expect(TurnModel.readableBlocks(large).count == 1, "the large passage is one block")
        try Self.expectLinear("a passage's rows", sizes: ("35 words", "140 words"), repeats: 10,
                              small: { _ = TurnModel.rows(of: small) }, large: { _ = TurnModel.rows(of: large) })
    }

    /// What the main actor does when one note changes between keystrokes: the index takes the new notes (working out
    /// the changed note's preview) and the day sections are mapped again. Short transcripts keep the one preview from
    /// hiding what grows with the notes.
    @Test func aKeystrokeCostsLinearlyInTheNotes() throws {
        func keystroke(notes count: Int) -> () -> Void {
            let notes = (0..<count).map { Self.note($0, words: 6) }
            var edited = notes
            edited[count / 2].title += " edited"
            var index = LibraryIndex(notes), flip = false
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let now = Date(timeIntervalSince1970: 1_791_452_460)
            return {
                flip.toggle()
                index.update(flip ? edited : notes)
                let sections = LibraryMapping.sections(index.entries, context: RowContext(), now: now, calendar: calendar)
                precondition(sections.reduce(0) { $0 + $1.rows.count } == count)
            }
        }
        try Self.expectLinear("a keystroke", sizes: ("500 notes", "2,000 notes"), repeats: 2,
                              small: keystroke(notes: 500), large: keystroke(notes: 2_000))
    }

    static let samples = 25, rounds = 3

    /// Expects `large`, the work of 4x the size, to cost less than `bound` times `small` in calling-thread CPU, and
    /// prints what it measured either way.
    ///
    /// Each size's cost is its least sample: CPU time leaves out the time the thread waits, but not what a busy
    /// machine still adds while it runs (an efficiency core, caches refilled after a switch), so the least is the
    /// closest to the work itself. A sample runs the large work `repeats` times and the small work 4x as often, so
    /// both last about as long (10-20 ms) and are as likely to be disturbed, and they alternate, so a change in the
    /// machine's load meets both alike. On a busy machine (load 20 on 10 cores) a round of `samples` once measured
    /// 6.0x for work that measures 4.6x; up to `rounds` rounds keep the least of all of them, and a quadratic step
    /// stays above the bound in every round.
    static func expectLinear(_ work: String, sizes: (small: String, large: String), repeats: Int,
                             small: () -> Void, large: () -> Void) throws {
        small(); large()
        var best = (small: Duration.seconds(1_000), large: Duration.seconds(1_000)), used = 0
        var ratio: Double { best.large / best.small * 4 }
        repeat {
            used += 1
            for _ in 0..<samples {
                best.small = min(best.small, try measureThreadCPU { for _ in 0..<(4 * repeats) { small() } }.elapsed)
                best.large = min(best.large, try measureThreadCPU { for _ in 0..<repeats { large() } }.elapsed)
            }
        } while ratio >= bound && used < rounds
        func ms(_ sample: Duration, runs: Int) -> String { String(format: "%.3f ms", sample / .milliseconds(runs)) }
        let measured = "\(sizes.small) \(ms(best.small, runs: 4 * repeats)), \(sizes.large) \(ms(best.large, runs: repeats)), "
            + "ratio " + String(format: "%.2f", ratio) + ", \(used) of \(rounds) rounds"
        print("\(work), calling-thread CPU: \(measured)")
        #expect(ratio < bound, "\(work) of 4x the size costs less than \(bound)x (\(measured))")
    }
}
