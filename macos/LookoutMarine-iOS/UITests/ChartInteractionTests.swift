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

        // Pinch IN at screen center → the chart must zoom OUT. (Not a pinch
        // out: a library opens FIT to its most-detailed cell, which sits AT the
        // per-view zoom cap — there is no deeper data there, so zooming in is
        // correctly a no-op. Zooming out always has room: the floor is z4,
        // far below any fit view.)
        app.pinch(withScale: 0.5, velocity: -2.0)
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

    // Zoom-to-cursor anchoring is verified deterministically by the
    // "zoomAbout keeps the point under the cursor fixed" unit test in
    // src/camera.zig (the anchor math both platforms share). The pinch test
    // above proves iOS touches reach that math with the gesture's anchor point.

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
