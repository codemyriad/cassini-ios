import Foundation

/// What the user typed into the Library search, as the phrases every note must contain (Android `SearchQuery`,
/// features.md section 1).
///
/// Each whitespace-separated term is one phrase. Inside a term every character that is not a letter, a digit or a
/// combining mark breaks a token, as the index splits the notes there: `e-mail` is the phrase `e mail`, which matches
/// the indexed tokens `e` and `mail`, and `Thur.` is `Thur`. The last token of a phrase matches as a prefix
/// (`deliv` finds `delivery`), the others as whole tokens. Every phrase must match (AND, OR, NOT and NEAR are plain
/// words), and case and accents are ignored when matching but kept here as typed. A term with no letter or digit is
/// dropped; nothing searchable left means no query, and the Library shows every note.
public struct SearchQuery: Hashable, Sendable {
    /// The tokens of each phrase, in order, as typed.
    public let phrases: [[String]]
    /// The phrases with case and accents folded, as the index compares them.
    let folded: [[String]]

    /// Nil when nothing searchable is left.
    public init?(_ input: String) {
        let phrases = Self.terms(input).map(SearchTokens.split).filter { !$0.isEmpty }
        guard !phrases.isEmpty else { return nil }
        self.phrases = phrases
        folded = phrases.map { $0.map(SearchTokens.fold) }
    }

    /// Splits on any Unicode whitespace (no-break and ideographic spaces included), dropping empty pieces.
    private static func terms(_ input: String) -> [String] {
        input.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}

/// The tokenizer shared by the query and the index: runs of letters and digits, with combining marks kept in the
/// token they follow.
enum SearchTokens {
    /// The tokens of `text` with their ranges in it (on Unicode scalar boundaries).
    static func scan(_ text: String) -> [(range: Range<String.Index>, text: String)] {
        var tokens: [(range: Range<String.Index>, text: String)] = []
        var start: String.Index?
        var index = text.startIndex
        let scalars = text.unicodeScalars
        while index < scalars.endIndex {
            let scalar = scalars[index]
            if isTokenScalar(scalar) || (start != nil && isMark(scalar)) {
                if start == nil { start = index }
            } else if let open = start {
                tokens.append((open..<index, String(scalars[open..<index])))
                start = nil
            }
            index = scalars.index(after: index)
        }
        if let open = start { tokens.append((open..<scalars.endIndex, String(scalars[open...]))) }
        return tokens
    }

    static func split(_ term: String) -> [String] { scan(term).map(\.text) }

    /// Case and accents removed: `CAFÉ` and `cafe` compare equal.
    static func fold(_ token: some StringProtocol) -> String {
        token.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    private static func isTokenScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .decimalNumber:
            true
        default:
            false
        }
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }
}

/// Text with highlighted `ranges` (character offsets into `text`) and the ellipses that mark a cut at either end. The
/// ellipses are not part of `text`.
public struct Highlighted: Hashable, Sendable {
    public var text: String
    public var ranges: [Range<Int>]
    public var leadingEllipsis: Bool
    public var trailingEllipsis: Bool

    public init(_ text: String, ranges: [Range<Int>] = [], leadingEllipsis: Bool = false, trailingEllipsis: Bool = false) {
        self.text = text; self.ranges = ranges; self.leadingEllipsis = leadingEllipsis; self.trailingEllipsis = trailingEllipsis
    }

    /// Start of a match in a marked snippet.
    public static let matchStart: Character = "\u{2}"
    /// End of a match in a marked snippet.
    public static let matchEnd: Character = "\u{3}"
    /// Where a snippet is cut.
    public static let ellipsis: Character = "…"

    /// Reads a marked snippet: the `matchStart`/`matchEnd` markers become ranges and never reach the text, and an
    /// ellipsis at either end becomes a flag. An unclosed match runs to the end; a stray end marker and an empty match
    /// are ignored. A stored Library preview (no markers) reads the same way.
    public init(marked snippet: String) {
        let leading = snippet.first == Self.ellipsis
        let body = snippet.dropFirst(leading ? 1 : 0)
        let trailing = !body.isEmpty && body.last == Self.ellipsis
        var text = ""
        var ranges: [Range<Int>] = []
        var count = 0
        var openAt: Int?
        for character in body.dropLast(trailing ? 1 : 0) {
            switch character {
            case Self.matchStart:
                if openAt == nil { openAt = count }
            case Self.matchEnd:
                if let start = openAt, start < count { ranges.append(start..<count) }
                openAt = nil
            default:
                text.append(character)
                count += 1
            }
        }
        if let start = openAt, start < count { ranges.append(start..<count) }
        self.init(text, ranges: ranges, leadingEllipsis: leading, trailingEllipsis: trailing)
    }

    /// Flatten line breaks without changing character offsets, so search highlights survive row layout.
    public var singleLine: Highlighted {
        var copy = self
        copy.text = String(text.map { $0.isNewline ? Character(" ") : $0 })
        return copy
    }

    /// The text as shown: with its ellipses.
    public var display: String {
        (leadingEllipsis ? String(Self.ellipsis) : "") + text + (trailingEllipsis ? String(Self.ellipsis) : "")
    }
}
