import XCTest

/// Saved voices empty and stale-voice layouts (`D106` L-63).
final class SavedVoicesFlowTests: XCTestCase {
    @MainActor private func openSavedVoices(seed: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed", seed]
        app.launchAndWait()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(within: 15))
        let settings = app.buttons["settingsButton"]
        XCTAssertTrue(settings.waitForExistence(within: 15))
        let firstTopic = app.buttons["transcriptionRow"]
        XCTAssertTrue(settings.tapWhenInteractive(in: app, until: { firstTopic.exists }), "Settings did not open")
        XCTAssertTrue(app.waitForSettingsPage("map"))
        let savedVoices = app.buttons["savedVoicesRow"]
        app.scroll(attempts: 6) { savedVoices.exists && savedVoices.isHittable && app.frame.contains(savedVoices.frame) }
        XCTAssertTrue(savedVoices.waitForExistence(within: 15))
        savedVoices.tapWhenSettled()
        XCTAssertTrue(app.navigationBars["Saved voices"].waitForExistence(within: 15))
        return app
    }

    @MainActor func testEmptySavedVoicesShowsAddButtonAndPrivacyFootnote() {
        let app = openSavedVoices(seed: "library")
        let addButton = app.buttons["addSavedVoice"]
        XCTAssertTrue(addButton.waitForExistence(within: 15))
        XCTAssertTrue(addButton.isHittable)
        XCTAssertTrue(addButton.label.contains("Add a voice"), addButton.label)
        let footnote = app.descendants(matching: .any)["savedVoicesPrivacyFootnote"]
        XCTAssertTrue(footnote.waitForExistence(within: 15))
        XCTAssertTrue(footnote.label.contains("Exports and shares include names only."), footnote.label)
        XCTAssertFalse(app.descendants(matching: .any)["voicesStaleNotice"].exists)
    }

    @MainActor func testStaleSavedVoiceShowsNoticePillAndPrivacyFootnote() {
        let app = openSavedVoices(seed: "staleVoices")
        let notice = app.descendants(matching: .any)["voicesStaleNotice"]
        XCTAssertTrue(notice.waitForExistence(within: 15))
        XCTAssertTrue(notice.label.contains("3 voices need naming again"), notice.label)
        XCTAssertTrue(notice.label.contains("Alex Moreau"), notice.label)
        XCTAssertTrue(notice.label.contains("Giulia Conti"), notice.label)
        XCTAssertTrue(notice.label.contains("Sam Rivera"), notice.label)

        let list = app.collectionViews["savedVoicesList"]
        let staleRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "Giulia Conti", "Needs naming again"))
            .firstMatch
        XCTAssertTrue(list.scroll(attempts: 6) { staleRow.exists }, "Giulia Conti row should show the stale pill")

        let footnote = app.descendants(matching: .any)["savedVoicesPrivacyFootnote"]
        XCTAssertTrue(list.scroll(attempts: 6) { footnote.exists }, "Privacy footnote should appear in the populated list")
        XCTAssertTrue(footnote.label.contains("Exports and shares include names only."), footnote.label)
    }
}
