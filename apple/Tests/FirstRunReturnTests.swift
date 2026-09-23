//  FirstRunReturnTests.swift — when setup comes back.
//
//  Setup runs on an empty library. Finishing it puts it away, and a mariner
//  who then removes every chart has an empty library again and the same
//  questions to answer. Set Up Later is a different answer and stands.

import XCTest
@testable import LookoutMarine

/// The app's wiring to the core's setup state machine. The state machine's
/// own cases are tested in src/firstrun.zig.
@MainActor
final class FirstRunReturnTests: ShellTestCase {

    /// A set holding one prepared chart, switched on.
    private func drawableSet() -> ChartSet {
        ChartSet(path: "/charts/noaa",
                 producer: "US",
                 preparedPath: nil,
                 cells: [ScannedCell(path: "/charts/noaa/US5MA1BO.pmtiles",
                                     name: "US5MA1BO",
                                     kind: .baked,
                                     band: 5,
                                     bytes: 1)],
                 rasters: [],
                 on: true)
    }

    /// Setup was put away over a library with charts. The mariner removes
    /// every chart, and the app notes the library and raises setup.
    func testSetupComesBackWhenTheLibraryGoesEmpty() {
        let app = AppModel()
        app.charts.sets = [drawableSet()]
        app.noteSetup()
        XCTAssertFalse(app.firstRun.showing)
        app.firstRun.finish()

        // Every chart removed.
        app.charts.sets = []
        app.noteSetup()

        XCTAssertTrue(app.firstRun.showing)
        XCTAssertEqual(app.firstRun.step, .welcome)
    }
}

/// The depth step's draft field. The field is parsed on every edit, so Start
/// Sailing applies a typed draft without Return.
final class DepthStepDraftTests: XCTestCase {

    func testATypedDraftParses() {
        XCTAssertEqual(DepthStep.parseDraft("7", feet: true), 7)
        XCTAssertEqual(DepthStep.parseDraft(" 1.8 ", feet: false), 1.8)
    }

    func testADraftIsCappedPerUnit() {
        XCTAssertEqual(DepthStep.parseDraft("250", feet: true), 100)
        XCTAssertEqual(DepthStep.parseDraft("250", feet: false), 30)
    }

    /// A cleared field, or one partway through an edit, leaves the draft as
    /// it was.
    func testTextThatIsNotADraftParsesToNil() {
        XCTAssertNil(DepthStep.parseDraft("", feet: true))
        XCTAssertNil(DepthStep.parseDraft("0", feet: true))
        XCTAssertNil(DepthStep.parseDraft("-", feet: true))
        XCTAssertNil(DepthStep.parseDraft("abc", feet: true))
    }
}
