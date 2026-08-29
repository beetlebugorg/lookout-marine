//  ChartInteractionTests.swift — does touch input actually reach the chart?
//
//  XCUITest injects touches through UIKit's real delivery path (no simulator
//  front-end involved), so this answers the load-bearing question for the
//  windowscene embed: gestures must cross the transparent-chrome-window /
//  SDL-chart-window split and land in ChartUIView's recognizers. The zoom
//  readout ("z11.0") is the oracle: a pinch must change it.

import XCTest

final class ChartInteractionTests: XCTestCase {
    /// A pick low on a phone falls under the bottom sheet. The chart lifts
    /// until the mark clears the sheet (§2.2).
    ///
    /// The oracle is the position readout, which names the centre of the
    /// view. The app moves the chart, so that position must change. A wide
    /// view uses a callout and does not move.
    func testChartLiftsToRevealAPickUnderTheSheet() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LOOKOUT_OPEN"] = try ChartFixture.chart()
        app.launchEnvironment["LOOKOUT_VIEW"] = "-76.4767,38.9763,15"
        app.launch()

        // The position readout, which names the centre of the view.
        let position = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '°' AND label CONTAINS 'N'")).firstMatch
        XCTAssertTrue(position.waitForExistence(timeout: 60), "position readout never appeared")
        let before = position.label

        // A tap low on the chart — where the sheet will stand.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.82)).tap()
        Thread.sleep(forTimeInterval: 3)

        let objects = app.staticTexts.matching(
            NSPredicate(format: "label ENDSWITH 'OBJECTS'")).firstMatch
        let sheet = objects.exists || app.buttons["Close the pick report"].exists
        try XCTSkipUnless(sheet, "the tap found no object to report; nothing to reveal")

