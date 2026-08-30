//  RasterChartTests.swift — does the raster chart pill work on iPhone and iPad?
//
//  The pill is the only way in to the raster charts on a touch device: there is
//  no menu bar, and a tablet under way has no keyboard. So the load-bearing
//  questions are whether the pill APPEARS over coverage, whether a tap on it
//  actually reaches it (the chrome window is transparent and passes most
//  touches through to the chart below — the same split that hid the Mac's pill
//  behind a hit-test hole), and whether the list it opens can switch the
//  picture off and on again.
//
//  The raster chart is installed the way a mariner installs one: the path list
//  in defaults, which is what the file picker writes.

import XCTest

final class RasterChartTests: XCTestCase {
    /// A raster chart covering the Chesapeake, dropped into the app's own
    /// Documents. Skips rather than fails when it is absent — this corpus is a
    /// 3.7 GB download, not something a checkout carries.
    private func rasterChart() throws -> String {
        let fm = FileManager.default
        let candidates = [
            ProcessInfo.processInfo.environment["LOOKOUT_TEST_RASTER"],
            NSHomeDirectory() + "/Charts/MBTILES/USA-Atlantic-CMap-Z8-16.mbtiles",
        ].compactMap { $0 }
        guard let found = candidates.first(where: { fm.fileExists(atPath: $0) }) else {
            throw XCTSkip("no raster chart covering the Chesapeake to test with")
        }
        return found
    }

    private func launch(_ raster: String) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["LOOKOUT_OPEN"] = try ChartFixture.chart()
        app.launchEnvironment["LOOKOUT_VIEW"] = "-76.4767,38.9763,13"
        // -AppleLanguages style argument domain: read before the app's own
        // defaults, so the chart is installed before the first frame.
        app.launchArguments += ["-lookout.rastercharts", "(\"\(raster)\")"]
        app.launch()
        return app
    }

    /// The pill names the set and appears only where the chart covers.
    func testPillAppearsOverCoverage() throws {
        let app = try launch(rasterChart())
        let pill = app.buttons["raster-pill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 60),
                      "no raster pill over a raster chart's own coverage")
        XCTAssertTrue(pill.label.uppercased().contains("CMAP"),
                      "the pill does not name the set: '\(pill.label)'")
    }

    /// A TAP ON THE PILL OPENS THE LIST. This is the one that catches the
    /// transparent-chrome-window hole: the pill draws correctly and does
    /// nothing when pressed.
    func testTapOpensTheList() throws {
        let app = try launch(rasterChart())
        let pill = app.buttons["raster-pill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 60), "no raster pill")
        pill.tap()
        XCTAssertTrue(app.buttons["None"].waitForExistence(timeout: 10),
                      "the pill was pressed and no list opened")
        XCTAssertTrue(app.buttons["Add Raster Charts…"].exists,
                      "the list opened without a way to add a chart")
    }

    /// "None" stops drawing, and the pill says so. Choosing the set again
    /// brings it back — the comparison the whole feature exists for.
    func testNoneTurnsItOffAndTheSetBringsItBack() throws {
        let app = try launch(rasterChart())
        let pill = app.buttons["raster-pill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 60), "no raster pill")

        pill.tap()
        let none = app.buttons["None"]
        XCTAssertTrue(none.waitForExistence(timeout: 10), "no list")
        none.tap()
        Thread.sleep(forTimeInterval: 2)

        XCTAssertEqual(state(pill), "off",
                       "the picture was turned off and the pill does not say so")

        pill.tap()
        let cmap = app.buttons.matching(
            NSPredicate(format: "label CONTAINS[c] 'CMap'")).firstMatch
        XCTAssertTrue(cmap.waitForExistence(timeout: 10), "the set is not in its own list")
        cmap.tap()
        Thread.sleep(forTimeInterval: 2)

        XCTAssertEqual(state(pill), "drawn",
                       "the set was chosen and the pill still reads off")
    }

    /// The pill's state as one stable word. The accessibility LABEL is help
    /// text and is free to be reworded; the value is the contract.
    private func state(_ pill: XCUIElement) -> String {
        (pill.value as? String) ?? ""
    }

    /// Hiding the ENC over the raster chart leaves the raster chart drawn, so
    /// the pill keeps naming it and reports which layer is off.
    func testHideEncKeepsTheRasterChart() throws {
        let app = try launch(rasterChart())
        let pill = app.buttons["raster-pill"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 60), "no raster pill")

        pill.tap()
        let hide = app.buttons["Hide ENC Over Raster"]
        XCTAssertTrue(hide.waitForExistence(timeout: 10), "no ENC switch in the list")
        hide.tap()
        Thread.sleep(forTimeInterval: 2)

        // The raster chart is STILL DRAWN — hiding the ENC does not turn the
        // picture off, and the pill must not read as though it had.
        XCTAssertEqual(state(pill), "drawn, ENC hidden",
                       "the ENC was hidden and the pill does not report it")
    }
}
