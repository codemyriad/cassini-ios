import Foundation

/// One searchable field of a note (its title, its transcript, its bookmark labels), split into tokens once so a search
/// only compares them. It stands in for Android's FTS4 `note_fts` column (`unicode61`, `remove_diacritics=1`).
public struct SearchText: Sendable {
    public let text: String
    private let ranges: [Range<String.Index>]
    private let folded: [String]

    public init(_ text: String) {
        self.text = text
        let tokens = SearchTokens.scan(text)
        ranges = tokens.map(\.range)
        folded = tokens.map { SearchTokens.fold($0.text) }
    }

    /// Whether `phrase` (folded tokens) is in the text: its tokens follow each other, the last one as a prefix.
    func contains(_ phrase: [String]) -> Bool { !starts(of: phrase).isEmpty }

    /// The token positions where `phrase` starts.
    private func starts(of phrase: [String]) -> [Int] {
        guard let last = phrase.last, folded.count >= phrase.count else { return [] }
        let whole = phrase.dropLast()
        return (0...(folded.count - phrase.count)).filter { start in
            zip(whole, folded[start...]).allSatisfy { $0 == $1 } && folded[start + whole.count].hasPrefix(last)
        }
    }

    /// The text around the matches of `phrases` (folded), as SQLite's FTS `snippet()` builds it: at most `tokens`
    /// tokens, every matched token between `Highlighted.matchStart` and `matchEnd`, and `…` where the text is cut. The
    /// window covers the most phrases, then is moved so the matches sit near its middle. Without a match it is the
    /// start of the text.
    func snippet(_ phrases: [[String]], tokens size: Int) -> String {
        guard !ranges.isEmpty else { return text }
        let hits = phrases.map { phrase in starts(of: phrase).map { $0..<($0 + phrase.count) } }
        var start = bestStart(hits, size: size)
        let highlighted = Set(hits.joined().flatMap { Array($0) })
        start = centred(start, size: size, highlighted: highlighted)
        let end = min(start + size, ranges.count)

        var out = ""
        if start > 0 { out.append(Highlighted.ellipsis) } else { out += text[..<ranges[0].lowerBound] }
        for position in start..<end {
            if position > start { out += text[ranges[position - 1].upperBound..<ranges[position].lowerBound] }
            let lit = highlighted.contains(position)
            if lit { out.append(Highlighted.matchStart) }
            out += text[ranges[position]]
            if lit { out.append(Highlighted.matchEnd) }
        }
        if end < ranges.count { out.append(Highlighted.ellipsis) } else { out += text[ranges[end - 1].upperBound...] }
        return out
    }

    /// The first window start that covers the most phrases (each counts 1000, each further hit 1), as FTS tries the
    /// window at the text start and the windows that end at each hit.
    private func bestStart(_ hits: [[Range<Int>]], size: Int) -> Int {
        let candidates = [0] + hits.joined().map { $0.lowerBound - size + 1 }.sorted()
        var best = 0, bestScore = -1
        for candidate in candidates {
            let window = candidate..<(candidate + size)
            let score = hits.reduce(0) { score, phrase in
                let inside = phrase.filter { window.contains($0.lowerBound) && $0.upperBound <= window.upperBound }.count
                return score + (inside > 0 ? 1000 + inside - 1 : 0)
            }
            if score > bestScore { best = candidate; bestScore = score }
        }
        return max(0, best)
    }

    /// Moves the window towards the end when that brings its highlighted tokens nearer its middle, as far as there
    /// are tokens after it.
    private func centred(_ start: Int, size: Int, highlighted: Set<Int>) -> Int {
        let inside = highlighted.filter { $0 >= start && $0 < start + size }
        guard let first = inside.min(), let last = inside.max() else { return start }
        let left = first - start, right = start + size - 1 - last
        let wanted = (left - right) / 2
        guard wanted > 0 else { return start }
        let after = max(0, ranges.count - (start + size))
        return start + min(wanted, after)
    }
}

/// The searchable fields of one note.
public struct SearchFields: Sendable {
    public let title: SearchText
    /// The transcript shown (the selected version's).
    public let body: SearchText
    /// Bookmark labels, an iOS extra.
    public let bookmarks: SearchText

    public init(title: String, body: String, bookmarks: [String] = []) {
        self.title = SearchText(title)
        self.body = SearchText(body)
        self.bookmarks = SearchText(bookmarks.joined(separator: "\n"))
    }

    public init(_ note: Note) {
        self.init(title: note.title, body: note.text, bookmarks: note.bookmarks.map(\.label))
    }

    /// Whether every phrase is in one of the fields (each phrase may be in another).
    public func matches(_ query: SearchQuery) -> Bool {
        query.folded.allSatisfy { phrase in
            title.contains(phrase) || body.contains(phrase) || bookmarks.contains(phrase)
        }
    }

    /// The transcript around the matches, 15 tokens (Android `snippet(note_fts, …, 1, 15)`).
    public func snippet(_ query: SearchQuery) -> String { body.snippet(query.folded, tokens: 15) }

    /// The title with its matches marked, 64 tokens (Android `snippet(note_fts, …, 0, 64)`).
    public func titleSnippet(_ query: SearchQuery) -> String { title.snippet(query.folded, tokens: 64) }
}
