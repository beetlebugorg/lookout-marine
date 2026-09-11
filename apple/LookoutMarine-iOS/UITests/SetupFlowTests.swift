//  SetupFlowTests.swift: setup, on a phone.
//
//  LOOKOUT_FIRST_RUN=1 runs the flow whatever the store holds, so a device that
//  has been through setup once still runs these.

import XCTest

final class SetupFlowTests: UITestCase {

    private func setupApp() throws -> XCUIApplication {
        try app(["LOOKOUT_NO_CHART": "1", "LOOKOUT_FIRST_RUN": "1"])
    }

    override func resetToStart(_ app: XCUIApplication) -> Bool {
        // Walk back to the first step from wherever the last test finished.
        for _ in 0..<3 {
            guard app.buttons["first-run-back"].exists else { break }
            app.buttons["first-run-back"].tap()
        }
        return app.staticTexts["Welcome to Lookout Marine"].waitForExistence(timeout: 5)
    }

    /// The welcome step names the app and offers a way forward and a way out.
    func testWelcomeReads() throws {
        let app = try setupApp()
        XCTAssertTrue(app.staticTexts["Welcome to Lookout Marine"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["first-run-continue"].exists)
        XCTAssertTrue(app.buttons["first-run-later"].exists)
        // The first step has nowhere to go back to.
        XCTAssertFalse(app.buttons["first-run-back"].exists)
    }

    /// Set Up Later leaves setup and lands on the empty page.
    func testSetUpLaterLeaves() throws {
        let app = try setupApp()
        XCTAssertTrue(app.buttons["first-run-later"].waitForExistence(timeout: 20))
        app.buttons["first-run-later"].tap()
        XCTAssertTrue(app.staticTexts["No charts yet"].waitForExistence(timeout: 10))
    }

    /// Continue reaches the source step, which offers all three sources with
    /// NOAA chosen.
    func testSourceStepOffersEverySource() throws {
        let app = try setupApp()
        XCTAssertTrue(app.buttons["first-run-continue"].waitForExistence(timeout: 20))
        app.buttons["first-run-continue"].tap()

        XCTAssertTrue(app.buttons["source-NOAA charts"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["source-Online chart"].exists)
        XCTAssertTrue(app.buttons["source-Files on this iPhone"].exists)
        XCTAssertTrue(app.buttons["source-NOAA charts"].isSelected,
                      "NOAA is the preselected source")
        XCTAssertTrue(app.buttons["first-run-back"].exists)
    }

    /// NOAA leads to the regions, which are the districts the core publishes.
    func testCoverageStepListsRegions() throws {
        let app = try setupApp()
        XCTAssertTrue(app.buttons["first-run-continue"].waitForExistence(timeout: 20))
        app.buttons["first-run-continue"].tap()
        XCTAssertTrue(app.buttons["source-NOAA charts"].waitForExistence(timeout: 10))
        app.buttons["first-run-continue"].tap()

        XCTAssertTrue(app.staticTexts["Which waters do you sail?"].waitForExistence(timeout: 10))
        // Nine Coast Guard districts, each with a row of its own.
        for id in ["d1", "d5", "d7", "d8", "d9", "d11", "d13", "d14", "d17"] {
            XCTAssertTrue(app.buttons["region-\(id)"].exists, "no row for region \(id)")
        }
        XCTAssertFalse(app.buttons["region-d3"].exists,
                       "district 3 was disestablished and ships no cells")
    }

    /// The regions run past the bottom of a phone screen, so the step scrolls
    /// to reach the last of them.
    func testCoverageStepScrollsToTheLastRegion() throws {
        let app = try setupApp()
        XCTAssertTrue(app.buttons["first-run-continue"].waitForExistence(timeout: 20))
        app.buttons["first-run-continue"].tap()
        XCTAssertTrue(app.buttons["source-NOAA charts"].waitForExistence(timeout: 10))
        app.buttons["first-run-continue"].tap()

        XCTAssertTrue(app.staticTexts["Which waters do you sail?"].waitForExistence(timeout: 10))
        let last = app.buttons["region-d17"]   // Alaska, the last one listed
        XCTAssertTrue(last.waitForExistence(timeout: 10))
        try XCTSkipIf(last.isHittable, "every region is on screen, so there is no scroll to test")
        app.swipeUp()
        XCTAssertTrue(last.isHittable, "the step did not scroll to the last region")
    }

    /// Picking Online chart reaches the link field, and Back returns.
    func testOnlineChartStepAndBack() throws {
        let app = try setupApp()
        XCTAssertTrue(app.buttons["first-run-continue"].waitForExistence(timeout: 20))
        app.buttons["first-run-continue"].tap()
        XCTAssertTrue(app.buttons["source-Online chart"].waitForExistence(timeout: 10))
        app.buttons["source-Online chart"].tap()
        app.buttons["first-run-continue"].tap()

        XCTAssertTrue(app.textFields["first-run-chart-link"].waitForExistence(timeout: 10))
        app.buttons["first-run-back"].tap()
        XCTAssertTrue(app.buttons["source-Online chart"].waitForExistence(timeout: 10))
    }
}
