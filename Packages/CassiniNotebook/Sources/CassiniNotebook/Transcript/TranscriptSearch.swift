import Foundation

/// One search hit: a character range of the paragraph text (`NoteTurn.text`) of paragraph `turnID`.
public struct TranscriptMatch: Hashable, Sendable {
    public var turnID: String
    public var range: Range<Int>
    public init(turnID: String, range: Range<Int>) { self.turnID = turnID; self.range = range }
}

/// In-note search (Android `TranscriptSearch`): case- and diacritic-insensitive matching over each paragraph's speech,
/// with ranges on the text as shown. "cafe" finds "café", "DELIVERY" finds "delivery".
public enum TranscriptSearch {
    /// Every match of `query` in `turns`, in text order. A blank query matches nothing; matches do not overlap.
    public static func matches(_ turns: [NoteTurn], query: String) -> [TranscriptMatch] {
        let needle = fold(query.trimmingCharacters(in: .whitespacesAndNewlines)).text
        guard !needle.isEmpty else { return [] }
        var result: [TranscriptMatch] = []
        for turn in turns {
            let folded = spoken(turn)
            let haystack = folded.text
            guard haystack.count >= needle.count else { continue }
            var at = 0
            while at + needle.count <= haystack.count {
                if haystack[at] == needle[0], haystack[at..<(at + needle.count)].elementsEqual(needle) {
                    result.append(TranscriptMatch(turnID: turn.id, range: folded.source[at]..<(folded.source[at + needle.count - 1] + 1)))
                    at += needle.count
                } else {
                    at += 1
                }
            }
        }
        return result
    }

    /// Search actual words, keeping the rendered offsets across inline speaker labels and parentheses.
    /// A label rename must not create a match; a phrase crossing a chip still maps to its real first/last words.
    private static func spoken(_ turn: NoteTurn) -> Folded {
        guard !turn.interjections.isEmpty else { return fold(turn.text) }
        var result = Folded(text: [], source: [])
        result.text.reserveCapacity(turn.text.count)
        result.source.reserveCapacity(turn.text.count)
        var previousEnd = 0
        for (index, word) in turn.words.enumerated() {
            let offset = turn.offsets[index]
            if index > 0 && offset > previousEnd {
                result.text.append(" ")
                result.source.append(offset - 1)
            }
            previousEnd = max(previousEnd, offset + word.text.count)
            let piece = fold(word.text)
            result.text.append(contentsOf: piece.text)
            for position in piece.source { result.source.append(offset + position) }
        }
        return result
    }

    /// `text` lower-cased without diacritics, as characters; `source[i]` is the character of `text` that character
    /// `i` came from. A character that folds to several keeps its source for each.
    struct Folded {
        var text: [Character]
        var source: [Int]
    }

    static func fold(_ text: String) -> Folded {
        var folded: [Character] = [], source: [Int] = []
        folded.reserveCapacity(text.count); source.reserveCapacity(text.count)
        for (index, character) in text.enumerated() {
            if character.isASCII {
                folded.append(Character(character.lowercased())); source.append(index)
                continue
            }
            for piece in String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                                                   locale: nil) {
                folded.append(piece); source.append(index)
            }
        }
        return Folded(text: folded, source: source)
    }
}

/// The search field's state on the Note screen: the query and which match is current. The counter shows
/// `current + 1` of the total ("3 of 12"); previous and next wrap around.
public struct InNoteSearch: Hashable, Sendable {
    public var query: String
    public var current = 0

    /// A search opened with `query` (prefilled from the Library: trimmed).
    public init(query: String = "") { self.query = query.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// A new query starts again from the first match.
    public mutating func setQuery(_ query: String) {
        guard query != self.query else { return }
        self.query = query
        current = 0
    }

    /// `current` kept inside `0..<total`.
    public func current(of total: Int) -> Int { total == 0 ? 0 : min(max(current, 0), total - 1) }

    public mutating func next(of total: Int) {
        guard total > 0 else { return }
        current = (current(of: total) + 1) % total
    }

    public mutating func previous(of total: Int) {
        guard total > 0 else { return }
        current = (current(of: total) - 1 + total) % total
    }
}
