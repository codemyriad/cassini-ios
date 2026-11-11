import XCTest
import CassiniNotebook
@testable import Cassini

/// Exercise the actual app's localized resource/formatter adapter, not a separately assembled writer copy.
@MainActor final class MarkdownCopyTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_793_088_000)

    func testFrenchUiAndUsFormattingLocaleRemainIndependent() throws {
        let original = Locale.current
        let copy = ExportCopy.markdownOptions(uiLanguage: "fr", locale: Locale(identifier: "en_US"),
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Rome")))
        XCTAssertEqual(copy.copy.transcriptHeading, "Transcription")
        XCTAssertEqual(copy.copy.speakersLine, "Intervenants\u{00A0}: {names}")
        XCTAssertEqual(copy.copy.notesHeading, "Notes")
        XCTAssertEqual(copy.dateLine(date, 3_120_000), "mardi 27 octobre 2026, 9:00 AM · 52 min")
        XCTAssertEqual(Locale.current, original, "Formatting never mutates the global locale")
    }

    func testActualResourcesResolveAllSixSharedCopiesAndArabicDurationDigits() throws {
        // Literal shared catalog values at cassini-ux b86b7b0; this verifies the production Export table wiring.
        let cases: [(String, String, String, String, String, String, String)] = [
            ("en", "Speakers: {names}", "Transcript", "Notes", "(over {names})", "Untitled meeting", "under 1 min"),
            ("it", "Voci: {names}", "Trascrizione", "Note", "(in sovrapposizione con {names})", "Riunione senza titolo", "meno di 1 min"),
            ("fr", "Intervenants\u{00A0}: {names}", "Transcription", "Notes", "(en même temps que {names})", "Réunion sans titre", "moins d’1 min"),
            ("es", "Hablantes: {names}", "Transcripción", "Notas", "(a la vez que {names})", "Reunión sin título", "menos de 1 min"),
            ("pt-BR", "Locutores: {names}", "Transcrição", "Notas", "(ao mesmo tempo que {names})", "Reunião sem título", "menos de 1 min"),
            ("pt-PT", "Oradores: {names}", "Transcrição", "Notas", "(ao mesmo tempo que {names})", "Reunião sem título", "menos de 1 min")]
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let original = Locale.current
        for (language, speakers, transcript, notes, over, untitled, underMinute) in cases {
            let options = ExportCopy.markdownOptions(uiLanguage: language, locale: Locale(identifier: "ar_EG"), timeZone: zone)
            XCTAssertEqual(options.copy.speakersLine, speakers, language)
            XCTAssertEqual(options.copy.transcriptHeading, transcript, language)
            XCTAssertEqual(options.copy.notesHeading, notes, language)
            XCTAssertEqual(options.copy.overLine, over, language)
            XCTAssertEqual(options.untitled, untitled, language)
            XCTAssertTrue(options.dateLine(date, 1).hasSuffix(" · " + underMinute), language)
            XCTAssertTrue(options.dateLine(date, 3_600_000).hasSuffix(" · ١ h ٠٠ min"), language)
            XCTAssertTrue(options.dateLine(date, 3_780_000).hasSuffix(" · ١ h ٠٣ min"), language)
        }
        XCTAssertEqual(Locale.current, original)
    }

    func testUnsupportedUiLanguageUsesEnglishAndBritishSpeakerListWithNumericRegionClock() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Rome"))
        let fallback = ExportCopy.markdownOptions(uiLanguage: "de-DE", locale: Locale(identifier: "de_DE"), timeZone: zone)
        XCTAssertEqual(fallback.copy.transcriptHeading, "Transcript")
        XCTAssertEqual(fallback.dateLine(date, 0), "Tuesday 27 October 2026, 09:00")
        XCTAssertEqual(fallback.copy.speakerList(["Ada", "Ben", "Chris"]), "Ada, Ben and Chris")
        let english = ExportCopy.markdownOptions(uiLanguage: "en", locale: Locale(identifier: "en_US"), timeZone: zone)
        XCTAssertEqual(english.dateLine(date, 0), "Tuesday 27 October 2026, 9:00 AM")
        XCTAssertEqual(english.copy.speakerList(["Ada", "Ben", "Chris"]), "Ada, Ben and Chris")
        XCTAssertEqual(english.unnamedSpeaker(2), "Speaker 2")
        let portuguese = ExportCopy.markdownOptions(uiLanguage: "pt-AO", locale: Locale(identifier: "en_GB"), timeZone: zone)
        XCTAssertEqual(portuguese.copy.speakersLine, "Oradores: {names}")
        XCTAssertEqual(portuguese.unnamedSpeaker(2), "Orador 2")
    }
}
