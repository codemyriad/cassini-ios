import XCTest

final class VoicesQuestionFlowTests: XCTestCase {
    private static let fixture = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"
    @MainActor private func launch(seed: String? = "speakers", reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--ask-voices", "--speakers-ready"]
            + (reset ? ["--reset-test-data"] : [])
            + (seed.map { ["--seed", $0, "--open-fixture", Self.fixture] } ?? [])
        app.launchAndWait()
        return app
    }

    @MainActor func testNotNowTurnsOffNamingDefaultAndDoesNotAskAgainAfterRelaunch() {
        let app = launch()
        let no = app.buttons["voicesQuestionNotNow"]
        XCTAssertTrue(no.waitForExistence(within: 15))
        no.tap()
        let marker = app.staticTexts["uiTestState-voicesQuestionState"]
        XCTAssertTrue(marker.waitForValue("speakers=2;answered=true;remember=false;auto=false"))
        XCTAssertFalse(app.staticTexts["voicesQuestionTitle"].exists)
        let header = app.buttons["speakerHeader-w1"]
        XCTAssertTrue(header.waitForExistence(within: 15))
        header.tap()
        XCTAssertTrue(app.textFields["speakerNameField"].waitForExistence(within: 15))
        XCTAssertEqual(app.switches["rememberVoice"].value as? String, "0")
        app.terminate()
        let reopened = launch(reset: false)
        XCTAssertTrue(reopened.staticTexts["uiTestState-voicesQuestionState"].waitForValue(
            "speakers=2;answered=true;remember=false;auto=false"))
        XCTAssertFalse(reopened.staticTexts["voicesQuestionTitle"].exists)
    }

    @MainActor func testYesRemembersWithoutEnablingAutomaticNaming() {
        let app = launch()
        let yes = app.buttons["voicesQuestionYes"]
        XCTAssertTrue(yes.waitForExistence(within: 15))
        yes.tap()
        XCTAssertTrue(app.staticTexts["uiTestState-voicesQuestionState"].waitForValue(
            "speakers=2;answered=true;remember=true;auto=false"))
    }

    @MainActor func testDismissalPreservesDefaultAndAnswersOnce() {
        let app = launch()
        let title = app.staticTexts["voicesQuestionTitle"]
        XCTAssertTrue(title.waitForExistence(within: 15))
        let scroll = app.scrollViews["voicesQuestionScroll"]
        XCTAssertTrue(scroll.waitForExistence(within: 15))
        // Drag the sheet's grabber, outside its scrollable text, to perform native dismissal.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let grabber = origin.withOffset(CGVector(dx: scroll.frame.midX, dy: scroll.frame.minY - 10))
        grabber.press(forDuration: 0.1, thenDragTo: origin.withOffset(
            CGVector(dx: scroll.frame.midX, dy: app.frame.maxY - 10)))
        XCTAssertTrue(app.staticTexts["uiTestState-voicesQuestionState"].waitForValue(
            "speakers=2;answered=true;remember=true;auto=false"))
        XCTAssertFalse(title.exists)
    }

    @MainActor func testFirstLaunchAndOneSpeakerNeverAsk() {
        let first = launch(seed: nil)
        XCTAssertTrue(first.staticTexts["heroTitle"].waitForExistence(within: 15))
        XCTAssertFalse(first.staticTexts["voicesQuestionTitle"].exists)
        let solo = launch(seed: "oneSpeaker")
        XCTAssertTrue(solo.staticTexts["uiTestState-voicesQuestionState"].waitForValue(
            "speakers=1;answered=false;remember=true;auto=false"))
        XCTAssertFalse(solo.staticTexts["voicesQuestionTitle"].exists)
    }
}
