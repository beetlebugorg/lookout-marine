//  PlacementTests.swift — where the chrome stands.
//
//  All of this is arithmetic on a point and a view size. It decides which body
//  the pick report takes, where a callout sits and which way a panel flips at
//  an edge, and none of it needs a chart or a view to run.

import XCTest
import SwiftUI
@testable import LookoutMarine

final class PickFormTests: XCTestCase {

    /// Below 700 wide the capsule and the corner chrome cannot share the bottom
    /// row. Below 520 tall there is no room for a callout over a chart.
    func testWhichBodyEachViewSizeAsksFor() {
        XCTAssertEqual(OverlayLayer.pickForm(for: CGSize(width: 1280, height: 800)), .callout)
        XCTAssertEqual(OverlayLayer.pickForm(for: CGSize(width: 700, height: 520)), .callout)
        XCTAssertEqual(OverlayLayer.pickForm(for: CGSize(width: 699, height: 800)), .bottomSheet)
        XCTAssertEqual(OverlayLayer.pickForm(for: CGSize(width: 402, height: 874)), .bottomSheet)
        XCTAssertEqual(OverlayLayer.pickForm(for: CGSize(width: 874, height: 402)), .sideSheet)
    }

    /// A narrow AND short view is a phone on its side held narrow. Width wins:
    /// a sheet against the bottom leaves the chart the wider part.
    func testWidthDecidesBeforeHeight() {
        XCTAssertEqual(OverlayLayer.pickForm(for: CGSize(width: 500, height: 400)), .bottomSheet)
    }

    /// The chart keeps the larger part of the view.
    func testTheBottomSheetNeverTakesHalfTheView() {
        let tall = OverlayLayer.bottomSheetSize(in: CGSize(width: 402, height: 874))
        XCTAssertEqual(tall.width, 402)
        XCTAssertEqual(tall.height, 340)
        let short = OverlayLayer.bottomSheetSize(in: CGSize(width: 402, height: 600))
        XCTAssertEqual(short.height, 288)
        XCTAssertLessThan(short.height, 300)
    }
}

final class CalloutLayoutTests: XCTestCase {
    private let view = CGSize(width: 1280, height: 800)

    /// The card stands over the mark, its floor clear of it, with the room
    /// between the mark and the margin to grow into.
    func testTheCardStandsOverTheMarkWhenThereIsRoom() {
        let p = OverlayLayer.calloutLayout(point: CGPoint(x: 640, y: 500),
                                           width: 420, in: view)
        XCTAssertEqual(p.edge, .above)
        XCTAssertEqual(p.y, 477)
        XCTAssertEqual(p.room, 461)
        XCTAssertEqual(p.x, 430)
    }

    /// Under the mark when the room above is too small to read a report in.
    func testTheCardGoesUnderTheMarkWhenTheRoomAboveIsSmall() {
        let p = OverlayLayer.calloutLayout(point: CGPoint(x: 640, y: 100),
                                           width: 420, in: view)
        XCTAssertEqual(p.edge, .below)
        XCTAssertEqual(p.y, 123)
        XCTAssertEqual(p.room, 601)
    }

    /// 200pt above is enough, even when there is more below.
    func testTwoHundredPointsAboveIsEnough() {
        let p = OverlayLayer.calloutLayout(point: CGPoint(x: 640, y: 239),
                                           width: 420, in: view)
        XCTAssertEqual(p.edge, .above)
        XCTAssertEqual(p.room, 200)
    }

    func testTheCardIsClampedToBothMargins() {
        XCTAssertEqual(OverlayLayer.calloutLayout(point: CGPoint(x: 20, y: 500),
                                                  width: 420, in: view).x, 16)
        XCTAssertEqual(OverlayLayer.calloutLayout(point: CGPoint(x: 1270, y: 500),
                                                  width: 420, in: view).x, 844)
    }

