import Foundation

/// One word of a transcript as the preview reads it.
public struct PreviewWord: Hashable, Sendable {
    public var text: String
    public var startMs: Int64
    public var endMs: Int64
    /// Who says it; nil when the passage has no speaker.
    public var speaker: String?
    public init(_ text: String, startMs: Int64, endMs: Int64, speaker: String? = nil) {
        self.text = text; self.startMs = startMs; self.endMs = endMs; self.speaker = speaker
    }
}

/// A Library preview excerpt. `text` has no ellipses; `leadingEllipsis` marks an excerpt that does not start at the
/// transcript start, `trailingEllipsis` one that was cut before the transcript end.
public struct Preview: Hashable, Sendable {
    public var text: String
    public var leadingEllipsis: Bool
    public var trailingEllipsis: Bool
    public init(_ text: String, leadingEllipsis: Bool = false, trailingEllipsis: Bool = false) {
        self.text = text; self.leadingEllipsis = leadingEllipsis; self.trailingEllipsis = trailingEllipsis
    }

    /// The excerpt as shown and stored in `Note.previewText`; `Highlighted(marked:)` reads it back.
    public var display: String {
        (leadingEllipsis ? "…" : "") + text + (trailingEllipsis ? "…" : "")
    }
}

/// The Library preview of a transcript without a search query (Android `PreviewText`, features.md section 1).
///
/// When the saved playback position is after the first word and before the end of the last word, the excerpt starts
/// at the word playing at that position and has a leading ellipsis. It takes whole words up to about `limit`
/// characters and stops at the first end of a speaker's turn reached once it holds at least `minBeforeTurnEnd`
/// characters, so one preview does not run two speakers' words together. A shorter turn ("Sì.") continues into the
/// next turns, so the row never shows a one-word excerpt while more words follow.
///
/// Otherwise (position 0, before or in the first word, or at or after the end of the last word, which is where a
/// finished playback leaves it) the excerpt is the transcript start: the first `limit` characters of the words joined
/// by spaces, cut at a word.
///
/// An excerpt that ends before the transcript end gets a trailing ellipsis, and the sentence punctuation at its end is
/// dropped first ("order." becomes "order…"). Lengths are UTF-16 units, as on Android.
public enum PreviewText {
    /// The excerpt budget in UTF-16 units, without the ellipses.
    public static let limit = 160
    /// An excerpt from the playing word stops at a turn end only once it has at least this many UTF-16 units.
    public static let minBeforeTurnEnd = 40

    static let cutPunctuation: Set<Character> = [".", ",", ";", ":", "!", "?", "…"]

    /// The preview of `words` (one transcript, in order) at `positionMs`; nil without words.
    public static func of(_ words: [PreviewWord], positionMs: Int64) -> Preview? {
        guard let last = words.last else { return nil }
        let first = positionMs >= last.endMs ? 0 : playing(words, positionMs)
        return excerpt(words[first...], leading: first > 0, reachesEnd: true)
    }

    /// The excerpt that starts with the first of `words`. `leading` when words come before it; `reachesEnd` when
    /// `words` run to the transcript end, so running out of them is not a cut.
    static func excerpt(_ words: ArraySlice<PreviewWord>, leading: Bool, reachesEnd: Bool) -> Preview {
        var text = ""
        var length = 0
        var next = words.startIndex
        while next < words.endIndex, next == words.startIndex || length + 1 + words[next].text.utf16.count <= limit {
            if leading, next > words.startIndex, stopsBefore(words, next, length) { break }
            if next > words.startIndex { text += " "; length += 1 }
            text += words[next].text
            length += words[next].text.utf16.count
            next += 1
        }
        let cut = next < words.endIndex || !reachesEnd
        var shown = cutAt(text, limit)
        if cut {
            let trimmed = String(shown.reversed().drop { cutPunctuation.contains($0) }.reversed())
            if !trimmed.isEmpty { shown = trimmed }
        }
        return Preview(shown, leadingEllipsis: leading, trailingEllipsis: cut || shown.utf16.count < length)
    }

