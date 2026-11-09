import XCTest

final class SpeechUnavailableTests: XCTestCase {
    @MainActor func testHardwareDisablesBothActionsButUnsupportedLocaleKeepsItsRefusalPath() {
        let app = XCUIApplication()
        for failure in ["hardware", "language"] {
            for (id, action) in [("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", "Transcribe"),
                                 ("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "Transcribe again")] {
                app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed-test-data", "--open-fixture", id,
                                       "--speech-unavailability", failure]
                app.launchAndWait(fresh: true)
                let menu = app.buttons["noteActions"]
                XCTAssertTrue(menu.waitForExistence(within: 15))
                menu.tap()
                let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", action)).firstMatch
                XCTAssertTrue(button.waitForExistence(within: 15))
                XCTAssertTrue(button.wait(until: NSPredicate(format: "enabled == %@", NSNumber(value: failure == "language")), within: 15))
            }
        }
    }

    /// The iOS 18 facts on a device where neither Whistle nor Parakeet can run: both actions are disabled, as on an
    /// Apple device without the model.
    @MainActor func testWithoutAppleSpeechOrAnotherRecognizerBothActionsAreDisabled() {
        let app = XCUIApplication()
        for (id, action) in [("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", "Transcribe"),
                             ("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "Transcribe again")] {
            app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed-test-data", "--open-fixture", id,
                                   "--ios18-platform"]
            app.launchAndWait(fresh: true)
            let menu = app.buttons["noteActions"]
            XCTAssertTrue(menu.waitForExistence(within: 15))
            menu.tap()
            let button = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", action)).firstMatch
            XCTAssertTrue(button.waitForExistence(within: 15))
            XCTAssertTrue(button.wait(until: NSPredicate(format: "enabled == false"), within: 15))
        }
    }
}
