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

    /// Waits until `predicate`, over the element's attributes as for `XCTNSPredicateExpectation`, holds. While the
    /// element is missing only `exists == false` can hold (reading another attribute of it would fail the test).
    @MainActor func wait(until predicate: NSPredicate, within timeout: TimeInterval) -> Bool {
        poll(within: timeout) { exists ? predicate.evaluate(with: self) : predicate.evaluate(with: ["exists": false]) }
    }

    /// Waits until this field holds `text`. Typed keys reach the app after `typeText` returns, seconds later on a busy
    /// machine, so a button tapped or read before then sees what the field held so far: a disabled Save, or a title
    /// cut short.
    @MainActor func waitForValue(_ text: String, within timeout: TimeInterval = 10) -> Bool {
        wait(until: NSPredicate(format: "value == %@", text), within: timeout)
    }
}

extension XCUIElement {
    /// Taps a menu item once it has stopped moving. A context menu or a pull-down menu still animates in when the app's
    /// own animations are off, and a tap that lands while it does is dropped on a busy machine ("Failed to tap", or a
    /// tap that does nothing). An open menu is also rebuilt whenever what it shows changes (a running job's note, at
    /// each result), and for a moment the item has no point to tap: reading `isHittable` then fails the test ("Failed
    /// to determine hittability… Activation point invalid"). So the wait reads snapshots, which only throw, until the
    /// item is on the screen at the same frame twice in a row, then taps it.
    @MainActor func tapWhenSettled(within timeout: TimeInterval = 10) {
        let screen = XCUIApplication().frame
        var last: CGRect?
        _ = poll(within: timeout) {
            guard let frame = (try? snapshot())?.frame.intersection(screen), !frame.isEmpty else { last = nil; return false }
            defer { last = frame }
            return frame == last
        }
        tap()
    }
}

/// Scrolling until something is on the screen. Each swipe costs about two and a half seconds, most of it XCTest
/// waiting for the list to settle, so the condition is checked before every swipe, not swiped past.
extension XCUIElement {
    /// Swipes this scroll view up (towards the end of the list) or down until `done` holds, at most `attempts` times.
    /// `fast` swipes fling further, for getting to the end of a list rather than to a row.
    @MainActor @discardableResult
    func scroll(up: Bool = true, attempts: Int = 8, fast: Bool = false, until done: () -> Bool) -> Bool {
        let velocity: XCUIGestureVelocity = fast ? .fast : .default
        for _ in 0..<attempts {
            if done() { return true }
            if up { swipeUp(velocity: velocity) } else { swipeDown(velocity: velocity) }
        }
        return done()
    }
}

extension XCUIElement {
    /// Replaces the text of this focused field with `text` in one edit, as Android's `performTextReplacement`: the
    /// field cleared, then `text` pasted. Typing 200 characters one key at a time takes XCTest about four seconds.
    /// A paste that does not land (the shortcut can be dropped on a busy machine) is typed instead.
    @MainActor func replaceText(with text: String) {
        let current = (value as? String) ?? ""
        let placeholder = placeholderValue ?? ""
        let length = current == placeholder ? 0 : current.count
        if length > 0 { typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: length + 2)) }
        UIPasteboard.general.string = text
        // The field may cut what is pasted to its limit. The first paste of a runner often does not land.
        for _ in 0..<2 {
            typeKey("v", modifierFlags: .command)
            if poll(within: 1, { ((value as? String).map { $0.count > 1 && text.hasPrefix($0) }) ?? false }) { return }
        }
        let left = (value as? String).map { $0 == placeholder ? 0 : $0.count } ?? 0
        if left > 0 { typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: left + 2)) }
        typeText(text)
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
    /// Launches and waits until the app's launch work is done: the seed written, the library read and any fixture note
    /// opened. A step taken before that, on a busy machine, could find an empty screen.
    ///
    /// When the app is already on the screen, launched with the same system arguments (such as a text size), and the
    /// launch resets the test data, the launch happens inside the app (`Launches.relaunchInApp`): about a second
    /// instead of five. `fresh` asks for a new process.
    @MainActor func launchAndWait(fresh: Bool = false, file: StaticString = #filePath, line: UInt = #line) {
        if !fresh, Launches.relaunchInApp(launchArguments) { return }
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
        if marker.waitForExistence(within: 10) { return true }
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
