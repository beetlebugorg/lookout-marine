//  ReadoutsModelTests.swift — what the chart reports every frame.
//
//  All of it is read from the core, never remembered from a gesture. The one
//  that matters is own ship: a readout holding the last numbers through a lost
//  fix is presenting a stale position as live.

import XCTest
@testable import LookoutMarine

@MainActor
final class ReadoutsModelTests: ShellTestCase {
    private var engine = FakeEngine()

    private func model() -> ReadoutsModel {
        engine = FakeEngine()
        let m = ReadoutsModel()
        m.engine = engine
        return m
    }

    func testTheFrameValuesAreRead() {
        let m = model()
        engine.view = lookout_view(lon: -76.4, lat: 38.9, zoom: 13.5, rotation_deg: 22)
        engine.scale = 12_000
        engine.overscaleValue = 2.5
        engine.scheme = 2
        m.pull()
        XCTAssertEqual(m.centerLon, -76.4)
        XCTAssertEqual(m.centerLat, 38.9)
        XCTAssertEqual(m.zoomLevel, 13.5)
        XCTAssertEqual(m.rotationDeg, 22)
        XCTAssertEqual(m.scaleDenominator, 12_000)
        XCTAssertEqual(m.overscale, 2.5)
        XCTAssertEqual(m.schemeName, "Night")
    }

    /// The core turns follow off itself on a pan, so the lock button follows
    /// the core and not its own last tap.
    func testFollowComesFromTheCore() {
        let m = model()
        engine.follow = 1
        m.pull()
        XCTAssertEqual(m.orientation, .northUp)
        engine.follow = 0                     // the mariner panned
        m.pull()
        XCTAssertEqual(m.orientation, .unlocked)
    }

    func testFollowWithNoFixIsArmed() {
        let m = model()
        engine.follow = 2
        m.pull()
        XCTAssertEqual(m.orientation, .armed)
    }

    func testCourseUpIsReadTogetherWithFollow() {
        let m = model()
        engine.follow = 1
        engine.courseUp = 1
        m.pull()
        XCTAssertEqual(m.orientation, .courseUp)
    }

    func testALiveFixCarriesThePosition() {
        let m = model()
        engine.ship = (state: .live, lat: 38.978, lon: -76.492)
        m.pull()
        XCTAssertEqual(m.fixState, .live)
        XCTAssertEqual(m.shipLat, 38.978)
        XCTAssertEqual(m.shipLon, -76.492)
    }

    /// A lost fix takes the numbers with it. Holding them would present a
    /// stale position as live.
    func testALostFixDropsThePosition() {
        let m = model()
        engine.ship = (state: .live, lat: 38.978, lon: -76.492)
        m.pull()
        engine.ship = (state: .lost, lat: 38.978, lon: -76.492)
        m.pull()
        XCTAssertEqual(m.fixState, .lost)
        XCTAssertNil(m.shipLat)
        XCTAssertNil(m.shipLon)
    }

    /// Nothing ever published one, and the readout never falls back to the map
    /// centre or the cursor.
    func testNoFixCarriesNoPosition() {
        let m = model()
        engine.ship = (state: .none, lat: 0, lon: 0)
        m.pull()
        XCTAssertEqual(m.fixState, .none)
        XCTAssertNil(m.shipLat)
    }

    /// The core said nothing at all. What was there stays: this is one
    /// unanswered read, not a lost fix.
    func testAnUnansweredReadLeavesTheFixAlone() {
        let m = model()
        engine.ship = (state: .live, lat: 38.978, lon: -76.492)
        m.pull()
        engine.ship = nil
        m.pull()
        XCTAssertEqual(m.fixState, .live)
        XCTAssertEqual(m.shipLat, 38.978)
    }

    /// Own ship comes from a plugin, so the follow control is only offered
    /// when one can supply a position.
    func testThePluginLayerIsRead() {
        let m = model()
        engine.pluginsAreActive = true
        m.pull()
        XCTAssertTrue(m.pluginsActive)
    }

    func testNoChartLeavesTheReadoutsWhereTheyWere() {
        let m = ReadoutsModel()
        m.scaleDenominator = 25_000
        m.pull()
        XCTAssertEqual(m.scaleDenominator, 25_000)
    }
}
