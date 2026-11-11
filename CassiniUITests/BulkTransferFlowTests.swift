import XCTest
import UIKit

final class BulkTransferFlowTests: XCTestCase {
    @MainActor func testSelectedAndAllZIPExportsReturnToTheSameLibrary() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .phone, "compact library")
        verifySelectedAndAllZIPExports()
    }

    @MainActor func testIPadSelectedAndAllZIPExportsReturnToTheSameLibrary() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad library")
        verifySelectedAndAllZIPExports()
    }

    @MainActor private func verifySelectedAndAllZIPExports() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-data", "--seed-test-data"]
        app.launchAndWait()
        let export = app.buttons["libraryExportZIP"]
        XCTAssertTrue(export.waitForEnabled(within: 15))
        export.tap()
        XCTAssertTrue(app.buttons["bulkExportAll"].waitForExistence(within: 15))
        XCTAssertFalse(app.buttons["bulkExportSelected"].exists, "An empty selection cannot export silently")
        let choice = app.switches["bulkExportChoice-BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"]
        XCTAssertTrue(choice.waitForExistence(within: 15))
        choice.tap()
        let selected = app.buttons["bulkExportSelected"]
        XCTAssertTrue(selected.waitForEnabled(within: 15))
        selected.tap()
        closeShareSheet(app)
        let done = app.staticTexts["bulkExportDone"]
        XCTAssertTrue(done.waitForExistence(within: 15))
        XCTAssertEqual(done.label, "Exported 1 to a ZIP archive")

        XCTAssertTrue(export.waitForEnabled(within: 15))
        export.tap()
        let all = app.buttons["bulkExportAll"]
        XCTAssertTrue(all.waitForEnabled(within: 15))
        all.tap()
        closeShareSheet(app)
        XCTAssertTrue(done.waitForExistence(within: 15))
        XCTAssertEqual(done.label, "Exported 2 to a ZIP archive")
        XCTAssertEqual(app.buttons.matching(identifier: "noteRow").count, 2, "Exports keep both source notes")
    }
}
