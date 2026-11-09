import Foundation
import Testing
@testable import CassiniNotebook

/// Preview budgets and playback positions, plus D84 reading order and interjection seams.
struct PreviewTextTests {
    private func turn(_ speaker: String, _ startMs: Int64, _ text: String, msPerWord: Int64 = 350) -> [PreviewWord] {
        text.split(separator: " ").enumerated().map { i, word in
            PreviewWord(String(word), startMs: startMs + Int64(i) * msPerWord, endMs: startMs + Int64(i + 1) * msPerWord - 50,
                        speaker: speaker)
        }
    }

    /// The words of board 03 ("Call with supplier"). Paolo's turn starts at 11:41 and "so" plays at 11:44.
    private var board03: [PreviewWord] {
        turn("spk_0", 692_000, "Ok, then let's confirm the quantities first. We said four hundred units for the first batch, right?")
            + turn("spk_1", 701_000, "Yes, four hundred. The issue is next delivery: so the delivery slips to Thursday, "
                + "but the price stays as agreed in the March order.")
            + turn("spk_2", 740_000, "Can you send that in writing? I need it for the purchase order before Friday.")
    }

    // ports: PreviewTextTest#reproducesBoard00
    @Test func reproducesBoard00() throws {
        let preview = try #require(PreviewText.of(board03, positionMs: (11 * 60 + 44) * 1000))
        let board00 = "so the delivery slips to Thursday, but the price stays as agreed in the March order"
        #expect(preview.display == "…\(board00)…")
        #expect(preview.text == board00)
        #expect(preview.leadingEllipsis)
        #expect(preview.trailingEllipsis)
    }

