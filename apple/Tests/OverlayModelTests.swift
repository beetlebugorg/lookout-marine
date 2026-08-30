//  OverlayModelTests.swift — what floats over the chart.
//
//  One at a time is the rule the mariner sees: raising any of these puts the
//  others away. The other thing worth checking is the lift, which moves the
//  chart under the mariner and has to put it back exactly.

import XCTest
@testable import LookoutMarine

@MainActor
final class OverlayModelTests: ShellTestCase {
    private var engine = FakeEngine()

    private func model() -> OverlayModel {
        engine = FakeEngine()
        let m = OverlayModel()
        m.engine = engine
        return m
    }

    private func feature(_ cls: String) -> PickFeature {
        PickFeature(cls: cls, chart: "US5MD1MC", s57: "{}")
    }

    private func mark(_ id: UInt64, _ name: String = "Anchorage") -> ChartMarker {
        ChartMarker(id: id, lon: -76, lat: 39, name: name, droppedAt: Date())
    }

    private func hover(_ title: String = "Tug") -> OverlayHover {
        OverlayHover(json: Data(#"{"title":"\#(title)","rows":[]}"#.utf8))!
    }

    private func pin() -> OverlayPin {
        OverlayPin(id: "ais:1", info: hover(), lon: -76, lat: 39)
    }

    // MARK: The pick report

    func testAPickShowsWhatCameBack() {
        let m = model()
        m.showPick([feature("LIGHTS"), feature("DEPARE")], at: CGPoint(x: 10, y: 20))
        XCTAssertEqual(m.pickResults.count, 2)
        XCTAssertEqual(m.pickIndex, 0)
        XCTAssertEqual(m.pickPoint, CGPoint(x: 10, y: 20))
        XCTAssertEqual(m.pickAnchor, CGPoint(x: 10, y: 20))
    }

    /// A tap on bare water is how a mariner dismisses the report.
    func testAnEmptyPickClosesTheReport() {
        let m = model()
        m.showPick([feature("LIGHTS")], at: CGPoint(x: 10, y: 20))
        m.showPick([], at: CGPoint(x: 30, y: 40))
        XCTAssertNil(m.pickPoint)
        XCTAssertNil(m.pickGeo)
    }

    /// The mark belongs to the object, not the screen, so where it was taken
    /// on the chart is kept and re-projected.
    func testThePickRemembersWhereItWasOnTheChart() {
        let m = model()
        engine.geoAt = (lon: -76.5, lat: 38.9)
        m.showPick([feature("LIGHTS")], at: CGPoint(x: 10, y: 20))
        XCTAssertEqual(m.pickGeo?.lon, -76.5)
        XCTAssertEqual(m.pickGeo?.lat, 38.9)
    }

    /// A wide view uses a callout, which stands over its object and hides
    /// nothing, so the chart does not move.
    func testAWideViewDoesNotLiftTheChart() {
        let m = model()
        m.chromeSize = CGSize(width: 1400, height: 900)
        m.showPick([feature("LIGHTS")], at: CGPoint(x: 700, y: 850))
        XCTAssertEqual(m.pickLift, 0)
        XCTAssertTrue(engine.panned.isEmpty)
    }

    /// A phone uses a bottom sheet, and an object low in the view falls under
    /// it. The chart rises until the mark clears the sheet, and the mark rises
    /// with it.
    func testAnObjectUnderTheSheetLiftsTheChart() {
        let m = model()
        m.chromeSize = CGSize(width: 390, height: 844)
        m.showPick([feature("LIGHTS")], at: CGPoint(x: 195, y: 800))
        XCTAssertGreaterThan(m.pickLift, 0)
        XCTAssertEqual(m.pickPoint?.y, 800 - m.pickLift)
        XCTAssertEqual(engine.panned, [-m.pickLift])
    }

    /// An object already clear of the sheet does not move the chart.
    func testAnObjectAboveTheSheetDoesNotLift() {
        let m = model()
        m.chromeSize = CGSize(width: 390, height: 844)
        m.showPick([feature("LIGHTS")], at: CGPoint(x: 195, y: 60))
        XCTAssertEqual(m.pickLift, 0)
        XCTAssertTrue(engine.panned.isEmpty)
    }

    /// Closing puts the chart back by exactly what the app moved it, and
    /// nothing more: the mariner's own panning is theirs.
    func testClosingPutsTheChartBackByTheSameAmount() {
        let m = model()
        m.chromeSize = CGSize(width: 390, height: 844)
        m.showPick([feature("LIGHTS")], at: CGPoint(x: 195, y: 800))
        let lift = m.pickLift
        m.closePick()
        XCTAssertEqual(engine.panned, [-lift, lift])
        XCTAssertEqual(m.pickLift, 0)
        XCTAssertTrue(m.pickResults.isEmpty)
        XCTAssertNil(m.pickAnchor)
    }

    /// Closing a report that never lifted moves nothing.
    func testClosingAnUnliftedReportMovesNothing() {
        let m = model()
        m.showPick([feature("LIGHTS")], at: CGPoint(x: 10, y: 20))
        m.closePick()
        XCTAssertTrue(engine.panned.isEmpty)
    }

    // MARK: One at a time

    /// The menu puts away the bubble and the rename field.
    func testTheMenuPutsTheOthersAway() {
        let m = model()
        m.pin(pin())
        m.beginRename(mark(1))
        m.openChartMenu(at: CGPoint(x: 10, y: 20))
        XCTAssertNotNil(m.chartMenu)
        XCTAssertNil(m.pinned)
        XCTAssertNil(m.renaming)
        XCTAssertEqual(m.renamingText, "")
    }

    /// A bubble and a hover tooltip never share the screen.
    func testPinningClearsTheHover() {
        let m = model()
        m.hover = hover()
        m.hoverPoint = CGPoint(x: 5, y: 5)
        m.pin(pin())
        XCTAssertNil(m.hover)
        XCTAssertNil(m.hoverPoint)
        XCTAssertNotNil(m.pinned)
    }

    /// The menu acts on the point it was raised at, not on wherever the cursor
    /// has drifted to since.
    func testTheMenuActsOnItsOwnPoint() {
        let m = model()
        engine.geoAt = (lon: -76.4, lat: 38.8)
        m.openChartMenu(at: CGPoint(x: 10, y: 20))
        engine.geoAt = (lon: 0, lat: 0)     // the cursor moved
        engine.features = [feature("LIGHTS")]
        m.chartMenuPick()
        XCTAssertNil(m.chartMenu)
        XCTAssertEqual(m.pickPoint, CGPoint(x: 10, y: 20))
    }

    func testDroppingAMarkClosesTheMenu() {
        let m = model()
        m.openChartMenu(at: CGPoint(x: 10, y: 20))
        m.chartMenuDropMarker()
        XCTAssertNil(m.chartMenu)
        XCTAssertTrue(engine.calls.contains("dropMarker"))
    }

    func testRemovingAMarkClosesTheMenu() {
        let m = model()
        engine.markerAt = mark(7)
        m.openChartMenu(at: CGPoint(x: 10, y: 20))
        m.chartMenuRemoveMarker()
        XCTAssertNil(m.chartMenu)
        XCTAssertEqual(engine.removed, [7])
    }

    // MARK: Renaming a mark

    func testRenamingStartsWithTheCurrentName() {
        let m = model()
        m.beginRename(mark(7, "Anchorage"))
        XCTAssertEqual(m.renaming?.id, 7)
        XCTAssertEqual(m.renamingText, "Anchorage")
    }

    func testReturnCommits() {
        let m = model()
        m.beginRename(mark(7, "Anchorage"))
        m.renamingText = "Fish trap"
        m.commitRename()
        XCTAssertEqual(engine.renamed.map(\.1), ["Fish trap"])
        XCTAssertNil(m.renaming)
    }

    /// An empty field keeps the old name, which the core decides, so every
    /// shell agrees on what an emptied field means. The empty string still
    /// goes down: this shell does not answer it here.
    func testAnEmptyFieldStillGoesToTheCore() {
        let m = model()
        m.beginRename(mark(7, "Anchorage"))
        m.renamingText = ""
        m.commitRename()
        XCTAssertEqual(engine.renamed.map(\.1), [""])
    }

    func testEscapeAbandons() {
        let m = model()
        m.beginRename(mark(7, "Anchorage"))
        m.cancelRename()
        XCTAssertTrue(engine.renamed.isEmpty)
        XCTAssertNil(m.renaming)
        XCTAssertEqual(m.renamingText, "")
    }

    // MARK: Reveal

    /// A row a plugin table named, with nothing drawn there, takes the bubble
    /// down rather than leaving the last one up.
    func testRevealingNothingClosesTheBubble() {
        let m = model()
        m.pin(pin())
        engine.revealPin = nil
        m.revealOnChart(lon: -76, lat: 39)
        XCTAssertNil(m.pinned)
    }

    func testRevealingPinsWhatIsThere() {
        let m = model()
        engine.revealPin = pin()
        m.revealOnChart(lon: -76, lat: 39)
        XCTAssertEqual(m.pinned?.id, "ais:1")
    }

    // MARK: The screenshot protocol's hooks

    /// A fraction of the view, with no pointer to press with.
    func testAFractionalPickLandsWhereItWasAsked() {
        let m = model()
        m.pickCentreHint = CGPoint(x: 200, y: 400)
        engine.features = [feature("LIGHTS")]
        m.pickAt(fx: 0.5, fy: 0.85)
        XCTAssertEqual(m.pickPoint, CGPoint(x: 200, y: 680))
    }

    /// Nothing has sized the view yet, so there is nowhere to press.
    func testAHookWithNoViewYetDoesNothing() {
        let m = model()
        m.pickCentreHint = nil
        engine.features = [feature("LIGHTS")]
        m.pickAt(fx: 0.5, fy: 0.5)
        XCTAssertTrue(m.pickResults.isEmpty)
    }

    func testRenamingTheNewestMarkTakesTheLastOne() {
        let m = model()
        engine.markerList = [mark(1, "First"), mark(2, "Newest")]
        m.showRenameNewestMarker()
        XCTAssertEqual(m.renamingText, "Newest")
    }
}
