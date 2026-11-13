import Foundation

/// One searchable field of a note (its title, its transcript, its bookmark labels), split into tokens once so a search
/// only compares them. It stands in for Android's FTS4 `note_fts` column (`unicode61`, `remove_diacritics=1`).
public struct SearchText: Sendable {
    public let text: String
    /// The text's UTF-8 bytes, and each token's byte range in them.
    private let utf8: [UInt8]
    private let ranges: [Range<Int>]
    /// The folded tokens' UTF-8 bytes one after another; token `i` is `bytes[offsets[i]..<offsets[i + 1]]`. Byte
    /// comparisons keep a search of a thousand notes within a frame.
    private let bytes: [UInt8]
    private let offsets: [Int]

    public init(_ text: String) {
        self.text = text
        let tokens = SearchTokens.scan(text)
        utf8 = Array(text.utf8)
        ranges = tokens.map { text.utf8.distance(from: text.startIndex, to: $0.range.lowerBound)
            ..< text.utf8.distance(from: text.startIndex, to: $0.range.upperBound) }
        var bytes: [UInt8] = [], offsets = [0]
        for token in tokens {
            bytes += SearchTokens.fold(token.text).utf8
            offsets.append(bytes.count)
        }
        self.bytes = bytes; self.offsets = offsets
    }

    /// Whether `phrase` (folded tokens) is in the text: its tokens follow each other, the last one as a prefix.
    func contains(_ phrase: [String]) -> Bool { !positions(of: phrase, firstOnly: true).isEmpty }

    /// The token positions where `phrase` starts.
    private func starts(of phrase: [String]) -> [Int] { positions(of: phrase, firstOnly: false) }

    private func positions(of phrase: [String], firstOnly: Bool) -> [Int] {
        let phrase = phrase.map { Array($0.utf8) }
        let last = ranges.count - phrase.count
        guard last >= 0, !phrase.isEmpty, phrase.allSatisfy({ !$0.isEmpty }) else { return [] }
        var found: [Int] = []
        bytes.withUnsafeBufferPointer { bytes in
            offsets.withUnsafeBufferPointer { offsets in
                let lead = phrase[0][0]
                var start = 0
                while start <= last {
                    if bytes[offsets[start]] == lead, matches(phrase, at: start, bytes, offsets) {
                        found.append(start)
                        if firstOnly { return }
                    }
                    start += 1
                }
            }
        }
        return found
    }

    /// Whether the tokens from `start` are `phrase`'s: the same bytes, the last one as a prefix.
    private func matches(_ phrase: [[UInt8]], at start: Int, _ bytes: UnsafeBufferPointer<UInt8>,
                         _ offsets: UnsafeBufferPointer<Int>) -> Bool {
        for (offset, token) in phrase.enumerated() {
            let begin = offsets[start + offset], length = offsets[start + offset + 1] - begin
            guard offset < phrase.count - 1 ? length == token.count : length >= token.count else { return false }
            let same = token.withUnsafeBufferPointer { memcmp(bytes.baseAddress! + begin, $0.baseAddress!, token.count) == 0 }
            if !same { return false }
        }
        return true
    }

    /// The text around the matches of `phrases` (folded), as SQLite's FTS `snippet()` builds it: at most `tokens`
    /// tokens, every matched token between `Highlighted.matchStart` and `matchEnd`, and `…` where the text is cut. The
    /// window covers the most phrases, then is moved so the matches sit near its middle. Without a match it is the
    /// start of the text.
    func snippet(_ phrases: [[String]], tokens size: Int) -> String {
        guard !ranges.isEmpty else { return text }
        var hits: [[Int]] = [], lengths: [Int] = [], marked = Set<Int>()
        for phrase in phrases {
            let starts = starts(of: phrase)
            hits.append(starts)
            lengths.append(phrase.count)
            for start in starts { for token in start..<(start + phrase.count) { marked.insert(token) } }
        }
        let highlighted = marked.sorted()
        let start = centred(bestStart(hits, lengths: lengths, size: size), size: size, highlighted: highlighted)
        let end = min(start + size, ranges.count)

        // The text runs between the highlighted tokens are copied whole, the marks put around each highlight.
        var out: [UInt8] = []
        out.reserveCapacity(utf8.count < 512 ? utf8.count + 16 : 512)
        var cursor = 0
        func copy(_ range: Range<Int>) { out.append(contentsOf: utf8[range]) }
        if start > 0 { out.append(contentsOf: String(Highlighted.ellipsis).utf8); cursor = ranges[start].lowerBound }
        for position in highlighted where position >= start && position < end {
            copy(cursor..<ranges[position].lowerBound)
            out.append(contentsOf: String(Highlighted.matchStart).utf8)
            copy(ranges[position])
            out.append(contentsOf: String(Highlighted.matchEnd).utf8)
            cursor = ranges[position].upperBound
        }
        let cut = end < ranges.count
        copy(cursor..<(cut ? ranges[end - 1].upperBound : utf8.count))
        if cut { out.append(contentsOf: String(Highlighted.ellipsis).utf8) }
        return String(decoding: out, as: UTF8.self)
    }

