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
        Self.settleInstall()
        launch()
        XCTAssertTrue(staticTexts["launchFinished"].waitForExistence(within: 30), "the launch did not finish", file: file, line: line)
    }

    @MainActor private static var installSettled = false

    /// xcodebuild installs the app while the test runner starts, so the runner's first launch can meet that install:
    /// the launch fails, or the app it reaches is ended under it. Once per runner, before the first test's own launch,
    /// a launch whose problems are expected lets the install finish.
    @MainActor private static func settleInstall() {
        guard !installSettled else { return }
        installSettled = true
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data"]
        XCTExpectFailure("the first launch can meet xcodebuild's install of the app", options: .nonStrict()) {
            app.launch()
            _ = app.staticTexts["launchFinished"].waitForExistence(within: 15)
            app.terminate()
        }
    }
}
