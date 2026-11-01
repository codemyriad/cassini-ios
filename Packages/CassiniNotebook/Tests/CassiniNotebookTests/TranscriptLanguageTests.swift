import CassiniCore
import Foundation
import Testing
import CassiniNotebook

/// The language tag of D53.2: `und` for a run that does not say, and what a reader counts as known.
@Suite struct TranscriptLanguageTests {
    // ports: TranscriptTest#undIsWrittenAndRoundTripsButIsNoKnownLanguage
    @Test func undIsWrittenAndRoundTripsButIsNoKnownLanguage() throws {
        let und = Transcript([Word("s", 0, 1, "ciao")], language: TranscriptLanguage.undetermined)
        #expect(try JSON.parseObject(und.json())["language"]?.string == "und")
        #expect(try Transcript.fromJSON(und.json()).language == "und")
        #expect(TranscriptLanguage.known("und") == nil)
        #expect(TranscriptLanguage.known("") == nil)
        #expect(TranscriptLanguage.known(nil) == nil)
        #expect(TranscriptLanguage.known("it-IT") == "it-IT")
    }

    /// A run writes what its recognizer reports, else `und`; a reported `und` or empty tag is `und` too.
    @Test func aRunWritesWhatItsRecognizerReportsElseUnd() {
        #expect(TranscriptLanguage.ofRun(reported: nil) == "und")
        #expect(TranscriptLanguage.ofRun(reported: "") == "und")
        #expect(TranscriptLanguage.ofRun(reported: "it-IT") == "it-IT")
    }
}
