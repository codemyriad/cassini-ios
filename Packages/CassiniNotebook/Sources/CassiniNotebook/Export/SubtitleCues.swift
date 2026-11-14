import CassiniCore
import Foundation

/// One subtitle cue. `text` is the cue's words joined with one space, in canonical order. `prefix` is the SRT label
/// prefix (`"<label>: "`) or empty. `lines` is `prefix + text` in one line, or two lines when it is over
/// `SubtitleCues.lineLength` characters.
public struct Cue: Hashable, Sendable {
    public var speaker: String
    public var label: String
    public var startMs: Int64
    public var endMs: Int64
    public var text: String
    public var prefix: String
    public var lines: [String]
}

/// Splits a transcript into subtitle cues for `SrtWriter` and `VttWriter` (features.md section 9). Lengths are
/// counted in UTF-16 units, as on Android.
public enum SubtitleCues {
    /// A silence of at least this long between two words starts a new cue.
    public static let pauseMs: Int64 = 1500
    /// A cue never runs longer than this from its start to the end of its last word.
    public static let maxSpanMs: Int64 = 6000
    /// The longest cue text in characters, with the SRT label prefix of a speaker's first cue.
    public static let maxText = 84
    /// A sentence end starts a new cue once the cue lasts at least this long.
    public static let sentenceMs: Int64 = 1500
    /// The shortest cue on screen, unless the speaker's next cue starts before.
    public static let minDurationMs: Int64 = 1000
    /// The longest line before a cue is split in two.
    public static let lineLength = 42

    private static let sentenceEnds: Set<Character> = [".", "?", "!", "…", "。", "？", "！"]

    /// The cues of `t`. Words are read in canonical order; a new cue starts before word `w` when (1) the speaker
    /// changes, (2) the silence before `w` is at least `pauseMs`, (3) `w` would end more than `maxSpanMs` after the
    /// cue start, (4) the text would be longer than `maxText`, or (5) the previous word ends a sentence and the cue
    /// already lasts `sentenceMs`. With `labelPrefixForSrt` and 2 or more speakers, rule (4) counts the SRT label
    /// prefix in the first cue of each turn.
    ///
    /// A cue starts at its first word's start and ends at the latest end of its words, lengthened to `minDurationMs`
    /// but never past the start of the same speaker's next cue, so one speaker's cues never overlap. Different
    /// speakers' cues may overlap. The cues are sorted by start with a stable sort, and the words inside a cue keep
    /// their canonical order.
    ///
    /// With `labelPrefixForSrt` and 2 or more speakers, a cue gets the prefix when its speaker differs from the cue
    /// before it in this sorted order (the first cue always does).
    public static func build(_ t: ExportTranscript, labelPrefixForSrt: Bool) -> [Cue] {
        let prefixed = labelPrefixForSrt && t.speakerCount >= 2
        var drafts: [Draft] = []
        var previous: Word?
        for word in t.words {
            if let prev = previous, let last = drafts.indices.last, !breaksBefore(drafts[last], prev, word) {
                drafts[last].add(word)
            } else {
                let budget = prefixed && previous.map({ Data($0.speaker.utf8) }) != Data(word.speaker.utf8) ? prefix(t, word.speaker).utf16.count : 0
                drafts.append(Draft(word, prefixLength: budget))
            }
            previous = word
        }
        let sorted = drafts.enumerated()
            .sorted { $0.element.startMs != $1.element.startMs ? $0.element.startMs < $1.element.startMs : $0.offset < $1.offset }
            .map(\.element)
        var nextStarts = [Int64?](repeating: nil, count: sorted.count)
        var following: [Data: Int64] = [:]
        for index in sorted.indices.reversed() {
            nextStarts[index] = following[Data(sorted[index].speaker.utf8)]
            following[Data(sorted[index].speaker.utf8)] = sorted[index].startMs
        }
        var shownSpeaker: String?
        return sorted.enumerated().map { index, draft in
            let cuePrefix = prefixed && Data(draft.speaker.utf8) != shownSpeaker.map({ Data($0.utf8) }) ? prefix(t, draft.speaker) : ""
            shownSpeaker = draft.speaker
            let text = draft.words.lazy.map(\.text).joined(separator: " ")
            return Cue(speaker: draft.speaker, label: t.label(draft.speaker), startMs: draft.startMs,
                       endMs: end(of: draft, nextStart: nextStarts[index]), text: text, prefix: cuePrefix,
                       lines: lines(cuePrefix + text, from: cuePrefix.utf16.count))
        }
    }

    /// `text` as one line when it fits `lineLength`, else as two lines split at a space at or after `from`: the
    /// space that best balances two lines of at most `lineLength` (on a tie the shorter first line), else the last
    /// space that keeps the first line within `lineLength`, else the first space. Text without such a space stays one
    /// line. Words are never dropped and there are never three lines.
    public static func lines(_ text: String, from: Int = 0) -> [String] {
        let units = Array(text.utf16)
        let space = UInt16(UInt8(ascii: " "))
        let spaces = units.indices.filter { $0 >= from && units[$0] == space }
        guard units.count > lineLength, let firstSpace = spaces.first else { return [text] }
        let balanced = spaces
            .filter { $0 <= lineLength && units.count - $0 - 1 <= lineLength }
            .min { abs(units.count - 1 - 2 * $0) < abs(units.count - 1 - 2 * $1) }
        let at = balanced ?? spaces.last { $0 <= lineLength } ?? firstSpace
        return [String(decoding: units[..<at], as: UTF16.self), String(decoding: units[(at + 1)...], as: UTF16.self)]
    }

    private static func prefix(_ t: ExportTranscript, _ speaker: String) -> String { t.label(speaker) + ": " }

    private static func breaksBefore(_ cue: Draft, _ prev: Word, _ word: Word) -> Bool {
        Data(word.speaker.utf8) != Data(prev.speaker.utf8)
            || word.startMs - prev.endMs >= pauseMs
            || word.endMs - cue.startMs > maxSpanMs
            || cue.length + 1 + word.text.utf16.count > maxText
            || (endsSentence(prev.text) && cue.endMs - cue.startMs >= sentenceMs)
    }

    /// The last character of `text` before trailing whitespace ends a sentence.
    private static func endsSentence(_ text: String) -> Bool {
        text.last { !$0.isWhitespace }.map(sentenceEnds.contains) ?? false
    }

    private static func end(of draft: Draft, nextStart: Int64?) -> Int64 {
        let end = max(draft.endMs, draft.startMs + minDurationMs)
        return nextStart.map { min(end, $0) } ?? end
    }

    private struct Draft {
        let speaker: String
        let startMs: Int64
        private(set) var words: [Word]
        private(set) var endMs: Int64
        private(set) var length: Int

        init(_ first: Word, prefixLength: Int) {
            speaker = first.speaker; startMs = first.startMs; words = [first]; endMs = first.endMs
            length = prefixLength + first.text.utf16.count
        }

        mutating func add(_ word: Word) {
            words.append(word)
            endMs = max(endMs, word.endMs)
            length += 1 + word.text.utf16.count
        }
    }
}
