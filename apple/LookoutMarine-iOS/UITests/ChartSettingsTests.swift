//  ChartSettingsTests.swift: the Charts pane of Mariner settings.
//
//  LOOKOUT_SHOW=settings:charts opens the form on that pane, which is the
//  only way in without a pointer to press the settings button with.

import XCTest

final class ChartSettingsTests: UITestCase {

    private func settingsApp() throws -> XCUIApplication {
        try app(["LOOKOUT_SHOW": "settings:charts"])
    }

    /// The NOAA picker opens from the Add charts row and stays open. It is
    /// presented from a row inside the form's list, and a sheet owned by a row
    /// goes away with the row.
    func testNoaaPickerStaysUp() throws {
        let app = try settingsApp()
        let row = app.buttons["get-charts-noaa"]
        XCTAssertTrue(row.waitForExistence(timeout: 30))
        row.tap()

        let download = app.buttons["Download"]
        XCTAssertTrue(download.waitForExistence(timeout: 10),
                      "the picker did not open")
        // Long enough for a sheet the form tears down to have gone.
        Thread.sleep(forTimeInterval: 3)
        XCTAssertTrue(download.exists, "the picker closed itself")
        XCTAssertTrue(app.buttons["Cancel"].exists)
    }
}
