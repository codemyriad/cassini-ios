import XCTest
import CassiniNotebook
@testable import Cassini

/// The words of the progress card in English.
final class ProgressTextTests: XCTestCase {
    private let second: Int64 = 1_000, minute: Int64 = 60_000

    private func nb(_ text: String) -> String { text.replacingOccurrences(of: " ", with: "\u{00A0}") }

    // ports: FormatTest#progress
    func testTheProgressCardWordsItsNumbers() {
        XCTAssertEqual(ProgressText.timeLeft(.range(lowMs: 6 * minute, highMs: 9 * minute)), nb("6–9 min"))
        XCTAssertEqual(ProgressText.timeLeft(.range(lowMs: 6 * minute + 50 * second, highMs: 8 * minute + 10 * second)), nb("6–9 min"))
        XCTAssertEqual(ProgressText.timeLeft(.range(lowMs: 6 * minute, highMs: 6 * minute)), "About \(nb("6 min"))")
        XCTAssertEqual(ProgressText.timeLeft(.range(lowMs: 10 * second, highMs: 50 * second)), nb("Under 1 min"))
        XCTAssertEqual(ProgressText.timeLeft(.range(lowMs: 10 * second, highMs: 2 * minute)), nb("1–2 min"))
        XCTAssertEqual(ProgressText.timeLeft(.range(lowMs: 70 * minute, highMs: 90 * minute)), nb("1 h 10 min–1 h 30 min"))
        XCTAssertEqual(ProgressText.timeLeft(.range(lowMs: 45 * minute, highMs: 70 * minute)), nb("45 min–1 h 10 min"))
        XCTAssertEqual(ProgressText.timeLeft(.calculating), "Calculating…")
        XCTAssertEqual(ProgressText.timeLeft(.finishing), "Finishing…")
        XCTAssertEqual(ProgressText.timeLeftLine(.range(lowMs: 6 * minute, highMs: 9 * minute)), "About \(nb("6–9 min")) left")
        XCTAssertEqual(ProgressText.timeLeftLine(.range(lowMs: 6 * minute, highMs: 6 * minute)), "About \(nb("6 min")) left")
        XCTAssertEqual(ProgressText.timeLeftLine(.range(lowMs: 0, highMs: 30 * second)), "Under \(nb("1 min")) left")
        XCTAssertEqual(ProgressText.timeLeftLine(.range(lowMs: 70 * minute, highMs: 90 * minute)), "About \(nb("1 h 10 min–1 h 30 min")) left")
        XCTAssertEqual(ProgressText.timeLeftLine(.calculating), "Calculating time left…")
        XCTAssertEqual(ProgressText.timeLeftLine(.finishing), "Finishing…")
        XCTAssertEqual(ProgressText.battery(.projected(percentNow: 54, percentAtFinish: 41)), "54% → about 41%")
        XCTAssertEqual(ProgressText.battery(.pluggedIn(percentNow: 80)), "Plugged in")
        XCTAssertEqual(ProgressText.battery(.measuring(percentNow: 80)), "Measuring…")
        XCTAssertNil(ProgressText.battery(.unavailable))
        XCTAssertEqual(ProgressText.headline(.findingWords), "Finding words")
        XCTAssertEqual(ProgressText.headline(.matchingVoices), "Matching saved voices")
        XCTAssertEqual(ProgressText.step(.speakers), "Speakers & matching")
        XCTAssertEqual(ProgressText.stepDescription(.words), "Step 3 of 5: Words")
        XCTAssertEqual(ProgressText.stepState(.skipped), "skipped")
        XCTAssertEqual(ProgressText.compactEta(.range(lowMs: 1 * minute, highMs: 1 * minute), language: "en"), "about 1 min left")
        XCTAssertEqual(ProgressText.compactEta(.range(lowMs: 6 * minute, highMs: 6 * minute), language: "en"), "about 6 min left")
        XCTAssertEqual(ProgressText.compactEta(.range(lowMs: 6 * minute, highMs: 9 * minute), language: "en"), "about 6–9 min left")
        XCTAssertEqual(ProgressText.compactEta(.range(lowMs: 70 * minute, highMs: 90 * minute), language: "en"), "about 70–90 min left")
        XCTAssertEqual(ProgressText.compactEta(.range(lowMs: 10 * second, highMs: 50 * second), language: "en"), "under \(nb("1 min")) left")
        XCTAssertEqual(ProgressText.compactEta(.calculating, language: "en"), "calculating time left…")
        XCTAssertEqual(ProgressText.compactEta(.finishing, language: "en"), "finishing…")
    }

    // ports: FormatTest#compactEtaLocales + TranscribingSheetStepLabelAlignment
    func testCompactEtaAudioDoneAndStepDescriptionsFollowExplicitLocales() {
        XCTAssertEqual(ProgressText.compactEta(.range(lowMs: 1 * minute, highMs: 1 * minute), language: "it"), "circa 1 min rimanente")
        XCTAssertEqual(ProgressText.compactEta(.range(lowMs: 4 * minute, highMs: 6 * minute), language: "it"), "circa 4–6 min rimanenti")
        XCTAssertEqual(ProgressText.compactEta(.range(lowMs: 1 * minute, highMs: 1 * minute), language: "fr"), "environ 1 min restante")
        XCTAssertEqual(ProgressText.compactEta(.range(lowMs: 4 * minute, highMs: 6 * minute), language: "fr"), "environ 4–6 min restantes")
        XCTAssertEqual(ProgressText.compactEta(.range(lowMs: 1 * minute, highMs: 1 * minute), language: "es"), "queda 1 min")
        XCTAssertEqual(ProgressText.compactEta(.range(lowMs: 4 * minute, highMs: 6 * minute), language: "es"), "quedan unos 4–6 min")
        XCTAssertEqual(ProgressText.compactEta(.range(lowMs: 1 * minute, highMs: 1 * minute), language: "pt-BR"), "cerca de 1 min restante")
        XCTAssertEqual(ProgressText.compactEta(.range(lowMs: 4 * minute, highMs: 6 * minute), language: "pt-PT"), "cerca de 4–6 min restantes")

        XCTAssertEqual(ProgressText.audioDone(doneMs: 29 * minute + 52 * second, totalMs: 48 * minute + 13 * second, language: "fr"),
                       "29:52 sur 48:13")
        XCTAssertEqual(ProgressText.audioDone(doneMs: 29 * minute + 52 * second, totalMs: 48 * minute + 13 * second, language: "it"),
                       "29:52 su 48:13")
        XCTAssertEqual(ProgressText.audioDone(doneMs: 29 * minute + 52 * second, totalMs: 48 * minute + 13 * second, language: "es"),
                       "29:52 de 48:13")

        XCTAssertEqual(ProgressText.stepDescription(.saving, language: "pt-BR"), "Etapa 5 de 5: Salvamento")
        XCTAssertEqual(ProgressText.stepDescription(.saving, language: "pt-PT"), "Passo 5 de 5: Gravação")
        XCTAssertEqual(ProgressText.stepDescription(.speakers, language: "fr"), "Étape 4 sur 5\u{00A0}: Intervenants et correspondance")
    }

    // ports: FormatTest#clock (the progress sheet's range and Audio done stat)
    func testTheAudioDoneStatAndTheRangeAreClockTimes() {
        XCTAssertEqual(ProgressText.range(startMs: 29 * minute, endMs: 29 * minute + 45 * second), "29:00–29:45")
        XCTAssertEqual(ProgressText.audioDone(doneMs: 29 * minute + 52 * second, totalMs: 48 * minute + 13 * second), "29:52 of 48:13")
    }
}
