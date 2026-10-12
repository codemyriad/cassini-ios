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
        XCTAssertEqual(ProgressText.battery(.projected(percentNow: 54, percentAtFinish: 41)), "54% → about 41%")
        XCTAssertEqual(ProgressText.battery(.pluggedIn(percentNow: 80)), "Plugged in")
        XCTAssertEqual(ProgressText.battery(.measuring(percentNow: 80)), "Measuring…")
        XCTAssertNil(ProgressText.battery(.unavailable))
        XCTAssertEqual(ProgressText.headline(.findingWords), "Finding words")
        XCTAssertEqual(ProgressText.headline(.matchingVoices), "Matching saved voices")
        XCTAssertEqual(ProgressText.step(.speakers), "Speakers & matching")
        XCTAssertEqual(ProgressText.stepDescription(.words), "Step 3 of 5: Words")
        XCTAssertEqual(ProgressText.stepState(.skipped), "skipped")
    }

    // ports: FormatTest#clock (the progress card's range and Processed stat)
    func testTheProcessedStatAndTheRangeAreClockTimes() {
        XCTAssertEqual(ProgressText.range(startMs: 29 * minute, endMs: 29 * minute + 45 * second), "29:00–29:45")
        XCTAssertEqual(ProgressText.processed(doneMs: 29 * minute + 52 * second, totalMs: 48 * minute + 13 * second), "29:52 / 48:13")
    }
}