    /// A card wider than the view still starts at the margin rather than off
    /// the leading edge.
    func testACardWiderThanTheViewStartsAtTheMargin() {
        let p = OverlayLayer.calloutLayout(point: CGPoint(x: 200, y: 300),
                                           width: 420, in: CGSize(width: 400, height: 800))
        XCTAssertEqual(p.x, 16)
    }

    /// The HUD owns the bottom band, so the card's floor stops above it.
    func testTheCardStopsClearOfTheHudBand() {
        let p = OverlayLayer.calloutLayout(point: CGPoint(x: 640, y: 60),
                                           width: 420, in: view)
        XCTAssertEqual(p.edge, .below)
        // 800 - (16 * 2 + 44) = 724, less the mark's clearance.
        XCTAssertEqual(p.room, 641)
    }

    /// A pick taken low on the view — on the capsule's own row, which a
    /// mariner reaching for a buoy near the bottom edge does — stands the card
    /// off the mark rather than putting its last line over the readouts.
    func testAPickOnTheHudBandStandsTheCardOffTheMark() {
        let p = OverlayLayer.calloutLayout(point: CGPoint(x: 640, y: 780),
                                           width: 420, in: view)
        XCTAssertEqual(p.edge, .above)
        // 800 - (16 * 2 + 44) = 724, and the mark is below that.
        XCTAssertEqual(p.y, 724)
        XCTAssertEqual(p.room, 708)
    }

    /// A pick clear of the band still holds its floor against the mark.
    func testAPickAboveTheBandHoldsItsFloorAgainstTheMark() {
        let p = OverlayLayer.calloutLayout(point: CGPoint(x: 640, y: 600),
                                           width: 420, in: view)
        XCTAssertEqual(p.edge, .above)
        XCTAssertEqual(p.y, 577)
    }

    /// Room is never negative, whatever the point.
    func testTheRoomIsNeverNegative() {
        for y in stride(from: -100.0, through: 900.0, by: 25) {
            let p = OverlayLayer.calloutLayout(point: CGPoint(x: 640, y: y),
                                               width: 420, in: view)
            XCTAssertGreaterThanOrEqual(p.room, 0, "y=\(y)")
        }
    }
}

final class CalloutWidthTests: XCTestCase {

    /// The detail column alone for one object, with the list beside it for
    /// several.
    func testOneObjectAndSeveral() {
        XCTAssertEqual(PickCallout.width(for: 1, in: 1280), 420)
        XCTAssertEqual(PickCallout.width(for: 0, in: 1280), 420)
        XCTAssertEqual(PickCallout.width(for: 3, in: 1280), 631)
    }

    /// It never runs past the margins.
    func testTheCardFitsTheView() {
        XCTAssertEqual(PickCallout.width(for: 3, in: 500), 468)
        XCTAssertEqual(PickCallout.width(for: 1, in: 500), 420)
    }

    /// Below 280 there is nothing left to read a report in, so the card keeps
    /// that much and takes the margin instead.
    func testTheCardHasAFloor() {
        XCTAssertEqual(PickCallout.width(for: 1, in: 300), 280)
        XCTAssertEqual(PickCallout.width(for: 3, in: 100), 280)
    }
}

final class HoverAndMenuLayoutTests: XCTestCase {
    private let view = CGSize(width: 1280, height: 800)

    /// The tip sits below and right of the pointer.
    func testTheTipSitsBelowAndRightOfThePointer() {
        let p = OverlayLayer.hoverLayout(point: CGPoint(x: 100, y: 100), in: view)
        XCTAssertEqual(p.alignment, Alignment(horizontal: .leading, vertical: .top))
        XCTAssertEqual(p.leading, 114)
        XCTAssertEqual(p.top, 114)
        XCTAssertEqual(p.trailing, 0)
        XCTAssertEqual(p.bottom, 0)
    }

