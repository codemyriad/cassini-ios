import XCTest

/// The least time any of the waits below allows, whatever its caller asks: on a busy host a step takes two to four
/// times as long, and a 3 or 5 second limit failed tests that had nothing wrong (E1). A wait returns as soon as its
/// condition holds, so a passing run is no slower. `TEST_RUNNER_CASSINI_UI_WAIT_FLOOR` (seconds) overrides it.
let uiWaitFloor: TimeInterval =
    ProcessInfo.processInfo.environment["CASSINI_UI_WAIT_FLOOR"].flatMap(TimeInterval.init) ?? 15

/// Waits that look at once and then about every tenth of a second. XCTest's `waitForExistence(timeout:)` and
/// `XCTNSPredicateExpectation` first look after a whole second, so each of them cost a test a second even when the
/// element was already on the screen. Each waits at least `uiWaitFloor`.
///
/// These are for what should happen. Check absence immediately after a positive screen/decision marker. A negative
/// wait would use elapsed time as evidence and wait the whole floor on every passing run.
extension XCUIElement {
    @MainActor func waitForExistence(within timeout: TimeInterval) -> Bool {
        poll(within: max(timeout, uiWaitFloor)) { exists }
    }

    @MainActor func waitForNonExistence(within timeout: TimeInterval) -> Bool {
        poll(within: max(timeout, uiWaitFloor)) { !exists }
    }

    /// Waits until the element is there and enabled: the recording screen shows Pause, disabled, while the microphone
    /// starts.
    @MainActor func waitForEnabled(within timeout: TimeInterval) -> Bool {
        poll(within: max(timeout, uiWaitFloor)) { exists && isEnabled }
    }

    /// Waits until `predicate`, over the element's attributes as for `XCTNSPredicateExpectation`, holds. While the
    /// element is missing only `exists == false` can hold (reading another attribute of it would fail the test).
    @MainActor func wait(until predicate: NSPredicate, within timeout: TimeInterval) -> Bool {
        poll(within: max(timeout, uiWaitFloor)) {
            exists ? predicate.evaluate(with: self) : predicate.evaluate(with: ["exists": false])
        }
    }

    /// Waits until this field holds `text`. Typed keys reach the app after `typeText` returns, seconds later on a busy
    /// machine, so a button tapped or read before then sees what the field held so far: a disabled Save, or a title
    /// cut short.
    @MainActor func waitForValue(_ text: String, within timeout: TimeInterval = 10) -> Bool {
        wait(until: NSPredicate(format: "value == %@", text), within: timeout)
    }
}

extension XCUIElement {
    /// Taps once after the Library's data, UIKit presentation and active scene are ready. A missing destination is
    /// a failure at the hang bound, never a reason to send a second tap while the first may still be in flight.
    @MainActor @discardableResult
    func tapWhenInteractive(in app: XCUIApplication, until opened: () -> Bool) -> Bool {
        guard app.staticTexts["uiTestState-libraryInteractive"].waitForExistence(within: uiWaitFloor),
              poll(within: uiWaitFloor, { exists && isEnabled && isHittable }) else { return false }
        tap()
        return poll(within: uiWaitFloor, opened)
    }

    /// Taps a menu item once it has stopped moving. A context menu or a pull-down menu still animates in when the app's
    /// own animations are off, and a tap that lands while it does is dropped on a busy machine ("Failed to tap", or a
    /// tap that does nothing). An open menu is also rebuilt whenever what it shows changes (a running job's note, at
    /// each result), and for a moment the item has no point to tap: reading `isHittable` then fails the test ("Failed
    /// to determine hittability… Activation point invalid"). So the wait reads snapshots, which only throw, until the
    /// item is on the screen at the same frame twice in a row, then taps it.
    @MainActor func tapWhenSettled(within timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let screen = XCUIApplication().frame
        var last: CGRect?
        let settled = poll(within: max(timeout, uiWaitFloor)) {
            guard let frame = (try? snapshot())?.frame.intersection(screen), !frame.isEmpty else { last = nil; return false }
            defer { last = frame }
            return frame == last
        }
        guard settled else { XCTFail("The menu item never settled on screen", file: file, line: line); return }
        tap()
    }
}

/// Scrolling until something is on the screen. Each swipe costs about two and a half seconds, most of it XCTest
/// waiting for the list to settle, so the condition is checked before every swipe, not swiped past.
extension XCUIElement {
    /// Swipes this scroll view up (towards the end of the list) or down until `done` holds, at most `attempts` times.
    @MainActor @discardableResult
    func scroll(up: Bool = true, attempts: Int = 8, velocity: XCUIGestureVelocity = .default,
                until done: () -> Bool) -> Bool {
        for _ in 0..<attempts {
            if done() { return true }
            if up { swipeUp(velocity: velocity) } else { swipeDown(velocity: velocity) }
        }
        return done()
    }
}

extension XCUIElement {
    /// Replaces this focused field once and waits for the edit. A timeout fails the edit; it never causes another
    /// edit that could overtake an input still arriving. The field may truncate the input to its limit.
    @MainActor func replaceText(with text: String, expecting expected: String? = nil, emptyValue: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        let current = (value as? String) ?? ""
        // SwiftUI's multiline TextField can expose its prompt as value/label without placeholderValue.
        let placeholder = emptyValue ?? placeholderValue.flatMap { $0.isEmpty ? nil : $0 } ?? label
        // Deleting a displayed prompt is harmless; skipping deletion could keep real text equal to that prompt.
        let length = current.count
        if length > 0 {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length + 2))
            guard poll(within: uiWaitFloor, { (value as? String).map { $0.isEmpty || $0 == placeholder } ?? false }) else {
                XCTFail("The field did not clear before replacement", file: file, line: line); return
            }
        }
        if text.isEmpty { return }
        // One input operation avoids a cross-process clipboard handoff and cannot duplicate a late paste.
        typeText(text)
        XCTAssertTrue(waitForValue(expected ?? text, within: uiWaitFloor),
                      "The replacement edit did not arrive", file: file, line: line)
    }
}

