//  PluginTableTests.swift — the tables a plugin declares, on a touch device.
//
//  The Mac opens one from the menu bar. A phone and an iPad have none, so the
//  same declaration is a row in the settings form. Without it an iPad mariner
//  hears a collision alarm and cannot see what raised it.

import XCTest

final class PluginTableTests: XCTestCase {

    private func settingsApp() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LOOKOUT_OPEN"] = try ChartFixture.chart()
        app.launchEnvironment["LOOKOUT_VIEW"] = "-76.4767,38.9763,15"
        app.launchEnvironment["LOOKOUT_SHOW"] = "settings:vessels"
        app.launch()
        return app
    }

    /// The AIS plugin declares one table, and it lands in Vessels because that
    /// is the menu its declaration names.
    func testTheDeclaredTableIsARowInItsOwnSection() throws {
        let app = try settingsApp()
        let row = app.buttons["plugin-table-targets"]
        XCTAssertTrue(row.waitForExistence(timeout: 60),
                      "no row for the declared table in the Vessels section")
        XCTAssertTrue(app.staticTexts["AIS Targets"].exists,
                      "the row does not name the table")
    }

    /// Tapping it pushes the table. With no instrument feed there is no
    /// traffic, so it says so rather than showing an empty grid.
    func testTheRowOpensTheTable() throws {
        let app = try settingsApp()
        let row = app.buttons["plugin-table-targets"]
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        row.tap()
        XCTAssertTrue(app.navigationBars["AIS Targets"].waitForExistence(timeout: 10),
                      "the row opened no table")
        XCTAssertTrue(app.staticTexts["Nothing to show yet"].exists
                        || app.buttons["Sort by Vessel"].exists,
                      "the table showed neither rows nor a reason for none")
    }

    /// Back goes one step, to the section it was opened from.
    func testBackFromTheTableReturnsToTheSection() throws {
        let app = try settingsApp()
        let row = app.buttons["plugin-table-targets"]
        XCTAssertTrue(row.waitForExistence(timeout: 60))
        row.tap()
        XCTAssertTrue(app.navigationBars["AIS Targets"].waitForExistence(timeout: 10))
        app.navigationBars["AIS Targets"].buttons.firstMatch.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5), "Back did not return to the section")
    }
}
