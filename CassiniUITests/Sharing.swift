import XCTest

extension XCUIApplication {
    /// iOS 26's newer share header uses a stable identifier and lowercase label; older sheets use "Close".
    @MainActor var shareSheetCloseButton: XCUIElement {
        buttons.matching(NSPredicate(format: "identifier == %@ OR label ==[c] %@",
                                     "header.closeButton", "Close")).firstMatch
    }
}