/// The labels of the elements on the screen whose identifier is `identifier`, from one snapshot of the app: one
/// round trip instead of one or more per element.
@MainActor func labels(in app: XCUIApplication, identifier: String) -> [String] {
    guard let root = try? app.snapshot() else { return [] }
    var found: [String] = [], stack: [any XCUIElementSnapshot] = [root]
    while let element = stack.popLast() {
        if element.identifier == identifier { found.append(element.label) }
        stack.append(contentsOf: element.children)
    }
    return found
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
    /// Releases exactly this many synthetic draft results; callers wait for the resulting words.
    @MainActor func appendDraft(sentences: Int) {
        XCUIDevice.shared.system.open(URL(string: "cassini://ui-test/append-draft?count=\(sentences)")!)
    }

    /// Launches and waits until the app's launch work is done: the seed written, the library read and any fixture note
    /// opened. A step taken before that, on a busy machine, could find an empty screen.
    ///
    /// When the app is already on the screen, launched with the same system arguments (such as a text size), and the
    /// launch resets the test data, the launch happens inside the app (`Launches.relaunchInApp`): about a second
    /// instead of five. `fresh` asks for a new process. Below iOS 26, always start a new process: the iOS 18
    /// accessibility tree can retain elements from the replaced graph and crash while XCTest reads them.
    @MainActor func launchAndWait(fresh: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        if DeviceUnderTest.iOS18Facts, !launchArguments.contains("--ios18-platform") { launchArguments.append("--ios18-platform") }
        if #available(iOS 26, *), !fresh, Launches.relaunchInApp(launchArguments) { return }
        launch()
        Launches.launched(launchArguments)
        XCTAssertTrue(staticTexts["launchFinished"].waitForExistence(within: 30), "the launch did not finish", file: file, line: line)
    }
}

/// UI-test launches made inside the running app. XCTest's launch of a new process costs about five seconds (ending
/// the last one, setting up the automation session, waiting for the app to settle); the app instead answers
/// `cassini://ui-test/relaunch` by building a new app graph from the arguments, as a launch would, over a library
/// and preferences of their own (`UITestRelaunch` and `UITestStorage` in the app). A new process is still launched
/// for the first test of a runner, after a test that failed, when the app is not in the foreground (a test ended
/// it, to check what persists), when the arguments keep the test data, and when the system arguments differ.
@MainActor enum Launches {
    /// The app's own options, with whether each takes a value; the rest of the arguments are the system's.
    private static let options: [String: Bool] = [
        "--ui-testing": false, "--reset-test-data": false, "--seed-test-data": false, "--seed": true,
        "--open-fixture": true, "--models-missing": false, "--notifications-denied": false, "--capture-held": false,
    ]
    /// The system arguments of the process this runner launched last; nil when a new process must come first.
    private static var processArguments: [String]?
    private static let observer = FailureObserver()

    static func systemArguments(_ arguments: [String]) -> [String] {
        var system: [String] = [], index = arguments.startIndex
        while index < arguments.endIndex {
            let argument = arguments[index]
            index += 1
            guard let takesValue = options[argument] else { system.append(argument); continue }
            if takesValue, index < arguments.endIndex, !arguments[index].hasPrefix("-") { index += 1 }
        }
        return system
    }

    static func launched(_ arguments: [String]) {
        observer.register()
        processArguments = systemArguments(arguments)
    }

    /// A test failed: whatever it left on the screen goes with a new process.
    static func invalidate() { processArguments = nil }

    /// Relaunches inside the app and waits for its launch work; false when the launch needs a new process or the
    /// app did not answer.
    static func relaunchInApp(_ arguments: [String]) -> Bool {
        guard arguments.contains("--reset-test-data"), let running = processArguments,
              running == systemArguments(arguments), XCUIApplication().state == .runningForeground else { return false }
        let token = UUID().uuidString
        var components = URLComponents()
        components.scheme = "cassini"; components.host = "ui-test"; components.path = "/relaunch"
        components.queryItems = [URLQueryItem(name: "token", value: token)] + arguments.map { URLQueryItem(name: "arg", value: $0) }
        guard let url = components.url else { return false }
        XCUIDevice.shared.system.open(url)
        let marker = XCUIApplication().staticTexts.matching(NSPredicate(format: "identifier == 'launchFinished' AND value == %@", token))
            .firstMatch
        // Not waitForExistence: a relaunch that did not answer falls back to a new process, so no floor here.
        if poll(within: 10, { marker.exists }) { return true }
        let markers = XCUIApplication().staticTexts.matching(identifier: "launchFinished").allElementsBoundByIndex
        print("The relaunch inside the app did not answer (state \(XCUIApplication().state.rawValue), markers "
              + "\(markers.map { $0.value as? String ?? "?" })); launching a new process")
        processArguments = nil
        return false
    }

    /// Forgets the launched process when a test fails, so the next test starts in a new one.
    private final class FailureObserver: NSObject, XCTestObservation {
        private var registered = false

        @MainActor func register() {
            guard !registered else { return }
            registered = true
            XCTestObservationCenter.shared.addTestObserver(self)
        }

        // Not every recorded issue fails the test: the app's runtime warnings are issues too.
        nonisolated func testCaseDidFinish(_ testCase: XCTestCase) {
            guard testCase.testRun?.hasSucceeded == false else { return }
            MainActor.assumeIsolated { Launches.invalidate() }
        }
    }
}
