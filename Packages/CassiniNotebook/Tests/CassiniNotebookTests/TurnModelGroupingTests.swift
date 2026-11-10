import Foundation
import Testing
@testable import CassiniNotebook

/// The paragraph grouping gives what it gave before it compiled its patterns once and grew a block's text word by
/// word. It used to search with `String.range(of:options: .regularExpression)` and join every word of a block again
/// after each word; those steps are kept below as the reference. The one difference, on text with combining marks, is
/// pinned in `compiledPatternsMatchCodePointsAsPortableDoes`.
@Suite struct TurnModelGroupingTests {
    static let corpus = [
        "", " ", "\n", "word", "Word.", "word.\"", "word.')]", "end.\n", "end.)\n", "x\n.", "a.b", ".a", "?!", "\t.",
        ",", ",a", ")a", " ,a", "(aside)", "ok)", "Hi!'", "really?\"", "so...", "wait…", "naïve", "e\u{301}", "٣",
        "中文。", "好！", "说」", "नमस्ते।", "مرحبا؟", "👍", "👍.", "1", "3.5", "-", "—", "\"Yes,\" she said.",
        "warehouse4 meeting5 budget6 delivery7", "line one.\nline two", "trailing space. ",
    ]

    /// On the text the model gives them: trimmed for the patterns anchored at the end (a compiled `$` also matches
    /// before a final line break), as it is for every pattern.
    @Test func compiledPatternsMatchWhatTheStringSearchMatched() {
        let patterns: [TurnModel.Pattern] = [.sentenceEnd, .attachesToPrevious, .wordLike, .punctuationTail]
        for pattern in patterns {
            let source = pattern.regex.pattern
            for raw in Self.corpus {
                for text in source.hasSuffix("$") ? [raw.trimmingCharacters(in: .whitespacesAndNewlines)] : [raw, raw.trimmingCharacters(in: .whitespacesAndNewlines)] {
                    #expect(pattern.matches(text) == (text.range(of: source, options: .regularExpression) != nil),
                            "\(source) on \(text.debugDescription)")
                }
            }
        }
    }

    /// Where the compiled patterns differ from that search on macOS 27: they match code points, as portable.ts's
    /// JavaScript does, so a combining mark no longer hides the punctuation or letter before it.
    @Test func compiledPatternsMatchCodePointsAsPortableDoes() {
        for text in [",\u{301}", ".\u{301}", ")\u{200D}", "?\u{E33}\u{1161}"] {
            #expect(TurnModel.Pattern.attachesToPrevious.matches(text), "\(text.debugDescription)")
        }
        #expect(TurnModel.joinedText(["a", ",\u{301}", "b"]) == "a,\u{301} b")
        #expect(TurnModel.isWordLike("\u{E49}\u{E33}"))
        #expect(TurnModel.isWordLike("\u{301}\u{E33}\u{20DD}"))
        #expect(!TurnModel.isWordLike("\u{301}"))
        #expect(!TurnModel.Pattern.sentenceEnd.matches("a.\u{301}"))
        #expect(!TurnModel.Pattern.punctuationTail.matches("a.\u{301}"))
    }

    /// The grouping reads a sentence's end from the text's end; it answers as the pattern does on the trimmed text.
    @Test func aSentenceEndReadFromTheEndAgreesWithThePattern() {
        func agrees(_ text: String) {
            let pattern = TurnModel.Pattern.sentenceEnd.matches(text.trimmingCharacters(in: .whitespacesAndNewlines))
            #expect(TurnModel.endsSentence(text) == pattern, "\(text.debugDescription)")
        }
        Self.corpus.forEach(agrees)
        let pieces = [".", "!", "?", "\"", "'", ")", "]", "a", "e\u{301}", "\u{301}", "\u{200D}", " ", "\n", "\r\n", "\t",
                      "\u{85}", "\u{2028}", "\u{2029}", "\u{0B}", "\u{0C}", "\u{A0}", "\u{3000}", "。", "…", "(", "»", "1"]
        var generator = Generator(seed: 0xE5D)
        for _ in 0..<5_000 {
            agrees((0..<generator.next(7)).map { _ in pieces[generator.next(pieces.count)] }.joined())
        }
    }

    @Test func joiningTrimsSkipsEmptyPartsAndAttachesPunctuation() {
        #expect(TurnModel.joinedText(["  Hello", ",", "", " ", "world ", ".", "(aside)", ")", "ok"]) == "Hello, world. (aside)) ok")
        var joined = TurnModel.joinedText(["Hello"])
        TurnModel.appendJoined(" , ", to: &joined)
        TurnModel.appendJoined("\n", to: &joined)
        TurnModel.appendJoined("there!", to: &joined)
        #expect(joined == "Hello, there!")
        // A block of one word keeps the word as given; a second word joins both trimmed.
        #expect(TurnModel.readableBlocks([word(" Yes ", at: 0)]).map(\.text) == [" Yes "])
        #expect(TurnModel.readableBlocks([word(" Yes ", at: 0), word(",", at: 300)]).map(\.text) == ["Yes,"])
    }

    @Test func groupingMatchesTheReferenceOnVariedTranscripts() {
        var generator = Generator(seed: 0x5EED)
        for _ in 0..<300 {
            let words = generator.transcript(count: generator.next(400))
            #expect(Snapshot.of(TurnModel.readableBlocks(words)) == Snapshot.of(Reference.readableBlocks(words)))
        }
    }

    /// The thousand-note Library check's transcript: 120 words of one passage, one block.
    @Test func groupingMatchesTheReferenceOnTheLibraryCheckTranscript() {
        let vocabulary = ["delivery", "Thursday", "price", "supplier", "order", "warehouse", "meeting", "budget"]
        for note in [0, 1, 7, 500, 999] {
            let words = (0..<120).map { index in
                word(vocabulary[(index * 7 + note) % vocabulary.count] + "\(note % 13)", at: Double(index) * 500)
            }
            let blocks = TurnModel.readableBlocks(words)
            #expect(Snapshot.of(blocks) == Snapshot.of(Reference.readableBlocks(words)))
            #expect(blocks.count == 1)
        }
    }

    /// The first 20 minutes of the 11-hour transcript of `TurnModelLongTranscriptTests`, with its speakers and with
    /// none (blocks then grow to their 140-word limit).
    @Test(arguments: [true, false]) func groupingMatchesTheReferenceOnALongTranscript(speakers: Bool) {
        let gap = 3_600_000 / 9500
        let words = (0..<(20 * 60_000 / gap)).map { index in
            TurnModel.Word(speaker: speakers ? "speaker_\(1 + (index / 23) % 4)" : nil, startMs: Double(index * gap),
                           endMs: Double(index * gap + gap * 4 / 5), text: "word\(index)")
        }
        let blocks = TurnModel.readableBlocks(words)
        #expect(Snapshot.of(blocks) == Snapshot.of(Reference.readableBlocks(words)))
        #expect(blocks.map(\.words.count).max() == (speakers ? 23 : 140))
    }

    private func word(_ text: String, at startMs: Double, speaker: String? = nil) -> TurnModel.Word {
        TurnModel.Word(speaker: speaker, startMs: startMs, endMs: startMs + 250, text: text)
    }
}