    /// It flips at whichever edge it would cross, one axis at a time.
    func testTheTipFlipsAtEachEdge() {
        let bottomRight = OverlayLayer.hoverLayout(point: CGPoint(x: 1200, y: 700), in: view)
        XCTAssertEqual(bottomRight.alignment,
                       Alignment(horizontal: .trailing, vertical: .bottom))
        XCTAssertEqual(bottomRight.trailing, 94)
        XCTAssertEqual(bottomRight.bottom, 114)

        let rightOnly = OverlayLayer.hoverLayout(point: CGPoint(x: 1200, y: 100), in: view)
        XCTAssertEqual(rightOnly.alignment,
                       Alignment(horizontal: .trailing, vertical: .top))

        let bottomOnly = OverlayLayer.hoverLayout(point: CGPoint(x: 100, y: 700), in: view)
        XCTAssertEqual(bottomOnly.alignment,
                       Alignment(horizontal: .leading, vertical: .bottom))
    }

    /// The menu opens tight against the press, and flips the same way.
    func testTheMenuOpensAtThePress() {
        let p = OverlayLayer.menuLayout(point: CGPoint(x: 100, y: 100), in: view,
                                        hasMarker: false)
        XCTAssertEqual(p.alignment, Alignment(horizontal: .leading, vertical: .top))
        XCTAssertEqual(p.leading, 102)
        XCTAssertEqual(p.top, 102)
    }

    /// A menu over a marker is taller, so it flips sooner.
    func testAMenuOverAMarkerFlipsSooner() {
        // 162pt tall without a marker, 220 with: a press at y=620 clears one
        // and not the other.
        let plain = OverlayLayer.menuLayout(point: CGPoint(x: 100, y: 620), in: view,
                                            hasMarker: false)
        let marker = OverlayLayer.menuLayout(point: CGPoint(x: 100, y: 620), in: view,
                                             hasMarker: true)
        XCTAssertEqual(plain.alignment.vertical, .top)
        XCTAssertEqual(marker.alignment.vertical, .bottom)
    }

    /// An offset is never negative, so nothing is pushed off the leading edge.
    func testNoOffsetIsNegative() {
        for x in stride(from: 0.0, through: 1280.0, by: 40) {
            for y in stride(from: 0.0, through: 800.0, by: 40) {
                let p = OverlayLayer.hoverLayout(point: CGPoint(x: x, y: y), in: view)
                XCTAssertGreaterThanOrEqual(min(p.leading, p.trailing, p.top, p.bottom), 0)
            }
        }
    }
}

final class ScaleBarTests: XCTestCase {

    /// The label is always a round distance, and the bar is 140pt or less.
    func testTheBarIsARoundDistanceUnder140Points() {
        for denominator in [500.0, 2_000, 13_267, 50_000, 250_000, 2_000_000] {
            guard let bar = ScaleBarView.bar(for: denominator) else {
                return XCTFail("no bar at 1:\(denominator)")
            }
            XCTAssertLessThanOrEqual(bar.width, 140, "1:\(denominator) drew \(bar.width)pt")
            XCTAssertGreaterThan(bar.width, 0)
            XCTAssertTrue(bar.label.hasSuffix(" m") || bar.label.hasSuffix(" km"), bar.label)
        }
    }

    /// Metres up close, whole kilometres beyond.
    func testTheUnitFollowsTheDistance() {
        XCTAssertEqual(ScaleBarView.bar(for: 2_000)?.label, "50 m")
        XCTAssertEqual(ScaleBarView.bar(for: 13_267)?.label, "500 m")
        XCTAssertEqual(ScaleBarView.bar(for: 50_000)?.label, "1 km")
        XCTAssertEqual(ScaleBarView.bar(for: 2_000_000)?.label, "50 km")
    }

    /// Zoomed in past the smallest round number, the bar keeps the smallest
    /// rather than vanishing.
    func testTheSmallestDistanceIsTheFloor() {
        XCTAssertEqual(ScaleBarView.bar(for: 1)?.label, "10 m")
    }

    func testNoScaleIsNoBar() {
        XCTAssertNil(ScaleBarView.bar(for: 0))
        XCTAssertNil(ScaleBarView.bar(for: -1))
    }
}
