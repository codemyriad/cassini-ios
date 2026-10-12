import XCTest

/// Waits that look at once and then about every tenth of a second. XCTest's `waitForExistence(timeout:)` and
/// `XCTNSPredicateExpectation` first look after a whole second, so each of them cost a test a second even when the
/// element was already on the screen. The timeouts mean what they meant there.
extension XCUIElement {
    @MainActor func waitForExistence(within timeout: TimeInterval) -> Bool {
        poll(within: timeout) { exists }
    }

    @MainActor func waitForNonExistence(within timeout: TimeInterval) -> Bool {
        poll(within: timeout) { !exists }
    }

    /// Waits until the element is there and enabled: the recording screen shows Pause, disabled, while the microphone
    /// starts.
    @MainActor func waitForEnabled(within timeout: TimeInterval) -> Bool {
        poll(within: timeout) { exists && isEnabled }
    }

    /// Waits until `predicate`, over the element's attributes as for `XCTNSPredicateExpectation`, holds.
    @MainActor func wait(until predicate: NSPredicate, within timeout: TimeInterval) -> Bool {
        poll(within: timeout) { predicate.evaluate(with: self) }
    }
}

@MainActor func poll(within timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if condition() { return true }
        if Date() >= deadline { return false }
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
}

extension XCUIApplication {
    /// Launches and waits until the app's launch work is done: the seed written, the library read and any fixture note
    /// opened. A step taken before that, on a busy machine, could find an empty screen.
    @MainActor func launchAndWait(file: StaticString = #filePath, line: UInt = #line) {
        launch()
        XCTAssertTrue(staticTexts["launchFinished"].waitForExistence(within: 30), "the launch did not finish", file: file, line: line)
    }
}