/// What a block holds, comparable.
private struct Snapshot: Equatable {
    var id: Int, speaker: String?, startMs: Double, endMs: Double, text: String
    var words: [Int], wordValues: [TurnModel.Word]

    static func of(_ blocks: [TurnModel.Block]) -> [Snapshot] {
        blocks.map {
            Snapshot(id: $0.id, speaker: $0.speaker, startMs: $0.startMs, endMs: $0.endMs, text: $0.text,
                     words: $0.words.map(\.index), wordValues: $0.words.map(\.word))
        }
    }
}

/// Deterministic transcripts with what the grouping treats specially: punctuation that attaches or ends a sentence,
/// padded and empty words, blank and changing speakers, long gaps and times that are not finite.
private struct Generator {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next(_ bound: Int) -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int((state >> 33) % UInt64(bound))
    }

    static let vocabulary = [
        "so", "the", "delivery", "slips", "Thursday.", "Yes.", "okay", ",", ".", "?", "!", ")", "(aside)", "  padded  ",
        "", " ", "\n", "really?\"", "done.')", "naïve", "中文。", "wait…", "3.5", "end!", "and,", "Hi", "e\u{301}",
    ]
    static let speakers: [String?] = [nil, "A", "B", " ", "speaker_1"]

    mutating func transcript(count: Int) -> [TurnModel.Word] {
        var words: [TurnModel.Word] = []
        var time = Double(next(1000))
        var speaker = Self.speakers[next(Self.speakers.count)]
        for _ in 0..<count {
            if next(12) == 0 { speaker = Self.speakers[next(Self.speakers.count)] }
            switch next(20) {
            case 0: time += Double(2200 + next(3000)) // a pause that may end a paragraph or a block
            case 1: time += Double(40_000 + next(60_000))
            default: time += Double(next(600))
            }
            var start = time, end = time + Double(next(900))
            if next(60) == 0 { start = .nan }
            if next(60) == 0 { end = .infinity }
            if next(40) == 0 { end = time - 100 }
            words.append(TurnModel.Word(speaker: speaker, startMs: start, endMs: end,
                                        text: Self.vocabulary[next(Self.vocabulary.count)]))
        }
        return words
    }
}

