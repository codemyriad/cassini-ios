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
        XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Telling speakers apart")).firstMatch.exists, "The advertised upgrade does not add speaker-model downloads")
    }

    @MainActor func testFirstWhistleSuggestsOnceThenSettingsDismissalPersists() {
        let app = XCUIApplication()
        let arguments = ["--ui-testing", "--seed-test-data", "--d78", "--d78-capable", "--open-fixture", walk]
        app.launchArguments = arguments + ["--reset-test-data"]
        app.launchAndWait()
        let transcribe = app.buttons["Transcribe"].firstMatch
        XCTAssertTrue(transcribe.waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts["uiTestState-noteSuggestionDecision"].waitForValue("no-result"))
        XCTAssertFalse(app.staticTexts[title].exists)
        transcribe.tap()
        XCTAssertTrue(app.descendants(matching: .any)["turn-w0"].waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts[title].waitForExistence(within: 15))
        app.launchArguments = arguments
        app.launchAndWait(fresh: true)
        XCTAssertTrue(app.staticTexts["noteTitle"].waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts["uiTestState-noteSuggestionDecision"].waitForValue("completed"))
        XCTAssertFalse(app.staticTexts[title].exists, "The result suggestion is shown once")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(within: 15))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(within: 15), "Settings still offers the upgrade")
        let dismiss = app.buttons["dismissParakeetSuggestion"]
        app.scroll { dismiss.exists && dismiss.isHittable }
        dismiss.tap()
        XCTAssertTrue(app.staticTexts[title].waitForNonExistence(within: 15))
        app.launchArguments = ["--ui-testing", "--seed-test-data", "--d78", "--d78-capable"]
        app.launchAndWait(fresh: true)
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.staticTexts["uiTestState-settingsLoaded"].waitForExistence(within: 15))
        XCTAssertFalse(app.staticTexts[title].exists)
    }

    @MainActor func testThreeGigabyteDeviceUsesWhistleWithoutAnUpgradeSuggestion() {
        transcribeWithWhistleOnAThreeGigabyteDevice()
    }

    /// The iOS 18 facts: with the unavailable candidate in Apple's slot the router still picks Whistle, the flow PR D
    /// enables on iOS 18 (the finite background path is the runner's rule, tested in `PlatformFactsTests`).
    @MainActor func testWithoutAppleSpeechAThreeGigabyteDeviceStillUsesWhistle() {
        transcribeWithWhistleOnAThreeGigabyteDevice(["--ios18-platform"])
    }

    @MainActor private func transcribeWithWhistleOnAThreeGigabyteDevice(_ arguments: [String] = []) {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed-test-data", "--d78", "--open-fixture", walk]
            + arguments
        app.launchAndWait()
        let transcribe = app.buttons["Transcribe"].firstMatch
        XCTAssertTrue(transcribe.waitForExistence(within: 15))
        transcribe.tap()
        XCTAssertTrue(app.descendants(matching: .any)["turn-w0"].waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts["uiTestState-noteSuggestionDecision"].waitForValue("completed"))
        XCTAssertFalse(app.staticTexts[title].exists)
        let back = app.navigationBars.buttons.firstMatch
        back.tap()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(within: 15))
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.staticTexts["Whistle"].firstMatch.waitForExistence(within: 15))
        XCTAssertTrue(app.staticTexts["uiTestState-settingsLoaded"].waitForExistence(within: 15))
        XCTAssertFalse(app.staticTexts[title].exists)
        XCTAssertFalse(app.staticTexts["Parakeet Ultra"].exists)
    }
}
