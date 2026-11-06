import Foundation
import Testing
@testable import CassiniNotebook

/// Android `SearchQueryTest`. iOS searches an in-memory index instead of FTS4, so the parsed phrases are written in
/// the FTS form Android builds (`"e mail*"`) and compared with Android's expected strings unchanged.
struct SearchQueryTests {
    private func fts(_ input: String) -> String? {
        SearchQuery(input)?.phrases.map { "\"" + $0.joined(separator: " ") + "*\"" }.joined(separator: " ")
    }

    private func text(_ highlighted: Highlighted, _ range: Range<Int>) -> String {
        String(Array(highlighted.text)[range])
    }

    // ports: SearchQueryTest#golden
    @Test func golden() {
        #expect(fts("delivery Thur") == "\"delivery*\" \"Thur*\"")
    }

    // ports: SearchQueryTest#quotesAndStarsAreDropped
    @Test func quotesAndStarsAreDropped() {
        #expect(fts("\"delivery Thur\"") == "\"delivery*\" \"Thur*\"")
        #expect(fts("deli*") == "\"deli*\"")
        #expect(fts("*deli**") == "\"deli*\"")
        #expect(fts("delivery \" *") == "\"delivery*\"")
    }

    // ports: SearchQueryTest#ftsOperatorsAreDropped
    @Test func ftsOperatorsAreDropped() {
        #expect(fts("^start") == "\"start*\"")
        #expect(fts("body:price") == "\"body price*\"")
        #expect(fts("(a) (b)") == "\"a*\" \"b*\"")
        #expect(fts("-price") == "\"price*\"")
        #expect(fts("deli*very") == "\"deli very*\"")
        #expect(fts("-- : () ^ \"\" *") == nil)
    }

    // ports: SearchQueryTest#innerPunctuationSplitsTokensAsTheTokenizerDoes
    @Test func innerPunctuationSplitsTokensAsTheTokenizerDoes() {
        #expect(fts("e-mail follow- -up") == "\"e mail*\" \"follow*\" \"up*\"")
        #expect(fts("follow-up") == "\"follow up*\"")
        #expect(fts("we're") == "\"we re*\"")
        #expect(fts("snake_case") == "\"snake case*\"")
    }

    // ports: SearchQueryTest#trailingPunctuationKeepsThePrefixMatch
    @Test func trailingPunctuationKeepsThePrefixMatch() {
        #expect(fts("deliv,") == "\"deliv*\"")
        #expect(fts("Thur.") == "\"Thur*\"")
        #expect(fts("¿really?!") == "\"really*\"")
    }

    // ports: SearchQueryTest#combiningMarksStayInTheirToken
    @Test func combiningMarksStayInTheirToken() {
        #expect(fts("café.") == "\"café*\"")
        #expect(fts("cafe\u{301}.") == "\"cafe\u{301}*\"")
    }

    // ports: SearchQueryTest#operatorWordsAreQuoted
    @Test func operatorWordsAreQuoted() {
        #expect(fts("price AND stays") == "\"price*\" \"AND*\" \"stays*\"")
        #expect(fts("a OR b NOT c NEAR d") == "\"a*\" \"OR*\" \"b*\" \"NOT*\" \"c*\" \"NEAR*\" \"d*\"")
        #expect(fts("NEAR/3") == "\"NEAR 3*\"")
        #expect(fts("(a OR b)") == "\"a*\" \"OR*\" \"b*\"")
    }

    // ports: SearchQueryTest#accentsAndCaseAreKept
    @Test func accentsAndCaseAreKept() {
        #expect(fts("café DELIVERY") == "\"café*\" \"DELIVERY*\"")
        #expect(fts("Élodie") == "\"Élodie*\"")
    }

    // ports: SearchQueryTest#emptyAndBlankInputs
    @Test func emptyAndBlankInputs() {
        #expect(fts("") == nil)
        #expect(fts("   ") == nil)
        #expect(fts("\t\n \u{3000}") == nil)
    }

    // ports: SearchQueryTest#whitespaceOfEveryKindSplits
    @Test func whitespaceOfEveryKindSplits() {
        #expect(fts(" a\tb\u{00A0}c\nd ") == "\"a*\" \"b*\" \"c*\" \"d*\"")
    }

    // ports: SearchQueryTest#termsWithoutLettersOrDigitsAreDropped
    @Test func termsWithoutLettersOrDigitsAreDropped() {
        #expect(fts("delivery , … ?!") == "\"delivery*\"")
        #expect(fts("2026") == "\"2026*\"")
    }

    // ports: SearchQueryTest#highlightsInTheMiddle
    @Test func highlightsInTheMiddle() {
        let parsed = Highlighted(marked: "so the \u{2}delivery\u{3} slips to \u{2}Thursday\u{3}, but")
        #expect(parsed.text == "so the delivery slips to Thursday, but")
        #expect(parsed.ranges == [7..<15, 25..<33])
        #expect(text(parsed, parsed.ranges[0]) == "delivery")
        #expect(text(parsed, parsed.ranges[1]) == "Thursday")
        #expect(!parsed.leadingEllipsis)
        #expect(!parsed.trailingEllipsis)
    }

    // ports: SearchQueryTest#highlightsAtStartAndEnd
    @Test func highlightsAtStartAndEnd() {
        let start = Highlighted(marked: "\u{2}Delivery\u{3} slips")
        #expect(start.text == "Delivery slips")
        #expect(start.ranges == [0..<8])
        let end = Highlighted(marked: "the \u{2}delivery\u{3}")
        #expect(end.text == "the delivery")
        #expect(end.ranges == [4..<12])
        #expect(Highlighted(marked: "\u{2}delivery\u{3}").ranges == [0..<8])
    }

    // ports: SearchQueryTest#adjacentHighlightsStaySeparate
    @Test func adjacentHighlightsStaySeparate() {
        let parsed = Highlighted(marked: "\u{2}deli\u{3}\u{2}very\u{3} x")
        #expect(parsed.text == "delivery x")
        #expect(parsed.ranges == [0..<4, 4..<8])
    }

    // ports: SearchQueryTest#ellipsesBecomeFlags
    @Test func ellipsesBecomeFlags() {
        let parsed = Highlighted(marked: "…first \u{2}delivery\u{3} slips…")
        #expect(parsed.text == "first delivery slips")
        #expect(parsed.ranges == [6..<14])
        #expect(parsed.leadingEllipsis)
        #expect(parsed.trailingEllipsis)
        #expect(Highlighted(marked: "…\u{2}delivery\u{3}…") == Highlighted("delivery", ranges: [0..<8], leadingEllipsis: true, trailingEllipsis: true))
        #expect(Highlighted(marked: "…") == Highlighted("", leadingEllipsis: true))
    }

    // ports: SearchQueryTest#malformedMarkers
    @Test func malformedMarkers() {
        #expect(Highlighted(marked: "") == Highlighted(""))
        #expect(Highlighted(marked: "the \u{2}deliv").ranges == [4..<9])
        #expect(Highlighted(marked: "the\u{3} x\u{2}\u{3} y").ranges == [])
        #expect(Highlighted(marked: "the\u{3} x\u{2}\u{3} y").text == "the x y")
        #expect(Highlighted(marked: "plain text").ranges == [])
    }
}