    /// The first window start that covers the most phrases (each counts 1000, each further hit 1), as FTS tries the
    /// window at the text start and the windows that end at each hit. `hits` holds each phrase's starts in token
    /// order, `lengths` its number of tokens.
    private func bestStart(_ hits: [[Int]], lengths: [Int], size: Int) -> Int {
        var candidates = [0]
        for starts in hits { for start in starts { candidates.append(start - size + 1) } }
        candidates.sort()
        var best = 0, bestScore = -1
        for candidate in candidates {
            var score = 0
            for phrase in hits.indices {
                // Hits that start in the window and end inside it.
                let inside = count(hits[phrase], from: candidate, through: candidate + size - lengths[phrase])
                if inside > 0 { score += 1000 + inside - 1 }
            }
            if score > bestScore { best = candidate; bestScore = score }
        }
        return max(0, best)
    }

    /// How many of the sorted `positions` are in `low...high`.
    private func count(_ positions: [Int], from low: Int, through high: Int) -> Int {
        guard low <= high else { return 0 }
        return firstIndex(in: positions, notBelow: high + 1) - firstIndex(in: positions, notBelow: low)
    }

    private func firstIndex(in positions: [Int], notBelow value: Int) -> Int {
        var low = 0, high = positions.count
        while low < high {
            let middle = (low + high) / 2
            if positions[middle] < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// Moves the window towards the end when that brings its highlighted tokens (sorted) nearer its middle, as far as
    /// there are tokens after it.
    private func centred(_ start: Int, size: Int, highlighted: [Int]) -> Int {
        let inside = highlighted.filter { $0 >= start && $0 < start + size }
        guard let first = inside.first, let last = inside.last else { return start }
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
    /// Bookmark labels, an iOS extra: one text each, so a phrase never runs from one label into the next.
    public let bookmarks: [SearchText]

    public init(title: String, body: String, bookmarks: [String] = []) {
        self.title = SearchText(title)
        self.body = SearchText(body)
        self.bookmarks = bookmarks.map(SearchText.init)
    }

    public init(_ note: Note) {
        // Synthetic inline-speaker labels are presentation, not speech. A single line also keeps paragraph
        // breaks from consuming the result preview's two lines before the highlighted word appears.
        self.init(title: note.title,
                  body: NoteTranscripts.sealed(note).turns.lazy.flatMap(\.words).map(\.text).joined(separator: " "),
                  bookmarks: note.bookmarks.compactMap(\.label))
    }

    /// Whether every phrase is in one of the fields (each phrase may be in another).
    public func matches(_ query: SearchQuery) -> Bool {
        query.folded.allSatisfy { phrase in
            title.contains(phrase) || body.contains(phrase) || bookmarks.contains { $0.contains(phrase) }
        }
    }

    /// The transcript around the matches, 15 tokens (Android `snippet(note_fts, …, 1, 15)`).
    public func snippet(_ query: SearchQuery) -> String { body.snippet(query.folded, tokens: 15) }

    /// The title with its matches marked, 64 tokens (Android `snippet(note_fts, …, 0, 64)`); without a match in it,
    /// the title as it is.
    public func titleSnippet(_ query: SearchQuery) -> String {
        let phrases = query.folded
        return phrases.contains(where: title.contains) ? title.snippet(phrases, tokens: 64) : title.text
    }
}