    /// The word playing at `positionMs`: the first word that has not ended there. Within a word that is the word
    /// itself; in a pause it is the next word to play. `of` handles a position after the last word.
    private static func playing(_ words: [PreviewWord], _ positionMs: Int64) -> Int {
        words.firstIndex { $0.endMs > positionMs } ?? 0
    }

    /// Whether an excerpt of `length` units ends before `index`, which starts another speaker's turn.
    private static func stopsBefore(_ words: ArraySlice<PreviewWord>, _ index: Int, _ length: Int) -> Bool {
        length >= minBeforeTurnEnd && words[index].speaker != words[index - 1].speaker
    }

    /// `text` cut to at most `limit` UTF-16 units, never inside a surrogate pair (only one giant word needs it).
    private static func cutAt(_ text: String, _ limit: Int) -> String {
        let units = Array(text.utf16)
        guard units.count > limit else { return text }
        let end = UTF16.isLeadSurrogate(units[limit - 1]) ? limit - 1 : limit
        return String(decoding: units[..<end], as: UTF16.self)
    }
}

extension Note {
    /// The Library preview at the saved playback position, from the transcript shown. Only the words it can show are
    /// read: the transcript start, or the words from the one playing at the position.
    public var transcriptPreview: Preview? {
        let positionMs = Int64((playbackPosition * 1000).rounded(.down))
        let segments = transcript.lazy.map(PreviewWord.of)
        guard let lastEnd = segments.last(where: { !$0.isEmpty })?.last?.endMs else { return nil }
        let fromStart = positionMs >= lastEnd
        // The first passage with a word still to end at the position, and that word in it.
        let segment = fromStart ? 0 : transcript.firstIndex { passage in
            passage.end * 1000 >= Double(positionMs) && PreviewWord.of(passage).contains { $0.endMs > positionMs }
        } ?? 0
        let firstInSegment = PreviewWord.of(transcript[segment]).firstIndex { fromStart || $0.endMs > positionMs } ?? 0
        let earlierWords = firstInSegment > 0 || transcript[..<segment].contains { $0.text.contains { !$0.isWhitespace } }
        var words = Array(PreviewWord.of(transcript[segment]).dropFirst(firstInSegment))
        var next = segment + 1
        // Enough words for the budget and one more, so the excerpt's cut is decided by the words themselves.
        while next < transcript.endIndex, words.reduce(0, { $0 + $1.text.utf16.count + 1 }) <= PreviewText.limit + 1 {
            words += PreviewWord.of(transcript[next])
            next += 1
        }
        guard !words.isEmpty else { return nil }
        return PreviewText.excerpt(words[...], leading: earlierWords && !fromStart, reachesEnd: next == transcript.endIndex)
    }
}

extension PreviewWord {
    /// The words of a passage: its text split at whitespace, each timed from the recognised words it overlaps, or
    /// spread over the passage when it has none (an edited passage keeps no word times).
    static func of(_ segment: TranscriptSegment) -> [PreviewWord] {
        let text = segment.text
        let speaker = segment.speakerID ?? segment.speaker
        var timed: [(range: Range<String.Index>, start: Double, end: Double)] = []
        var cursor = text.startIndex
        for word in segment.words {
            let piece = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty, let range = text.range(of: piece, range: cursor..<text.endIndex) else { continue }
            timed.append((range, word.start, word.end))
            cursor = range.upperBound
        }
        let pieces = text.split(whereSeparator: \.isWhitespace)
        let length = Double(max(1, text.count))
        return pieces.map { piece in
            let range = piece.startIndex..<piece.endIndex
            let overlapping = timed.filter { $0.range.overlaps(range) }
            let start: Double, end: Double
            if let first = overlapping.first, let last = overlapping.last {
                start = first.start; end = last.end
            } else {
                let offset = Double(text.distance(from: text.startIndex, to: range.lowerBound))
                let span = segment.end - segment.start
                start = segment.start + span * offset / length
                end = segment.start + span * (offset + Double(piece.count)) / length
            }
            return PreviewWord(String(piece), startMs: Int64((start * 1000).rounded()), endMs: Int64((end * 1000).rounded()),
                               speaker: speaker)
        }
    }
}
