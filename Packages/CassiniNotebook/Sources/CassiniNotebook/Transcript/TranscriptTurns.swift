import Foundation

/// One transcript word as the Note screen reads it: its text without surrounding white space, when it starts and ends
/// in the audio, its speaker (nil for a passage without one) and the passage it came from.
public struct TranscriptWord: Hashable, Sendable {
    public var speaker: String?
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String
    /// Whether the word is set apart from the one before it by a space. False only where the source wrote the two
    /// together, such as a full stop given as its own word.
    public var spaceBefore: Bool
    /// The passage the word belongs to; nil for draft words.
    public var segmentID: UUID?

    public init(speaker: String?, start: TimeInterval, end: TimeInterval, text: String, spaceBefore: Bool = true,
                segmentID: UUID? = nil) {
        self.speaker = speaker; self.start = start; self.end = end; self.text = text
        self.spaceBefore = spaceBefore; self.segmentID = segmentID
    }
}

/// A maximal run of consecutive words with the same speaker (Android core `Turn`).
public struct TranscriptTurn: Hashable, Sendable {
    public var speaker: String?
    public var start: TimeInterval
    public var end: TimeInterval
    public var words: [TranscriptWord]

    /// The words joined as the paragraph shows them.
    public var text: String { TranscriptTurns.text(of: words) }
}

/// Splits a transcript into turns (Android core `TranscriptTurns`).
public enum TranscriptTurns {
    /// The turns of `words`, in order. A turn starts at its first word's start and ends at its last word's end, even
    /// when an earlier word of the turn ends later.
    public static func of(_ words: [TranscriptWord]) -> [TranscriptTurn] {
        var turns: [TranscriptTurn] = []
        var from = 0
        while from < words.count {
            var to = from + 1
            while to < words.count, words[to].speaker == words[from].speaker { to += 1 }
            let run = Array(words[from..<to])
            turns.append(TranscriptTurn(speaker: run[0].speaker, start: run[0].start, end: run[run.count - 1].end, words: run))
            from = to
        }
        return turns
    }

    /// `words` joined: a space before each word but the first, unless the word is written onto the one before.
    public static func text(of words: [TranscriptWord]) -> String {
        var text = ""
        for (index, word) in words.enumerated() {
            if index > 0, word.spaceBefore { text += " " }
            text += word.text
        }
        return text
    }

    /// Punctuation that closes onto the word before it when the source gives it as a word of its own.
    static let closing: Set<Character> = [".", ",", ";", ":", "!", "?", "…", ")", "]", "»", "”", "’", "%", "。", "，", "？", "！"]
}

extension Note {
    /// The words of the shown transcript in order, each with its passage's speaker. A passage without word times is one
    /// word of its whole text.
    public var transcriptWords: [TranscriptWord] { transcript.transcriptWords }
}

extension Array where Element == TranscriptSegment {
    /// See `Note.transcriptWords`.
    public var transcriptWords: [TranscriptWord] {
        var words: [TranscriptWord] = []
        for segment in self {
            guard !segment.words.isEmpty else {
                let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                words.append(TranscriptWord(speaker: segment.speakerID, start: segment.start, end: segment.end, text: text,
                                            segmentID: segment.id))
                continue
            }
            // A passage starts apart from the one before. Inside it, a word joins the one before only when the source
            // put no space between them and it starts with closing punctuation.
            var spaced = true
            var first = true
            for word in segment.words {
                let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if word.text.first?.isWhitespace == true { spaced = true }
                guard !text.isEmpty else { continue }
                let joins = !first && !spaced && text.first.map(TranscriptTurns.closing.contains) == true
                words.append(TranscriptWord(speaker: segment.speakerID, start: word.start, end: word.end, text: text,
                                            spaceBefore: !joins, segmentID: segment.id))
                first = false
                spaced = word.text.last?.isWhitespace ?? false
            }
        }
        return words
    }
}
