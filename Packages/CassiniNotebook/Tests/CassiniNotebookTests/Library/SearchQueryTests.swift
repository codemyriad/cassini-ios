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
        #expect(fts("consegna giov") == "\"consegna*\" \"giov*\"")
    }

    // ports: SearchQueryTest#quotesAndStarsAreDropped
    @Test func quotesAndStarsAreDropped() {
        #expect(fts("\"consegna giov\"") == "\"consegna*\" \"giov*\"")
        #expect(fts("cons*") == "\"cons*\"")
        #expect(fts("*cons**") == "\"cons*\"")
        #expect(fts("consegna \" *") == "\"consegna*\"")
    }

    // ports: SearchQueryTest#ftsOperatorsAreDropped
    @Test func ftsOperatorsAreDropped() {
        #expect(fts("^inizio") == "\"inizio*\"")
        #expect(fts("body:prezzo") == "\"body prezzo*\"")
        #expect(fts("(a) (b)") == "\"a*\" \"b*\"")
        #expect(fts("-prezzo") == "\"prezzo*\"")
        #expect(fts("con*segna") == "\"con segna*\"")
        #expect(fts("-- : () ^ \"\" *") == nil)
    }

    // ports: SearchQueryTest#innerPunctuationSplitsTokensAsTheTokenizerDoes
    @Test func innerPunctuationSplitsTokensAsTheTokenizerDoes() {
        #expect(fts("e-mail follow- -up") == "\"e mail*\" \"follow*\" \"up*\"")
        #expect(fts("follow-up") == "\"follow up*\"")
        #expect(fts("l'ordine") == "\"l ordine*\"")
        #expect(fts("snake_case") == "\"snake case*\"")
    }

    // ports: SearchQueryTest#trailingPunctuationKeepsThePrefixMatch
    @Test func trailingPunctuationKeepsThePrefixMatch() {
        #expect(fts("consegn,") == "\"consegn*\"")
        #expect(fts("giov.") == "\"giov*\"")
        #expect(fts("¿davvero?!") == "\"davvero*\"")
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
        #expect(fts("giovedì CONSEGNA") == "\"giovedì*\" \"CONSEGNA*\"")
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
        #expect(fts("consegna , … ?!") == "\"consegna*\"")
        #expect(fts("2026") == "\"2026*\"")
    }

    // ports: SearchQueryTest#highlightsInTheMiddle
    @Test func highlightsInTheMiddle() {
        let parsed = Highlighted(marked: "quindi la \u{2}consegna\u{3} slitta a \u{2}giovedì\u{3}, but")
        #expect(parsed.text == "quindi la consegna slitta a giovedì, but")
        #expect(parsed.ranges == [10..<18, 28..<35])
        #expect(text(parsed, parsed.ranges[0]) == "consegna")
        #expect(text(parsed, parsed.ranges[1]) == "giovedì")
        #expect(!parsed.leadingEllipsis)
        #expect(!parsed.trailingEllipsis)
    }

    // ports: SearchQueryTest#highlightsAtStartAndEnd
    @Test func highlightsAtStartAndEnd() {
        let start = Highlighted(marked: "\u{2}Consegna\u{3} slitta")
        #expect(start.text == "Consegna slitta")
        #expect(start.ranges == [0..<8])
        let end = Highlighted(marked: "la \u{2}consegna\u{3}")
        #expect(end.text == "la consegna")
        #expect(end.ranges == [3..<11])
        #expect(Highlighted(marked: "\u{2}consegna\u{3}").ranges == [0..<8])
    }

    // ports: SearchQueryTest#adjacentHighlightsStaySeparate
    @Test func adjacentHighlightsStaySeparate() {
        let parsed = Highlighted(marked: "\u{2}con\u{3}\u{2}segna\u{3} x")
        #expect(parsed.text == "consegna x")
        #expect(parsed.ranges == [0..<3, 3..<8])
    }

    // ports: SearchQueryTest#ellipsesBecomeFlags
    @Test func ellipsesBecomeFlags() {
        let parsed = Highlighted(marked: "…prima \u{2}consegna\u{3} slitta…")
        #expect(parsed.text == "prima consegna slitta")
        #expect(parsed.ranges == [6..<14])
        #expect(parsed.leadingEllipsis)
        #expect(parsed.trailingEllipsis)
        #expect(Highlighted(marked: "…\u{2}consegna\u{3}…") == Highlighted("consegna", ranges: [0..<8], leadingEllipsis: true, trailingEllipsis: true))
        #expect(Highlighted(marked: "…") == Highlighted("", leadingEllipsis: true))
    }

    // ports: SearchQueryTest#malformedMarkers
    @Test func malformedMarkers() {
        #expect(Highlighted(marked: "") == Highlighted(""))
        #expect(Highlighted(marked: "la \u{2}conse").ranges == [3..<8])
        #expect(Highlighted(marked: "la\u{3} x\u{2}\u{3} y").ranges == [])
        #expect(Highlighted(marked: "la\u{3} x\u{2}\u{3} y").text == "la x y")
        #expect(Highlighted(marked: "plain text").ranges == [])
    }
}
