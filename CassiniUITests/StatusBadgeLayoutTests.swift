import XCTest

/// Exercises the real Library flow layout and shared pill with a long catalog translation at the largest text size.
final class StatusBadgeLayoutTests: XCTestCase {
    @MainActor func testFrenchBadgesStayInsideTheRowAtLargestText() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "the narrow phone flow")
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--badge-gallery",
                               "-AppleLanguages", "(fr)", "-AppleLocale", "fr_FR",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchAndWait(fresh: true)
        XCTAssertTrue(app.descendants(matching: .any)["badgeGallery"].waitForExistence(within: 15))
        let window = app.windows.firstMatch.frame
        let scroll = app.scrollViews.firstMatch
        for index in 0..<9 {
            let badge = app.descendants(matching: .any)["badge-gallery-\(index)"]
            XCTAssertTrue(badge.waitForExistence(within: 15))
            XCTAssertTrue(scroll.scroll(attempts: 12) { badge.exists && badge.isHittable }, "badge \(index) is visible")
            XCTAssertGreaterThan(badge.frame.width, 0)
            XCTAssertGreaterThanOrEqual(badge.frame.minX, window.minX - 1, "badge \(index) stays inside the left edge")
            XCTAssertLessThanOrEqual(badge.frame.maxX, window.maxX + 1, "badge \(index) stays inside the right edge")
        }
        try app.performAccessibilityAudit(for: .textClipped)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "status-badges-fr-accessibilityXXXL"
        image.lifetime = .keepAlways
        add(image)
    }
}
