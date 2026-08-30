//  HudTests.swift — the readouts, and the controls in the chrome.
//
//  The chrome floats in a pass-through window over the chart. Every control in
//  it can be swallowed by that split, and every readout can be dropped when the
//  row will not fit, so these check that each one is there and answers.

import XCTest

final class HudTests: XCTestCase {

    private func app(view: String = "-76.4767,38.9763,15") throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LOOKOUT_OPEN"] = try ChartFixture.chart()
        app.launchEnvironment["LOOKOUT_VIEW"] = view
        app.launch()
        XCTAssertTrue(app.staticTexts["band"].waitForExistence(timeout: 60),
                      "the readouts never appeared")
        return app
    }

    /// Nothing is dropped when the row will not fit: it falls to two lines.
    func testEveryReadoutIsOnScreen() throws {
        let app = try app()
        XCTAssertTrue(app.staticTexts["band"].exists)
        XCTAssertTrue(app.buttons["scale-readout"].exists)
        // The zoom, which is the one readout with no control on it.
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'z1'")).firstMatch.exists,
            "no zoom readout")
    }

    /// The band names the navigational purpose the chart is drawn for.
    func testTheBandIsAPurposeAndNotANumber() throws {
        let app = try app()
        XCTAssertTrue(["Overview", "General", "Coastal", "Approach", "Harbor", "Berthing"]
            .contains(app.staticTexts["band"].label),
            "the band read \(app.staticTexts["band"].label)")
    }

    /// With no source of position the readout shows NO NUMBERS, and offers the
    /// one thing that would fix it.
    func testWithNoSourceItOffersTheFix() throws {
        let app = try app()
        XCTAssertTrue(app.buttons["configure-gps"].exists,
                      "no way to say where the position should come from")
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '°' AND label CONTAINS \"'\"")).firstMatch.exists,
            "a coordinate is shown with no fix behind it")
    }

    /// It routes to Connections, which is where a gateway or a Signal K server
    /// is added. This is the one place the app tells a mariner they have no
    /// position, so it carries the fix.
    func testConfigureGpsRoutesToConnections() throws {
        let app = try app()
        app.buttons["configure-gps"].tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 10)
                        || app.staticTexts["Connections"].waitForExistence(timeout: 5),
                      "Configure GPS did not open Connections")
    }

    /// The scale readout opens the scale entry, which starts at the scale it
    /// was showing.
    func testTheScaleReadoutOpensTheScaleEntry() throws {
        let app = try app()
        app.buttons["scale-readout"].tap()
        XCTAssertTrue(app.staticTexts["Zoom to scale"].waitForExistence(timeout: 10),
                      "the scale readout opened nothing")
        XCTAssertTrue(app.buttons["Go"].exists)
        // The preset's label is the band and its scale together.
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Harbor'")).firstMatch.exists,
            "no band presets")
    }

    /// The zoom bubbles reach the chart across the window split.
    func testTheZoomBubblesMoveTheChart() throws {
        let app = try app()
        let zoom = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'z1'")).firstMatch
        let before = zoom.label
        app.buttons["minus"].tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertNotEqual(zoom.label, before, "Zoom out did not reach the chart")
    }

    /// The compass locks the chart to own ship. With no fix it is armed and
    /// waiting, which is a state of its own and not a failure.
    func testTheCompassArmsWithNoFix() throws {
        let app = try app()
        let compass = app.buttons["compass"]
        XCTAssertEqual(compass.value as? String, "free")
        compass.tap()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertEqual(compass.value as? String, "armed",
                       "following own ship with no fix should arm, not lock")
    }

    /// The scale bar is a round distance, and the chart credit rides with it.
    func testTheScaleBarIsARoundDistance() throws {
        let app = try app()
        let bar = app.staticTexts["scale-bar"]
        XCTAssertTrue(bar.exists, "no scale bar")
        XCTAssertTrue(bar.label.hasSuffix(" m") || bar.label.hasSuffix(" km"), bar.label)
    }

    /// The settings bubble opens the form, and Done puts it away.
    func testTheSettingsBubbleOpensTheForm() throws {
        let app = try app()
        app.buttons["gearshape"].tap()
        XCTAssertTrue(app.navigationBars["Mariner Settings"].waitForExistence(timeout: 10),
                      "the gear opened nothing")
        app.buttons["Done"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["band"].waitForExistence(timeout: 5),
                      "Done did not bring the chart back")
    }
}
