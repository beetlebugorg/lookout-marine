//  PluginInstallTests.swift — installing a plugin on a touch device.
//
//  The consent sheet has always been wired on both platforms; only the entry
//  point was missing, so an iPad could carry the shipped set and nothing else.

import XCTest

final class PluginInstallTests: XCTestCase {

    private func pluginsPane() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LOOKOUT_OPEN"] = try ChartFixture.chart()
        app.launchEnvironment["LOOKOUT_SHOW"] = "settings:plugins"
        app.launch()
        return app
    }

    /// The section is listed whatever is installed. It used to appear only when
    /// a non-bundled plugin was loaded, because nothing on iOS could install
    /// one, which left a device carrying only the shipped set with no way in.
    func testThePluginsSectionIsAlwaysListed() throws {
        let app = try pluginsPane()
        XCTAssertTrue(app.buttons["install-plugin"].waitForExistence(timeout: 60),
                      "no way to install a plugin")
    }

    /// The shipped set is the product: it takes no consent surface and never
    /// appears here.
    func testTheShippedSetIsNotListed() throws {
        let app = try pluginsPane()
        XCTAssertTrue(app.buttons["install-plugin"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.staticTexts["No plugins installed."].exists,
                      "the shipped plugins are listed as if the mariner put them there")
        XCTAssertFalse(app.staticTexts["AIS"].exists)
    }

    /// Install Plugin… opens the Files picker rather than doing nothing.
    func testInstallOpensThePicker() throws {
        let app = try pluginsPane()
        let button = app.buttons["install-plugin"]
        XCTAssertTrue(button.waitForExistence(timeout: 60))
        button.tap()
        // The picker is another process, so it is found on the springboard.
        let files = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        let up = files.wait(for: .runningForeground, timeout: 10)
            || app.navigationBars.count > 1
        XCTAssertTrue(up, "Install Plugin… opened no picker")
    }
}