        XCTAssertNotEqual(position.label, before,
                          "the chart did not move to bring the object out from under the sheet")
    }

    func testPinchZoomsAndDragPans() throws {
        let app = XCUIApplication()
        // A fixed chart and view, so the pinch starts with room to zoom out.
        // Documents can open on the z4 floor, where a pinch out is correctly
        // a no-op and the assertion below fails for the wrong reason.
        app.launchEnvironment["LOOKOUT_OPEN"] = try ChartFixture.chart()
        app.launchEnvironment["LOOKOUT_VIEW"] = "-76.4767,38.9763,15"
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

    /// Not a correctness test: ~60s of continuous pans + pinches to keep the
    /// render loop hot, so Instruments (or the app's own "frame:" stats line)
    /// can profile SUSTAINED interaction. Attaches to an already-running app
    /// (activate, not launch) so a console started with
    /// `simctl launch --console-pty` keeps streaming the app's stderr.
    /// Skipped unless LOOKOUT_SOAK=1 (pass TEST_RUNNER_LOOKOUT_SOAK=1 through
    /// xcodebuild) so the regular test plan stays fast.
    func testInteractionSoakForProfiling() throws {
        guard ProcessInfo.processInfo.environment["LOOKOUT_SOAK"] == "1" else {
            throw XCTSkip("set LOOKOUT_SOAK=1 to run the profiling soak")
        }
        let app = XCUIApplication()
        app.activate()
        let zoom = app.staticTexts.matching(NSPredicate(format: "label MATCHES 'z[0-9.]+'")).firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 45), "zoom readout never appeared")

        let deadline = Date().addingTimeInterval(60)
        var flip = false
        while Date() < deadline {
            let from = app.coordinate(withNormalizedOffset: CGVector(dx: flip ? 0.65 : 0.35, dy: 0.5))
            let to = app.coordinate(withNormalizedOffset: CGVector(dx: flip ? 0.35 : 0.65, dy: flip ? 0.42 : 0.58))
            from.press(forDuration: 0.02, thenDragTo: to)
            app.pinch(withScale: flip ? 0.7 : 1.5, velocity: flip ? -3.0 : 3.0)
            flip.toggle()
        }
        XCTAssertTrue(zoom.exists, "app died during the soak")
    }

    /// Rotation: the chart window stack and chrome must survive an orientation
    /// change (drawable resize -> engine rebuild) with the HUD still present.
    func testRotationKeepsChartAlive() throws {
        let app = XCUIApplication()
        app.launch()
        let zoom = app.staticTexts.matching(NSPredicate(format: "label MATCHES 'z[0-9.]+'")).firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 45), "zoom readout never appeared")

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(zoom.exists, "HUD lost after rotating to landscape")
        app.pinch(withScale: 0.7, velocity: -2.0)
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(zoom.exists, "chart died interacting in landscape")

        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 4)
        XCTAssertTrue(zoom.exists, "HUD lost after rotating back to portrait")
    }

    /// Not a correctness test: frames the chart for a README/screenshot pass —
    /// landscape, double-tap-zoomed into the harbor — then HOLDS so an outside
    /// `simctl io screenshot` can capture the live app. Attaches to the running
    /// app (activate) to keep its opened chart. Skipped unless LOOKOUT_FRAME=1
    /// (pass TEST_RUNNER_LOOKOUT_FRAME=1 through xcodebuild).
    func testFrameForScreenshot() throws {
        guard ProcessInfo.processInfo.environment["LOOKOUT_FRAME"] == "1" else {
            throw XCTSkip("set LOOKOUT_FRAME=1 to run the screenshot framing hold")
        }
        let app = XCUIApplication()
        app.activate()
        let zoom = app.staticTexts.matching(NSPredicate(format: "label MATCHES 'z[0-9.]+'")).firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 45), "zoom readout never appeared")

        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 4)

        // Zoom toward the harbor (double-tap anchors at the tap point); pause
        // between taps so each band rebuild lands before the next step.
        let harbor = app.coordinate(withNormalizedOffset: CGVector(dx: 0.45, dy: 0.42))
        for _ in 0..<2 {
            harbor.doubleTap()
            Thread.sleep(forTimeInterval: 3)
        }
        // Capture window: screenshots are taken from outside during this hold.
        Thread.sleep(forTimeInterval: 40)
        XCTAssertTrue(zoom.exists, "app died while holding for the screenshot")
    }

    /// The portrait twin of the framing hold: turn upright and hold, leaving
    /// whatever the launch environment opened (a pick, a panel) on screen.
    /// Attach to a running app; launching here would drop its environment.
    func testPortraitHoldForScreenshot() throws {
        guard ProcessInfo.processInfo.environment["LOOKOUT_PORTRAIT"] == "1" else {
            throw XCTSkip("set LOOKOUT_PORTRAIT=1 to run the portrait screenshot hold")
        }
        let app = XCUIApplication()
        app.activate()
        let zoom = app.staticTexts.matching(NSPredicate(format: "label MATCHES 'z[0-9.]+'")).firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 45), "zoom readout never appeared")
        XCUIDevice.shared.orientation = .portrait
        Thread.sleep(forTimeInterval: 40)
        XCTAssertTrue(zoom.exists, "app died while holding for the screenshot")
    }

    /// The hardware keyboard drives the pick report. This test covers the
    /// responder chain, not the actions. AppModel owns the actions.
    ///
    /// The oracle is the report's text. The arrows move the selection and the
    /// detail pane follows.
    func testHardwareKeyboardWalksThePickList() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LOOKOUT_OPEN"] = try ChartFixture.chart()
        app.launchEnvironment["LOOKOUT_VIEW"] = "-76.4767,38.9763,15"
        app.launchEnvironment["LOOKOUT_SHOW"] = "pick"
        app.launch()

        // The pick's object list heads the card: "N OBJECTS".
        let objects = app.staticTexts.matching(
            NSPredicate(format: "label ENDSWITH 'OBJECTS'")).firstMatch
        XCTAssertTrue(objects.waitForExistence(timeout: 60),
                      "pick report never opened — nothing to drive with the keyboard")

        // The whole report's text: the detail pane reads out the selected
        // object, so the set changes when — and only when — the selection does.
        func page() -> Set<String> {
            Set(app.staticTexts.allElementsBoundByIndex.map { $0.label })
        }
        let first = page()

        app.typeKey(XCUIKeyboardKey.downArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(objects.exists, "↓ closed the report")
        XCTAssertNotEqual(page(), first, "↓ did not move the pick's selection")

        app.typeKey(XCUIKeyboardKey.upArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(objects.exists, "↑ closed the report")
        XCTAssertEqual(page(), first, "↑ did not walk back to the first object")

        // This test does not assert Escape. XCUITest does not deliver the
        // Escape key to the app, so the assertion would report a limit of the
        // harness as a defect of the app. Check Escape by hand on a device
        // with a keyboard.
    }

    /// The chrome keeps its taps while a pick report is open.
    ///
    /// The callout is laid out inside a full-size frame. A full-size frame
    /// that also hit-tests takes every tap on the screen.
    /// `testChromeButtonsStillWork` runs with no report open and cannot cover
    /// this.
    func testChromeButtonsWorkWithPickReportOpen() throws {
        let app = XCUIApplication()
        app.launchEnvironment["LOOKOUT_OPEN"] = try ChartFixture.chart()
        app.launchEnvironment["LOOKOUT_VIEW"] = "-76.4767,38.9763,15"
        app.launchEnvironment["LOOKOUT_SHOW"] = "pick"
        // Log which path answers each hit test; the map must be the one.
        app.launchEnvironment["LOOKOUT_HITMAP"] = "1"
        app.launch()

        let objects = app.staticTexts.matching(
            NSPredicate(format: "label ENDSWITH 'OBJECTS'")).firstMatch
        XCTAssertTrue(objects.waitForExistence(timeout: 60), "pick report never opened")

        let zoom = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES 'z[0-9.]+'")).firstMatch
        XCTAssertTrue(zoom.waitForExistence(timeout: 20), "zoom readout never appeared")

        // The zoom bubble: a control far from the report.
        let zoomIn = app.buttons["plus"].exists
            ? app.buttons["plus"]
            : app.buttons.matching(
                NSPredicate(format: "label CONTAINS[c] 'zoom in'")).firstMatch
        XCTAssertTrue(zoomIn.waitForExistence(timeout: 10), "zoom-in bubble not found")
        let before = zoom.label
        zoomIn.tap()
        Thread.sleep(forTimeInterval: 2)
        XCTAssertNotEqual(zoom.label, before,
                          "the zoom bubble did nothing while a report was open — the report is swallowing chrome taps")

        // The gear, which is under the report's corner of the screen.
        let gear = app.buttons["gearshape"].exists
            ? app.buttons["gearshape"]
            : app.buttons.matching(
                NSPredicate(format: "identifier CONTAINS 'gear'")).firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 10), "settings gear not found")
        gear.tap()
        XCTAssertTrue(app.staticTexts["Mariner Settings"].waitForExistence(timeout: 10),
                      "settings sheet did not open while a report was open")
    }

    /// Opens the mariner form, sets the scheme to Night and then to Day, and
    /// holds after each change. An outside `simctl io screenshot` checks that
    /// the form follows both ways. The return to Day is the case that fails
    /// when the form removes its colour-scheme preference instead of setting
    /// one. Skipped unless LOOKOUT_SCHEMEHOLD=1.
    func testSchemeHoldForScreenshot() throws {
        guard ProcessInfo.processInfo.environment["LOOKOUT_SCHEMEHOLD"] == "1" else {
            throw XCTSkip("set LOOKOUT_SCHEMEHOLD=1 to run the scheme hold")
        }
        let app = XCUIApplication()
        app.launchEnvironment["LOOKOUT_OPEN"] = try ChartFixture.chart()
        app.launchEnvironment["LOOKOUT_VIEW"] = "-76.4767,38.9763,15"
        app.launchEnvironment["LOOKOUT_SHOW"] = "settings"
        app.launch()

        XCTAssertTrue(app.staticTexts["Mariner Settings"].waitForExistence(timeout: 60),
                      "settings sheet never opened")
        app.buttons["Night"].tap()
        Thread.sleep(forTimeInterval: 20)   // capture window: form must be dark
        app.buttons["Day"].tap()
        Thread.sleep(forTimeInterval: 25)   // capture window: form must be light AGAIN
        XCTAssertTrue(app.staticTexts["Mariner Settings"].exists, "the form went away")
    }

    /// Holds a pick open on the CURRENT orientation so an outside
    /// `simctl io screenshot` can check the callout stands clear of its mark.
    /// Skipped unless LOOKOUT_PICKHOLD=1.
    func testPickHoldForScreenshot() throws {
        guard ProcessInfo.processInfo.environment["LOOKOUT_PICKHOLD"] == "1" else {
            throw XCTSkip("set LOOKOUT_PICKHOLD=1 to run the pick screenshot hold")
        }
        let app = XCUIApplication()
        app.launchEnvironment["LOOKOUT_OPEN"] = try ChartFixture.chart()
        app.launchEnvironment["LOOKOUT_VIEW"] = "-76.4767,38.9763,15"
        app.launchEnvironment["LOOKOUT_SHOW"] = "pick"
        app.launch()
        let objects = app.staticTexts.matching(
            NSPredicate(format: "label ENDSWITH 'OBJECTS'")).firstMatch
        XCTAssertTrue(objects.waitForExistence(timeout: 60), "pick report never opened")
        Thread.sleep(forTimeInterval: 40)
        XCTAssertTrue(objects.exists, "app died while holding for the screenshot")
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
