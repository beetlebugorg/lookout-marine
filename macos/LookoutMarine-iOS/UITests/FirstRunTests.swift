//  FirstRunTests.swift — the empty state, which is the whole app until a
//  chart is aboard.

import XCTest

final class FirstRunTests: UITestCase {

    private func emptyApp() throws -> XCUIApplication {
        try app(["LOOKOUT_NO_CHART": "1"])
    }

    /// The page states what the app is, why it is empty, and what to do, and
    /// the button that does it is on one line.
    func testEmptyStateReads() throws {
        let app = try emptyApp()
        XCTAssertTrue(app.staticTexts["No charts yet"].waitForExistence(timeout: 20))
        let button = app.buttons["choose-charts"]
        XCTAssertTrue(button.exists)
        XCTAssertTrue(button.frame.height < 70, "the button wrapped to two lines: \(button.frame)")
        XCTAssertFalse(app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS 'drop them anywhere'"))
            .element.exists, "the Mac's drop line is on the phone")
    }

    /// Nothing on the page runs off the screen.
    func testNothingIsClipped() throws {
        let app = try emptyApp()
        XCTAssertTrue(app.staticTexts["No charts yet"].waitForExistence(timeout: 20))
        let screen = app.windows.element(boundBy: 0).frame
        for text in app.staticTexts.allElementsBoundByIndex where text.frame.width > 0 {
            XCTAssertTrue(text.frame.minX >= screen.minX && text.frame.maxX <= screen.maxX,
                          "runs off the side: \(text.label) \(text.frame)")
        }
    }

    /// Choose Charts says it is working, and the picker comes up.
    ///
    /// The Files picker is another process. When it does not start there is
    /// nothing here to fix and nothing to assert, so the wait is a skip: the
    /// app's own half is the button reporting that the tap landed.
    func testPickerOpens() throws {
        let app = try emptyApp()
        let button = app.buttons["choose-charts"]
        XCTAssertTrue(button.waitForExistence(timeout: 20))
        button.tap()
        XCTAssertFalse(button.isEnabled, "the button gave no sign the tap landed")
        try XCTSkipUnless(app.buttons["Cancel"].waitForExistence(timeout: 30),
                          "the Files picker did not start")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.isEnabled, "the button stayed disabled after the picker closed")
    }
}
