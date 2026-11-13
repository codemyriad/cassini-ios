import XCTest

extension XCUIApplication {
    /// Speaker management lives in More; the meeting header contains individual names instead of a count chip.
    @MainActor func openNoteSpeakers(file: StaticString = #filePath, line: UInt = #line) {
        let more = buttons["noteActions"]
        XCTAssertTrue(more.waitForExistence(within: 5), file: file, line: line)
        more.tapWhenSettled()
        let speakers = buttons["speakersButton"]
        XCTAssertTrue(speakers.waitForExistence(within: 5), file: file, line: line)
        speakers.tapWhenSettled()
    }
}
