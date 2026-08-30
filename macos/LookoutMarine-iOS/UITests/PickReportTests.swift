//  PickReportTests.swift — the report a mariner reads about one object.
//
//  It is raised from the chart menu, which a press opens. On a phone it is a
//  sheet against the bottom edge with the readouts folded into its footer; on a
//  wide view it is a callout beside the mark.

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

    /// One test opens the scale entry from the footer.
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

    /// A phone folds the readouts into the sheet's footer, so the sheet and the
    /// capsule do not fight for the bottom of the screen. The footer shows own
    /// ship, and with no fix that means no numbers at all.
    func testTheSheetFooterShowsOwnShipAndNotTheCamera() throws {
        let app = try report()
        try XCTSkipUnless(app.windows.firstMatch.frame.width < 700,
                          "a wide view keeps the capsule and uses a callout")
        XCTAssertTrue(app.buttons["configure-gps"].exists,
                      "the footer dropped the position readout")
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '°' AND label CONTAINS \"'\"")).firstMatch.exists,
            "the footer shows a coordinate with no fix behind it")
    }

    /// The scale still opens its entry from the footer.
    func testTheFooterScaleStillOpensTheEntry() throws {
        let app = try report()
        try XCTSkipUnless(app.windows.firstMatch.frame.width < 700, "no sheet on a wide view")
        let scale = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Scale 1:'")).firstMatch
        XCTAssertTrue(scale.exists, "no scale in the footer")
        scale.tap()
        XCTAssertTrue(app.staticTexts["Zoom to scale"].waitForExistence(timeout: 10),
                      "the footer's scale opened nothing")
    }
}
