import XCTest

final class ParakeetSuggestionTests: XCTestCase {
    private let walk = "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"
    private let title = "Get better transcripts with Parakeet Ultra"

    @MainActor func testSettingsSuggestionOpensTheSpeechOnlyConsentPlan() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed-test-data", "--d78", "--d78-capable"]
        app.launchAndWait()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(within: 15))
        let download = app.buttons["downloadParakeetSuggestion"]
        app.scroll { download.exists && download.isHittable }
        download.tap()
        XCTAssertTrue(app.staticTexts["Transcribe on this device"].waitForExistence(within: 15))
        let speech = app.staticTexts["Speech recognition"].firstMatch
        XCTAssertTrue(speech.waitForExistence(within: 15))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Telling speakers apart")).firstMatch.staysAbsent(for: 1), "The advertised upgrade does not add speaker-model downloads")
    }

    @MainActor func testFirstWhistleSuggestsOnceThenSettingsDismissalPersists() {
        let app = XCUIApplication()
        let arguments = ["--ui-testing", "--seed-test-data", "--d78", "--d78-capable", "--open-fixture", walk]
        app.launchArguments = arguments + ["--reset-test-data"]
        app.launchAndWait()
        let transcribe = app.buttons["Transcribe"].firstMatch
        XCTAssertTrue(transcribe.waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts[title].staysAbsent(for: 1))
        transcribe.tap()
        XCTAssertTrue(app.descendants(matching: .any)["turn-w0"].waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts[title].waitForExistence(within: 15))
        app.launchArguments = arguments
        app.launchAndWait(fresh: true)
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts[title].staysAbsent(for: 1), "The result suggestion is shown once")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(within: 15))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(within: 15), "Settings still offers the upgrade")
        let dismiss = app.buttons["dismissParakeetSuggestion"]
        app.scroll { dismiss.exists && dismiss.isHittable }
        dismiss.tap()
        XCTAssertTrue(app.staticTexts[title].staysAbsent(for: 1))
        app.launchArguments = ["--ui-testing", "--seed-test-data", "--d78", "--d78-capable"]
        app.launchAndWait(fresh: true)
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts[title].staysAbsent(for: 1))
    }

    @MainActor func testThreeGigabyteDeviceUsesWhistleWithoutAnUpgradeSuggestion() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed-test-data", "--d78", "--open-fixture", walk]
        app.launchAndWait()
        let transcribe = app.buttons["Transcribe"].firstMatch
        XCTAssertTrue(transcribe.waitForExistence(within: 15))
        transcribe.tap()
        XCTAssertTrue(app.descendants(matching: .any)["turn-w0"].waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts[title].staysAbsent(for: 1))
        let back = app.navigationBars.buttons.firstMatch
        back.tap()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(within: 15))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.staticTexts["Whistle"].firstMatch.waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts[title].staysAbsent(for: 1))
        XCTAssertTrue(app.staticTexts["Parakeet Ultra"].staysAbsent(for: 1))
    }
}
