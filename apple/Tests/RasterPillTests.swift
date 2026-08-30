//  RasterPillTests.swift — the pill must be right about which picture and in
//  what state.
//
//  With a picture chart on, the ENC drops its opaque water and land fills to
//  let it through. That is a real reduction in what the chart is telling the
//  mariner, and the pill is the only thing that says so.

import XCTest
@testable import LookoutMarine

final class RasterPillTests: XCTestCase {

    private func set(_ id: Int, _ name: String, inView: Bool = true,
                     shown: Bool = false) -> RasterSet {
        RasterSet(id: id, name: name, inView: inView, shown: shown)
    }

    /// No coverage, no pill. A control that is useless here is noise.
    func testNoCoverageIsNoPill() {
        let pill = RasterPill(inView: [], active: -1, chartHidden: false)
        XCTAssertFalse(pill.isShown)
        XCTAssertEqual(pill.name, "")
    }

    func testTheDrawnSetIsNamedAndReadsAsDrawn() {
        let pill = RasterPill(inView: [set(0, "ArcGIS"), set(1, "Navionics")],
                              active: 1, chartHidden: false)
        XCTAssertTrue(pill.isShown)
        XCTAssertEqual(pill.name, "Navionics")
        XCTAssertEqual(pill.state, .on)
        XCTAssertEqual(pill.stateName, "drawn")
    }

    /// The bug this type exists to make impossible: the pill named the first
    /// set in view and reported the state of whichever was drawn, so it read
    /// "NAVIONICS | OFF" while Navionics was drawn.
    func testTheNameAndTheStateAreTheSameSet() {
        let pill = RasterPill(inView: [set(0, "ArcGIS"), set(1, "Navionics")],
                              active: 1, chartHidden: false)
        XCTAssertEqual(pill.name, "Navionics")
        XCTAssertEqual(pill.state, .on)
        XCTAssertTrue(pill.help.hasPrefix("Navionics below the ENC."), pill.help)
    }

    /// Nothing drawn: the pill names the first set covering this water and says
    /// it is off, so a mariner can see what is here to switch on.
    func testWithNothingDrawnItNamesWhatIsHere() {
        let pill = RasterPill(inView: [set(0, "ArcGIS"), set(1, "Navionics")],
                              active: -1, chartHidden: false)
        XCTAssertEqual(pill.name, "ArcGIS")
        XCTAssertEqual(pill.state, .off)
        XCTAssertEqual(pill.stateName, "off")
    }

    /// A set drawn somewhere else does not name this water.
    func testASetOutOfViewIsNotNamed() {
        let pill = RasterPill(inView: [set(0, "ArcGIS")], active: 7, chartHidden: false)
        XCTAssertEqual(pill.name, "ArcGIS")
        XCTAssertEqual(pill.state, .off)
    }

    /// Hiding the ENC above the picture is a third state, and it is not off:
    /// the picture is then the only thing on screen.
    func testTheEncHiddenAboveIt() {
        let pill = RasterPill(inView: [set(0, "ArcGIS")], active: 0, chartHidden: true)
        XCTAssertEqual(pill.state, .chartOff)
        XCTAssertEqual(pill.stateName, "drawn, ENC hidden")
    }

    /// The colour reports the PICTURE, not the ENC. Hiding the ENC does not
    /// turn the pill amber, because the picture is still drawn.
    func testTheTintFollowsThePictureAndNotTheEnc() {
        let drawn = RasterPill(inView: [set(0, "ArcGIS")], active: 0, chartHidden: false)
        let encOff = RasterPill(inView: [set(0, "ArcGIS")], active: 0, chartHidden: true)
        let off = RasterPill(inView: [set(0, "ArcGIS")], active: -1, chartHidden: false)
        XCTAssertEqual(drawn.tint, encOff.tint)
        XCTAssertNotEqual(drawn.tint, off.tint)
    }

    /// Chart hidden with nothing drawn is still off. The ENC being hidden says
    /// nothing about a picture that is not there.
    func testTheEncHiddenWithNoPictureIsStillOff() {
        let pill = RasterPill(inView: [set(0, "ArcGIS")], active: -1, chartHidden: true)
        XCTAssertEqual(pill.state, .off)
    }

    /// Several sets over one coast: the help says how many, because the mariner
    /// is choosing between them.
    func testSeveralSetsAreCounted() {
        let one = RasterPill(inView: [set(0, "ArcGIS")], active: 0, chartHidden: false)
        XCTAssertFalse(one.help.contains("cover this view"), one.help)
        let two = RasterPill(inView: [set(0, "ArcGIS"), set(1, "Bing")],
                             active: 0, chartHidden: false)
        XCTAssertTrue(two.help.contains("2 raster charts cover this view"), two.help)
    }

    /// Every state names itself, so a test never has to read the help text.
    func testEveryStateHasItsOwnWord() {
        XCTAssertEqual(Set([
            RasterPill(inView: [set(0, "A")], active: 0, chartHidden: false).stateName,
            RasterPill(inView: [set(0, "A")], active: 0, chartHidden: true).stateName,
            RasterPill(inView: [set(0, "A")], active: -1, chartHidden: false).stateName,
        ]).count, 3)
    }
}
