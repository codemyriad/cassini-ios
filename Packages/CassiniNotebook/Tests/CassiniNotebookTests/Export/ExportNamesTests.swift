import Testing
@testable import CassiniNotebook

struct ExportNamesTests {
    private func repeated(_ s: String, _ n: Int) -> String { String(repeating: s, count: n) }

    // ports: ExportNamesTest#plainTitleKeepsAccentsAndGetsTheExtension
    @Test func plainTitleKeepsAccentsAndGetsTheExtension() {
        #expect(ExportNames.file("Café delivery — price €", ext: "opus") == "Café delivery — price €.opus")
    }

    // ports: ExportNamesTest#forbiddenCharactersBecomeUnderscores
    @Test func forbiddenCharactersBecomeUnderscores() {
        #expect(ExportNames.file("a/b\\c:d*e?f\"g<h>i|j", ext: "srt") == "a_b_c_d_e_f_g_h_i_j.srt")
    }

    // ports: ExportNamesTest#controlCharactersBecomeUnderscores
    @Test func controlCharactersBecomeUnderscores() {
        #expect(ExportNames.file("a\tb\nc\u{0000}d\u{007F}e", ext: "txt") == "a_b_c_d_e.txt")
    }

    // ports: ExportNamesTest#whitespaceRunsCollapse
    @Test func whitespaceRunsCollapse() {
        #expect(ExportNames.file("Monday   meeting", ext: "vtt") == "Monday meeting.vtt")
    }

    // ports: ExportNamesTest#dotsAndSpacesAreTrimmedAtBothEnds
    @Test func dotsAndSpacesAreTrimmedAtBothEnds() {
        #expect(ExportNames.file(" ..note. . ", ext: "txt") == "note.txt")
        #expect(ExportNames.file("v1.2 draft", ext: "txt") == "v1.2 draft.txt")
    }

    // ports: ExportNamesTest#nothingLeftFallsBack
    @Test func nothingLeftFallsBack() {
        #expect(ExportNames.file("", ext: "opus") == "Cassini note.opus")
        #expect(ExportNames.file(" . . ", ext: "opus") == "Cassini note.opus")
        #expect(ExportNames.file(" \u{3000}", ext: "m4a") == "Cassini note.m4a")
    }

    // ports: ExportNamesTest#longTitlesAreCutAtOneHundredUnits
    @Test func longTitlesAreCutAtOneHundredUnits() {
        #expect(ExportNames.file(repeated("a", 120), ext: "txt") == repeated("a", 100) + ".txt")
        #expect(ExportNames.file(repeated("a", 99) + " bcd", ext: "txt") == repeated("a", 99) + ".txt")
    }

    // ports: ExportNamesTest#theCutNeverSplitsASurrogatePair
    @Test func theCutNeverSplitsASurrogatePair() {
        let emoji = "😀"
        #expect(ExportNames.file(repeated("a", 99) + emoji + "b", ext: "txt") == repeated("a", 99) + ".txt")
        #expect(ExportNames.file(repeated("a", 98) + emoji + "b", ext: "txt") == repeated("a", 98) + emoji + ".txt")
    }
}
