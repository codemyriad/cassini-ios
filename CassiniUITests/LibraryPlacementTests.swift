import XCTest

/// Standalone installs remain reachable even though meetings use their Library rows.
final class LibraryPlacementTests: XCTestCase {
    @MainActor func testStandaloneDownloadStillOpensSettingsAndCanBeCancelled() throws {
        try standalone(checking: false)
    }

    @MainActor func testStandaloneCheckingStillOpensSettings() throws {
        try standalone(checking: true)
    }

    @MainActor private func standalone(checking: Bool) throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the phone Library placement")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", "library", "--parakeet", "--models-missing",
                               "--held-model-install", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if checking { app.launchArguments.append("--checking-model-install") }
        app.launchAndWait(fresh: true)
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 15))
        let speech = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Speech recognition'")).firstMatch
        XCTAssertTrue(app.scroll { speech.exists && speech.isHittable && app.frame.contains(speech.frame) })
        speech.tap()
        XCTAssertTrue(app.buttons["Download"].waitForExistence(within: 15))
        app.buttons["Download"].tap()
        let requested = app.staticTexts["uiTestState-modelInstallRequested"]
        XCTAssertTrue(requested.waitForExistence(within: 15))
        XCTAssertEqual(requested.value as? String, "speech", "This is an actual speech-only installer request")
        let stage = checking ? "Checking files" : "Downloading 46%"
        XCTAssertTrue(speech.wait(until: NSPredicate(format: "label CONTAINS %@", stage), within: 15))
        XCTAssertFalse(app.staticTexts["uiTestState-modelInstallCompleted"].exists, "The fixture is held at its real progress event")
        app.navigationBars["Settings"].buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15))
        let banner = app.buttons["progressBanner"]
        XCTAssertTrue(banner.waitForExistence(within: 15), "The standalone install card is retained")
        XCTAssertTrue(banner.label.hasPrefix("Downloading models"), banner.label)
        if checking { XCTAssertTrue(banner.label.contains("Checking files"), banner.label) }
        banner.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(within: 15), "The retained card opens Settings")
        XCTAssertTrue(speech.wait(until: NSPredicate(format: "label CONTAINS %@", stage), within: 15),
                      "The install stage survives navigation back to Settings")
        if !checking {
            let cancel = app.buttons["Cancel"].firstMatch
            XCTAssertTrue(cancel.waitForExistence(within: 15))
            cancel.tap()
            XCTAssertTrue(speech.wait(until: NSPredicate(format: "label CONTAINS 'Downloads with next transcription'"), within: 15))
            app.navigationBars["Settings"].buttons.element(boundBy: 0).tap()
            XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15))
            XCTAssertFalse(banner.exists, "Cancellation removes only the standalone install")
        }
        app.terminate()
    }
}