/// The grouping as it was: a regular expression compiled per call, and a block's text joined again from its first
/// word after each word.
private enum Reference {
    typealias Block = TurnModel.Block

    static func readableBlocks(_ input: [TurnModel.Word]) -> [Block] {
        var grouped: [Block] = []
        var current: Block?
        for (index, rawWord) in input.enumerated() {
            var word = rawWord
            word.startMs = rawWord.startMs.isFinite ? rawWord.startMs.rounded(.towardZero) : 0
            word.endMs = rawWord.endMs.isFinite ? rawWord.endMs.rounded(.towardZero) : word.startMs
            if word.speaker?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true { word.speaker = nil }
            let item = TurnModel.TimedWord(index: index, word: word)
            if var block = current {
                let gap = max(0, word.startMs - block.endMs)
                let duration = max(0, word.endMs - block.startMs)
                let targetReached = block.words.count >= 96 || block.endMs - block.startMs >= 45_000
                let boundary = matches(block.text.trimmingCharacters(in: .whitespacesAndNewlines), #"[.!?]["')\]]*$"#) || gap >= 2200
                if block.speaker != word.speaker || gap > 4200 || duration > 90_000 || block.words.count + 1 > 140 || (targetReached && boundary) {
                    grouped.append(block)
                    current = Block(id: index, speaker: word.speaker, startMs: word.startMs,
                                    endMs: word.endMs, text: word.text, words: [item])
                } else {
                    block.words.append(item)
                    block.endMs = word.endMs
                    block.text = joinedText(block.words.map { $0.word.text })
                    current = block
                }
            } else {
                current = Block(id: index, speaker: word.speaker, startMs: word.startMs,
                                endMs: word.endMs, text: word.text, words: [item])
            }
        }
        if let current { grouped.append(current) }

        var merged: [Block] = []
        for block in grouped {
            guard var previous = merged.last else { merged.append(block); continue }
            let previousCount = TurnModel.textWordCount(previous.text)
            let currentCount = TurnModel.textWordCount(block.text)
            let small = previousCount < 18 || currentCount < 18 || max(0, previous.endMs - previous.startMs) < 8000 || max(0, block.endMs - block.startMs) < 8000
            if previous.speaker == block.speaker,
               max(0, block.startMs - previous.endMs) <= 4200,
               previousCount + currentCount <= 140,
               max(0, block.endMs - previous.startMs) <= 90_000, small {
                previous.endMs = block.endMs
                previous.text = joinedText([previous.text, block.text])
                previous.words += block.words
                merged[merged.count - 1] = previous
            } else {
                merged.append(block)
            }
        }
        return merged
    }

    static func joinedText(_ parts: [String]) -> String {
        var result = ""
        for part in parts {
            let part = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if !result.isEmpty && !matches(part, #"^[,.;:!?)]"#) { result += " " }
            result += part
        }
        return result
    }

    static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }
}
