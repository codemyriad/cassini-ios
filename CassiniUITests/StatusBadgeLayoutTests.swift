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
        let inset = app.descendants(matching: .any)["badgeGallery"].frame.minX - window.minX
        let content = window.insetBy(dx: inset, dy: 0)
        let scroll = app.scrollViews.firstMatch
        let viewport = scroll.frame.intersection(window)
        for index in 0..<9 {
            let badge = app.descendants(matching: .any)["badge-gallery-\(index)"]
            guard badge.waitForExistence(within: 15) else {
                XCTFail("The actual badge \(index) is missing"); return
            }
            XCTAssertTrue(scroll.scroll(attempts: 12) {
                guard badge.exists, !badge.frame.isEmpty else { return false }
                return badge.frame.minY >= viewport.minY && badge.frame.maxY <= viewport.maxY
            }, "the complete badge \(index) is visible")
            if index == 0 { XCTAssertTrue(badge.label.hasPrefix("Enregistrement"), "the real French catalog is active") }
            XCTAssertGreaterThan(badge.frame.width, 0)
            XCTAssertGreaterThanOrEqual(badge.frame.minX, content.minX - 1, "badge \(index) stays inside the left edge")
            XCTAssertLessThanOrEqual(badge.frame.maxX, content.maxX + 1, "badge \(index) stays inside the right edge")
        }
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "status-badges-fr-accessibilityXXXL"
        image.lifetime = .keepAlways
        add(image)
        try app.performAccessibilityAudit(for: .textClipped)
    }
}
