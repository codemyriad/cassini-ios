import XCTest

/// Settings and "Source code and notices" over the UI-test models: Apple's speech model installed, the speaker models
/// not downloaded, notifications denied.
final class SettingsFlowTests: XCTestCase {
    @MainActor private func openSettings(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "library", "--notifications-denied"] + arguments
        app.launchAndWait()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15))
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 5))
        return app
    }

    /// Scrolls the screen up until `element` is on it.
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(within: 2), "\(element) is not on the screen")
    }

    @MainActor private func row(_ app: XCUIApplication, startingWith title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    /// Any element whose label starts with `title`: a row that is not a button reads as one element.
    @MainActor private func element(_ app: XCUIApplication, startingWith title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
    }

    // ports: SettingsViewModelTest#showsTheModelRowsTheCountsTheVersionAndTheNotificationsBanner (on the screen)
    @MainActor func testSettingsShowsTheModelRowsTheBannerTheCountsAndTheBundleVersion() {
        let app = openSettings()
        // In the iPad split view the list fills in after the navigation bar.
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "App language")).firstMatch
            .waitForExistence(within: 5))
        XCTAssertTrue(app.staticTexts["Notifications are off"].waitForExistence(within: 5))
        XCTAssertTrue(app.buttons["Turn on"].exists)
        let speech = element(app, startingWith: "Speech recognition")
        reveal(speech, in: app)
        XCTAssertTrue(speech.label.contains("Ready"), speech.label)
        XCTAssertFalse(row(app, startingWith: "Speech recognition").exists, "a Ready row is not a button")
        XCTAssertTrue(row(app, startingWith: "Telling speakers apart").label.contains("Not downloaded"))
        let voices = row(app, startingWith: "Saved voices")
        reveal(voices, in: app)
        XCTAssertTrue(voices.label.contains("None yet"), voices.label)
        // With its value: on iPad the library's toolbar beside Settings has a Recently Deleted button too.
        XCTAssertTrue(row(app, startingWith: "Recently Deleted,").label.contains("Empty"))
        let version = element(app, startingWith: "Cassini 0.1.0")
        reveal(version, in: app)
    }

    // ports: SettingsViewModelTest#onlyANotDownloadedOrAFailedRowOpensModelDownload (on the screen)
    @MainActor func testANotDownloadedRowOpensTheStandaloneDownload() {
        let app = openSettings()
        let speakers = row(app, startingWith: "Telling speakers apart")
        reveal(speakers, in: app)
        speakers.tap()
        XCTAssertTrue(app.staticTexts["Transcribe on this device"].waitForExistence(within: 5))
        XCTAssertTrue(app.buttons["Download"].exists, "with no note the screen offers a standalone Download")
        app.buttons["Download"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 5))
        // The fake models install nothing: agreed to and still missing, the row waits for the next transcription.
        let pending = element(app, startingWith: "Telling speakers apart")
        reveal(pending, in: app)
        XCTAssertTrue(pending.label.contains("Downloads with next transcription"), pending.label)
    }

    // ports: SettingsBehaviourTest#licenceRowsOpenAndBackClosesTheText
    @MainActor func testLicenceRowsOpenTheirTextAndBackClosesIt() {
        let app = openSettings()
        let notices = app.buttons["Source code and notices"]
        reveal(notices, in: app)
        notices.tap()
        XCTAssertTrue(app.navigationBars["Source code and notices"].waitForExistence(within: 5))
        for title in ["Cassini", "Third-party notices", "Model notices", "Where the models come from", "Privacy",
                      "Source code on GitHub"] {
            XCTAssertTrue(row(app, startingWith: title).exists, "\(title) row")
        }
        row(app, startingWith: "Privacy").tap()
        XCTAssertTrue(app.navigationBars["Privacy"].waitForExistence(within: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Cassini for iOS keeps")).firstMatch.exists)
        app.navigationBars["Privacy"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Source code and notices"].waitForExistence(within: 5))

        row(app, startingWith: "Cassini").tap()
        XCTAssertTrue(app.navigationBars["Cassini"].waitForExistence(within: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "GNU GENERAL PUBLIC LICENSE")).firstMatch
            .waitForExistence(within: 5))
        app.navigationBars["Cassini"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Source code and notices"].waitForExistence(within: 5))
        app.navigationBars["Source code and notices"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 5))
    }
}
