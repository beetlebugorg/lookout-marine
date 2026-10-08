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
        XCTAssertEqual(DepthStep.parseDraft("7"), 7)
        XCTAssertEqual(DepthStep.parseDraft(" 1.8 "), 1.8)
    }

    /// The plan caps a draft past the most the step accepts.
    func testThePlanCapsTheDraftPerUnit() {
        var p = lookout_depth_plan()
        lookout_depth_plan(250 * LOOKOUT_METRES_PER_FOOT, 0, 1, &p)
        XCTAssertEqual(p.draft, p.draft_max)
        XCTAssertEqual(p.draft_max, 100)
        lookout_depth_plan(250, 0, 0, &p)
        XCTAssertEqual(p.draft, 30)
    }

    /// A cleared field, or one partway through an edit, leaves the draft as
    /// it was.
    func testTextThatIsNotADraftParsesToNil() {
        XCTAssertNil(DepthStep.parseDraft(""))
        XCTAssertNil(DepthStep.parseDraft("0"))
        XCTAssertNil(DepthStep.parseDraft("-"))
        XCTAssertNil(DepthStep.parseDraft("abc"))
    }
}
