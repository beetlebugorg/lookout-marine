//  CompactHudTests.swift — the phone's readouts.
//
//  A phone cannot fit the whole row on one line: the position alone is 44% of
//  an iPhone's width, and with the raster chart pill beside it the capsule
//  overflowed the screen and lost its shape.
//
//  The row is offered one line and falls to two only when it will not fit, so
//  nothing is ever dropped. These check that: the position stays readable, it
//  is in the convention a mariner works in, the scale still opens its entry,
//  and nothing is silently truncated.

import XCTest

final class CompactHudTests: XCTestCase {
    private let bands = ["Overview", "General", "Coastal", "Approach", "Harbour", "Berthing"]

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LOOKOUT_OPEN"] =
            "/Users/claude/Charts/ENC_ROOT/US5MD1MC/US5MD1MC.pmtiles"
        app.launchEnvironment["LOOKOUT_VIEW"] = "-76.4767,38.9763,14"
        app.launch()
        return app
    }

    /// The band readout, which is also the part of the row that carries no
    /// control — so a tap on it is a tap on the row itself.
    private func bandText(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label IN %@", bands)).firstMatch
    }

    private func position(_ app: XCUIApplication) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '°' AND label CONTAINS 'N'")).firstMatch
    }

    private func skipUnlessCompact(_ app: XCUIApplication) throws {
        // The same threshold the app uses to choose the compact row.
        try XCTSkipUnless(app.windows.firstMatch.frame.width < 700,
                          "not a compact width; the whole row fits")
    }

    /// The position is ALWAYS readable. The row falls to two lines rather than
    /// dropping it — it is the one readout a mariner may have to write down or
    /// pass over the radio, and it becomes the vessel's own once there is a GPS.
    func testPositionIsAlwaysVisible() throws {
        let app = launch()
        let band = bandText(app)
        XCTAssertTrue(band.waitForExistence(timeout: 60), "no readouts")
        try skipUnlessCompact(app)

        XCTAssertTrue(position(app).exists,
                      "the phone dropped the position instead of taking a second line")
    }

    /// Degrees and DECIMAL MINUTES, which is what a mariner works in. Seconds
    /// would read as a position and be the wrong convention.
    func testPositionIsDegreesAndDecimalMinutes() throws {
        let app = launch()
        let pos = position(app)
        XCTAssertTrue(pos.waitForExistence(timeout: 60), "no position")
        XCTAssertFalse(pos.label.contains("\""),
                       "the position is in seconds: '\(pos.label)'")
        XCTAssertTrue(pos.label.contains("."),
                      "the position has no decimal minutes: '\(pos.label)'")
    }

    /// THE ROW'S TAP MUST NOT EAT THE CONTROLS. The scale readout opens the
    /// scale entry; it shares the row with the gesture that reveals the
    /// position, and the inner control has to win on its own area.
    func testScaleStillOpensItsEntry() throws {
        let app = launch()
        let band = bandText(app)
        XCTAssertTrue(band.waitForExistence(timeout: 60), "no readouts")
        try skipUnlessCompact(app)

        let scale = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Scale 1:'")).firstMatch
        XCTAssertTrue(scale.waitForExistence(timeout: 10), "no scale readout")
        scale.tap()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 5),
                      "the scale readout did not open the scale entry")
    }

    /// Nothing in the row is truncated. A Menu reports an ideal width that does
    /// not cover its label, which silently clipped the scale to "1:26,9…" and
    /// the pill's name to "GO…" — both of which still LOOK like a readout.
    func testNothingIsTruncated() throws {
        let app = launch()
        let band = bandText(app)
        XCTAssertTrue(band.waitForExistence(timeout: 60), "no readouts")
        try skipUnlessCompact(app)

        let clipped = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '…'")).firstMatch
        XCTAssertFalse(clipped.exists, "a readout is truncated: '\(clipped.label)'")
    }
}
