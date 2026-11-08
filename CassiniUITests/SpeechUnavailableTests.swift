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
}