    // ports: PreviewTextTest#positionZeroGivesTheTranscriptStart
    @Test func positionZeroGivesTheTranscriptStart() throws {
        let preview = try #require(PreviewText.of(board03, positionMs: 0))
        #expect(preview.display == "Ok, then let's confirm the quantities first. We said four hundred units for the first batch, right? "
            + "Yes, four hundred. The issue is next delivery: so the…")
        #expect(!preview.leadingEllipsis)
        #expect(preview.text.utf16.count <= PreviewText.limit)
        // Before the first word and inside it are the start too.
        #expect(PreviewText.of(board03, positionMs: 500_000) == preview)
        #expect(PreviewText.of(board03, positionMs: 692_100) == preview)
    }

    // ports: PreviewTextTest#aPauseStartsAtTheNextWord
    @Test func aPauseStartsAtTheNextWord() throws {
        let preview = try #require(PreviewText.of(board03, positionMs: 735_000))
        #expect(preview.display == "…Can you send that in writing? I need it for the purchase order before Friday.")
        #expect(preview.leadingEllipsis)
        #expect(!preview.trailingEllipsis)
    }

    // ports: PreviewTextTest#endOfTranscript
    @Test func endOfTranscript() {
        let last = board03.last!
        #expect(PreviewText.of(board03, positionMs: last.startMs)?.display == "…Friday.")
        // A finished playback leaves the position at or after the last word's end: the row shows the start.
        let start = PreviewText.of(board03, positionMs: 0)
        #expect(PreviewText.of(board03, positionMs: last.endMs) == start)
        #expect(PreviewText.of(board03, positionMs: last.endMs + 60_000) == start)
    }

    // ports: PreviewTextTest#aShortTurnContinuesIntoTheNextTurns
    @Test func aShortTurnContinuesIntoTheNextTurns() throws {
        let words = turn("spk_0", 0, "So, when does the second delivery arrive?") + turn("spk_1", 5_000, "Yes.")
            + turn("spk_0", 6_000, "So Thursday works for everyone, including the warehouse.") + turn("spk_1", 12_000, "All right.")
        let preview = try #require(PreviewText.of(words, positionMs: 5_000))
        #expect(preview.display == "…Yes. So Thursday works for everyone, including the warehouse…")
        #expect(preview.text.utf16.count >= PreviewText.minBeforeTurnEnd)
    }

    // ports: PreviewTextTest#cutAtAWordWithPunctuationDropped
    @Test func cutAtAWordWithPunctuationDropped() throws {
        let long = turn("spk_0", 0, (1...40).map { "sample\($0)," }.joined(separator: " "))
        let preview = try #require(PreviewText.of(long, positionMs: long[5].startMs))
        #expect(preview.text.utf16.count <= PreviewText.limit, "\(preview.display)")
        #expect(preview.text.hasPrefix("sample6, sample7, "))
        // Whole words only: the excerpt is a prefix of the words from the playing one.
        let words = long.dropFirst(5).map { $0.text.trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
        #expect(words.joined(separator: ", ").hasPrefix(preview.text))
        #expect(preview.display.hasSuffix("…"))
        #expect(!preview.display.hasSuffix(",…"))
        // One more word would not fit (the dropped comma counted).
        let next = long[5 + preview.text.split(separator: " ").count].text
        #expect((preview.text + ",").utf16.count + 1 + next.utf16.count > PreviewText.limit)
    }

    // ports: PreviewTextTest#sentencePunctuationIsDroppedOnlyWhenCut
    @Test func sentencePunctuationIsDroppedOnlyWhenCut() {
        let long = turn("spk_0", 0, "Then we agreed on the quantities for the first batch.") + turn("spk_1", 9_000, "Ok.")
        #expect(PreviewText.of(long, positionMs: long[1].startMs)?.display == "…we agreed on the quantities for the first batch…")
        let words = turn("spk_0", 0, "Fine. Next.") + turn("spk_1", 2_000, "Yes!")
        #expect(PreviewText.of(words, positionMs: words[1].startMs)?.display == "…Next. Yes!")
        #expect(PreviewText.of(words, positionMs: words[2].startMs)?.display == "…Yes!")
        #expect(PreviewText.of(words, positionMs: 0)?.display == "Fine. Next. Yes!")
    }

    // ports: PreviewTextTest#shortTranscriptHasNoEllipses
    @Test func shortTranscriptHasNoEllipses() {
        #expect(PreviewText.of(turn("spk_0", 0, "Hello world."), positionMs: 0) == Preview("Hello world."))
    }

    // ports: PreviewTextTest#noTranscriptNoPreview
    @Test func noTranscriptNoPreview() {
        #expect(PreviewText.of([], positionMs: 0) == nil)
        #expect(PreviewText.of([], positionMs: 10_000) == nil)
    }

    // ports: PreviewTextTest#aGiantWordIsCutOnACodePoint
    @Test func aGiantWordIsCutOnACodePoint() throws {
        let giant = String(repeating: "a", count: PreviewText.limit - 1) + "😀" + "tail"
        let preview = try #require(PreviewText.of([PreviewWord(giant, startMs: 0, endMs: 1_000, speaker: "spk_0")], positionMs: 0))
        #expect(preview.text == String(repeating: "a", count: PreviewText.limit - 1))
        #expect(preview.trailingEllipsis)
    }

    // ports: PreviewTextTest#storedPreviewReadsBack
    @Test func storedPreviewReadsBack() throws {
        let preview = try #require(PreviewText.of(board03, positionMs: 704_000))
        #expect(Highlighted(marked: preview.display)
            == Highlighted(preview.text, leadingEllipsis: true, trailingEllipsis: true))
    }

    // MARK: A note's transcript

    /// board03 as passages of a note, one per sentence, with word times.
    private var board03Note: Note {
        var note = Note(title: "Call with supplier")
        var segments: [TranscriptSegment] = []
        var turnWords: [PreviewWord] = []
        func flush() {
            guard let first = turnWords.first, let last = turnWords.last else { return }
            segments.append(TranscriptSegment(
                text: turnWords.map(\.text).joined(separator: " "), start: Double(first.startMs) / 1000,
                end: Double(last.endMs) / 1000, speakerID: first.speaker,
                words: turnWords.map { TimedWord(text: $0.text, start: Double($0.startMs) / 1000, end: Double($0.endMs) / 1000) }))
            turnWords = []
        }
        for word in board03 {
            if let previous = turnWords.last, previous.speaker != word.speaker || previous.text.last == "." { flush() }
            turnWords.append(word)
        }
        flush()
        note.transcript = segments
        return note
    }

    @Test func aNotesPreviewReadsTheWordsAtItsPosition() {
        var note = board03Note
        for positionMs: Int64 in [0, 500_000, 692_100, 704_000, (11 * 60 + 44) * 1000, 735_000, board03.last!.startMs,
                                  board03.last!.endMs + 1] {
            note.playbackPosition = Double(positionMs) / 1000
            #expect(note.transcriptPreview == PreviewText.of(board03, positionMs: positionMs), "at \(positionMs)")
        }
    }

    @Test func anEditedPassageWithoutWordTimesSpreadsItsWords() {
        var note = Note(title: "Edited")
        note.transcript = [TranscriptSegment(text: "one two three four", start: 0, end: 4),
                           TranscriptSegment(text: "five six", start: 4, end: 6)]
        note.playbackPosition = 4.5
        #expect(note.transcriptPreview?.display == "…five six")
        note.playbackPosition = 0
        #expect(note.transcriptPreview?.display == "one two three four five six")
        #expect(Note(title: "Empty").transcriptPreview == nil)
    }
}


