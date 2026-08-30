//  UITestCase.swift — one app launch per test class, not per test.
//
//  XCTest makes a new instance for every test method, so an XCUIApplication
//  held in an instance property means a launch per test: about seven seconds
//  each once the chart is open, which was half the suite's wall time.
//
//  The process is reused; the screen state is not. Each test asks for the app
//  and then navigates to what it needs, which costs about a second. Where a
//  test does mean to stack on the one before it, it says so and the class runs
//  in the order the names sort in.

import XCTest

class UITestCase: XCTestCase {

    /// The launch environment the running app was started with. A test asking
    /// for a different one gets a fresh launch.
    private static var launchedWith: [String: String] = [:]

    /// The app for this class. Launched by the first test that asks and reused
    /// by the rest, unless the environment differs.
    ///
    /// `reset` runs when the app is being reused, to put the screen back where
    /// a test expects to start. Override `resetToStart` in the class.
    func app(_ environment: [String: String] = [:],
             file: StaticString = #filePath, line: UInt = #line) throws -> XCUIApplication {
        var env = environment
        if env["LOOKOUT_OPEN"] == nil, env["LOOKOUT_NO_CHART"] == nil {
            env["LOOKOUT_OPEN"] = try ChartFixture.chart(file: file, line: line)
        }
        env["LOOKOUT_NO_CHART"] = nil

        let app = XCUIApplication()
        if app.state == .runningForeground, Self.launchedWith == env, resetToStart(app) {
            return app
        }
        if app.state != .notRunning { app.terminate() }
        app.launchEnvironment = env
        app.launch()
        Self.launchedWith = env
        return app
    }

    /// A launch of its own, for a test that must not see what the last one
    /// left behind.
    func freshApp(_ environment: [String: String] = [:],
                  file: StaticString = #filePath, line: UInt = #line) throws -> XCUIApplication {
        XCUIApplication().terminate()
        Self.launchedWith = [:]
        return try app(environment, file: file, line: line)
    }

    /// Put the screen back where a test expects to start, and say whether it
    /// worked. False relaunches, which is the way back from anywhere.
    ///
    /// The default closes what a previous test left over the chart.
    @discardableResult
    func resetToStart(_ app: XCUIApplication) -> Bool {
        if app.buttons["close-report"].exists { app.buttons["close-report"].tap() }
        if app.buttons["Pick report"].exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.2)).tap()
        }
        return true
    }

    /// The chart is up once the scale bar is, which needs no fix and no plugin.
    @discardableResult
    func waitForChart(_ app: XCUIApplication, timeout: TimeInterval = 60) -> Bool {
        app.staticTexts["scale-bar"].waitForExistence(timeout: timeout)
    }

    /// Leave nothing running for the next class.
    override class func tearDown() {
        XCUIApplication().terminate()
        launchedWith = [:]
        super.tearDown()
    }
}
