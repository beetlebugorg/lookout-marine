//  ChartInteractionTests.swift — does touch input actually reach the chart?
//
//  XCUITest injects touches through UIKit's real delivery path (no simulator
//  front-end involved), so this answers the load-bearing question for the
//  windowscene embed: gestures must cross the transparent-chrome-window /
//  SDL-chart-window split and land in ChartUIView's recognizers. The zoom
//  readout ("z11.0") is the oracle: a pinch must change it.

import XCTest

final class ChartInteractionTests: XCTestCase {
    func testPinchZoomsAndDragPans() throws {
        let app = XCUIApplication()
        app.launch()

        // The chart auto-opens from Documents; the scale readout appears with
        // the first render.
        let zoom = app.staticTexts.matching(NSPredicate(format: "label MATCHES 'z[0-9.]+'")).firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 45), "zoom readout never appeared — chart did not open/render")
        let before = zoom.label

        // Pinch out at screen center → the chart must zoom in.
        app.pinch(withScale: 2.0, velocity: 2.0)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertNotEqual(zoom.label, before,
                          "pinch did not change the zoom readout — touches are not reaching the chart")

        // One-finger drag → pan; the app must stay up and keep its readout.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.35))
        from.press(forDuration: 0.05, thenDragTo: to)
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(zoom.exists, "app lost its HUD after a drag")
    }

    /// Anchored zoom ("zoom to cursor"): the chart point under the gesture must
    /// stay under it. Oracle: tap-identify at an off-center point, double-tap
    /// it twice (each zooms +1 anchored there), identify again — the features
    /// under the point must overlap what was there before. A center-anchored
    /// (broken) zoom would shift the geo under an off-center point by most of
    /// half a screen over two levels and change what identify returns.
    func testZoomAnchorsAtThePoint() throws {
        let app = XCUIApplication()
        app.launch()
        let zoom = app.staticTexts.matching(NSPredicate(format: "label MATCHES 'z[0-9.]+'")).firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 45), "zoom readout never appeared")
        Thread.sleep(forTimeInterval: 3) // let the first build land so identify has features
        let z0 = zoom.label

        let p = app.coordinate(withNormalizedOffset: CGVector(dx: 0.68, dy: 0.42))
        p.tap()
        Thread.sleep(forTimeInterval: 2)
        let before = identifyRows(app)
        XCTAssertFalse(before.isEmpty, "no features under the probe point")

        p.doubleTap()
        Thread.sleep(forTimeInterval: 2)
        p.doubleTap()
        Thread.sleep(forTimeInterval: 3)
        XCTAssertNotEqual(zoom.label, z0, "double-tap did not zoom")

        p.tap()
        Thread.sleep(forTimeInterval: 2)
        let after = identifyRows(app)
        XCTAssertFalse(after.isEmpty, "nothing under the point after zooming — anchor drifted off the chart")
        XCTAssertFalse(Set(before).intersection(Set(after)).isEmpty,
                       "features under the point changed entirely after zooming — anchor drifted (before=\(before) after=\(after))")
    }

    /// The S-57 class acronyms currently shown in the identify panel.
    private func identifyRows(_ app: XCUIApplication) -> [String] {
        app.staticTexts.matching(identifier: "identify-cls").allElementsBoundByIndex.map(\.label)
    }

    /// The other half of the PassThroughWindow contract: chrome controls must
    /// KEEP their touches (only empty chrome falls through to the chart).
    func testChromeButtonsStillWork() throws {
        let app = XCUIApplication()
        app.launch()

        let zoom = app.staticTexts.matching(NSPredicate(format: "label MATCHES 'z[0-9.]+'")).firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 45), "zoom readout never appeared")

        // What does the chrome expose? (Shows up in the xcodebuild log.)
        print("BUTTONS: \(app.buttons.allElementsBoundByIndex.map { "\($0.identifier)/\($0.label)@\($0.frame)" })")

        // The settings gear opens the mariner form as a sheet.
        let gear = app.buttons["gearshape"].exists
            ? app.buttons["gearshape"]
            : app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'settings' OR identifier CONTAINS 'gear'")).firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "settings gear button not found in chrome")
        print("TAPPING: \(gear.identifier)/\(gear.label)@\(gear.frame)")
        gear.tap()
        let title = app.staticTexts["Mariner Settings"]
        XCTAssertTrue(title.waitForExistence(timeout: 10),
                      "settings sheet did not open — chrome buttons lost their touches")
    }
}
