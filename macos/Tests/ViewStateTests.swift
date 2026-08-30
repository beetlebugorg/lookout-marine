//  ViewStateTests.swift — the camera pose across launches.
//
//  Reopening on the far side of the world from where you left is the kind of
//  thing a chartplotter must not do.

import XCTest
@testable import LookoutMarine

final class ViewStateTests: ShellTestCase {

    func testNothingSavedIsNoPose() {
        XCTAssertNil(ViewState.load())
    }

    func testAPoseRoundTrips() throws {
        ViewState.save(lookout_view(lon: -76.482, lat: 38.9763, zoom: 14.5, rotation_deg: 37))
        let v = try XCTUnwrap(ViewState.load())
        XCTAssertEqual(v.lon, -76.482, accuracy: 1e-12)
        XCTAssertEqual(v.lat, 38.9763, accuracy: 1e-12)
        XCTAssertEqual(v.zoom, 14.5, accuracy: 1e-12)
        XCTAssertEqual(v.rotation_deg, 37, accuracy: 1e-12)
    }

    /// A pose saved before rotation existed still opens, north up.
    func testAPoseWithNoRotationOpensNorthUp() throws {
        Store.shared.set(["lon": -76.0, "lat": 38.0, "zoom": 12.0], "chart.view")
        let v = try XCTUnwrap(ViewState.load())
        XCTAssertEqual(v.rotation_deg, 0)
    }

    /// Half a pose is no pose: the opening view then comes from the core, which
    /// is the same policy every host gets.
    func testAHalfPoseIsNoPose() {
        Store.shared.set(["lon": -76.0, "lat": 38.0], "chart.view")
        XCTAssertNil(ViewState.load())
        Store.shared.set(["zoom": 12.0], "chart.view")
        XCTAssertNil(ViewState.load())
    }

    func testSomethingElseUnderTheKeyIsNoPose() {
        Store.shared.set("not a pose", "chart.view")
        XCTAssertNil(ViewState.load())
    }
}
