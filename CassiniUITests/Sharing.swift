import XCTest

extension XCUIApplication {
    /// Direct identifier lookups avoid XCTest's app-wide OR/KVC label filtering, which flooded its diagnostics
    /// and crashed inside its log-quarantine callback on iOS 18. The newer header may be outside ActivityListView.
    @MainActor func waitForShareSheetClose(within timeout: TimeInterval = 30) -> XCUIElement? {
        let list = otherElements["ActivityListView"].firstMatch
        let scoped = ["header.closeButton", "Close", "close"].map { list.buttons[$0].firstMatch }
        let floating = ["header.closeButton", "Close", "close"].map { buttons[$0].firstMatch }
        var found: XCUIElement?
        let ready = poll(within: max(timeout, uiWaitFloor)) {
            let candidates = list.exists ? scoped + floating : floating
            for candidate in candidates where candidate.exists && candidate.isHittable {
                found = candidate
                return true
            }
            return false
        }
        return ready ? found : nil
    }
}
