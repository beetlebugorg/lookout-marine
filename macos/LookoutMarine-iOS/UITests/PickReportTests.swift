//  PickReportTests.swift — the report a mariner reads about one object.
//
//  It is raised from the chart menu, which a press opens. On a phone it is a
//  sheet against the bottom edge; on a wide view it is a callout beside the
//  mark. The readouts capsule stands above either one, in the place and the
//  shape it always has.

import XCTest

final class PickReportTests: UITestCase {

    /// The app on the chart with a report open. The process is reused across
    /// the class; the report is raised again for each test, which is the state
    /// every test here starts from.
    private func report() throws -> XCUIApplication {
        let app = try app(["LOOKOUT_VIEW": "-76.4767,38.9763,15"])
        XCTAssertTrue(app.staticTexts["band"].waitForExistence(timeout: 60),
                      "the chart never came up")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.0)
        XCTAssertTrue(app.buttons["Pick report"].waitForExistence(timeout: 10),
                      "a press raised no chart menu")
        app.buttons["Pick report"].tap()
        try XCTSkipUnless(app.buttons["close-report"].waitForExistence(timeout: 5),
                          "the press found no object to report")
        return app
    }

    /// One test opens the scale entry from the capsule.
    override func resetToStart(_ app: XCUIApplication) -> Bool {
        if app.buttons["Close scale entry"].exists { app.buttons["Close scale entry"].tap() }
        return super.resetToStart(app) && app.staticTexts["band"].waitForExistence(timeout: 5)
    }

    /// The controls the report is read with: copy, close, and the fold.
    func testTheReportCarriesItsControls() throws {
        let app = try report()
        XCTAssertTrue(app.buttons["copy-report"].exists, "no way to copy the report")
        XCTAssertTrue(app.buttons["s57-fold"].exists, "no fold to the source attributes")
    }

    /// The fold opens the cell's own words. Nothing the decode did is a
    /// substitute for the source.
    func testTheFoldOpensTheSourceAttributes() throws {
        let app = try report()
        let fold = app.buttons["s57-fold"]
        XCTAssertTrue(fold.label.hasPrefix("Show"), fold.label)
        fold.tap()
        XCTAssertTrue(app.buttons["s57-fold"].label.hasPrefix("Hide"),
                      "the fold did not open")
    }

    /// Close takes it away and leaves the chart where it was.
    func testCloseTakesTheReportAway() throws {
        let app = try report()
        app.buttons["close-report"].tap()
        XCTAssertFalse(app.buttons["close-report"].waitForExistence(timeout: 3),
                       "the report stayed up")
        XCTAssertTrue(app.staticTexts["band"].exists, "the readouts did not come back")
    }

    /// The capsule stands above the sheet rather than being folded into it.
    /// It shows own ship, and with no fix that means no numbers at all.
    ///
    /// The sheet used to carry a copy of the same four readouts, so opening a
    /// report turned the pill into a bar and printed the map centre in the
    /// slot the capsule gives own ship.
    func testTheCapsuleStandsAboveTheSheetAndShowsOwnShip() throws {
        let app = try report()
        let sheet = app.buttons["close-report"].frame
        let gps = app.buttons["configure-gps"]
        XCTAssertTrue(gps.exists, "the capsule went away with the report up")
        XCTAssertLessThan(gps.frame.maxY, sheet.minY,
                          "the capsule is not above the sheet: \(gps.frame) \(sheet)")
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '°' AND label CONTAINS \"'\"")).firstMatch.exists,
            "a coordinate with no fix behind it")
    }

    /// The scale opens its entry over a report, from the one capsule.
    func testTheScaleOpensItsEntryOverAReport() throws {
        let app = try report()
        let scale = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Scale 1:'")).firstMatch
        XCTAssertTrue(scale.exists, "no scale to tap")
        scale.tap()
        XCTAssertTrue(app.staticTexts["Zoom to scale"].waitForExistence(timeout: 10),
                      "the scale opened nothing")
    }
}