extension PreviewTextTests {
    @Test func acknowledgmentPreviewKeepsTheChipAndDoesNotStopAtItsSpeakerChange() throws {
        let vector = try D84IntegrationVector.load("acknowledgment")
        let words = vector.words.map { PreviewWord($0.text, startMs: $0.startMs, endMs: $0.endMs, speaker: $0.speaker) }
        let expected = "The release candidate is ready for testing, (Ben: Sounds good.) and I will send the download link after this call."
        #expect(PreviewText.of(words, positionMs: 0, labels: ["ben": "Ben"])?.display == expected)
        // Starting after the first word must still carry the host's words after the interjection.
        let preview = try #require(PreviewText.of(words, positionMs: words[1].startMs, labels: ["ben": "Ben"]))
        #expect(preview.display == "…" + String(expected.dropFirst("The ".count)))
        #expect(!preview.trailingEllipsis)
    }

    @Test func competingPreviewReadsWholeRowsRatherThanInterleavingSpeakers() throws {
        let vector = try D84IntegrationVector.load("competing")
        let words = vector.words.map { PreviewWord($0.text, startMs: $0.startMs, endMs: $0.endMs, speaker: $0.speaker) }
        let first = "I can check the Linux build and report any problems today."
        let second = "I will test the browser connection and check the microphone settings."
        #expect(PreviewText.of(words, positionMs: 0)?.display == first + " " + second)
        let preview = try #require(PreviewText.of(words, positionMs: words[2].startMs))
        #expect(preview.display == "…" + String(first.dropFirst("I ".count).dropLast()) + "…")
        #expect(preview.trailingEllipsis)
    }

    @Test func notePreviewUsesSpeakerLabelsInItsInlineChip() throws {
        let vector = try D84IntegrationVector.load("acknowledgment")
        var note = Note(title: "Weekly check-in")
        note.transcript = TranscriptSegment.segments(of: vector.words)
        note.speakers = [.init(id: "ada", name: "Ada"), .init(id: "ben", name: "Ben")]
        #expect(note.transcriptPreview?.display.contains("(Ben: Sounds good.)") == true)
        #expect(note.transcriptPreview?.display.contains("and I will send") == true)
    }
}

extension PreviewTextTests {
    @Test func equalStartPlaybackUsesTheLaterCanonicalAtom() {
        let words = [PreviewWord("First.", startMs: 0, endMs: 1000, speaker: "ada"),
                     PreviewWord("Second.", startMs: 0, endMs: 1000, speaker: "ben")]
        #expect(PreviewText.of(words, positionMs: 100)?.display == "…Second.")
    }
}
