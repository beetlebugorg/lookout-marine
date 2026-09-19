//  FirstRunReturnTests.swift — when setup comes back.
//
//  Setup runs on an empty library. Finishing it puts it away, and a mariner
//  who then removes every chart has an empty library again and the same
//  questions to answer. Set Up Later is a different answer and stands.

import XCTest
@testable import LookoutMarine

@MainActor
final class FirstRunReturnTests: ShellTestCase {

    private func models() -> (FirstRunModel, ChartsModel, ChartLinksModel) {
        (FirstRunModel(), ChartsModel(raster: RasterModel()), ChartLinksModel())
    }

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

    func testSetupRunsOnAnEmptyLibrary() {
        let (flow, charts, links) = models()
        XCTAssertTrue(flow.shouldRun(charts: charts, links: links))
    }

    /// The defect: finishing setup put it away for the run, so a mariner who
    /// removed every chart had an empty library and no route to the page that
    /// builds one. The library is noted where the app notes it, from the set
    /// list changing, and not by hand.
    func testSetupComesBackWhenTheLibraryGoesEmpty() {
        let app = AppModel()
        app.charts.sets = [drawableSet()]
        app.firstRun.finish()

        // Every chart removed.
        app.charts.sets = []
        app.considerFirstRun()

        XCTAssertTrue(app.firstRun.showing)
    }

    /// Set Up Later is "not now" from a mariner who never had charts. Setup
    /// holds for the run, or the page they dismissed comes straight back.
    func testSetUpLaterHoldsForTheRun() {
        let (flow, charts, links) = models()
        flow.noteLibrary(charts)
        flow.finish()

        XCTAssertFalse(flow.shouldRun(charts: charts, links: links))
    }

    /// The scan has not read the library for the first moment of a launch, so
    /// nothingToDraw is false then. Reading that as a library would put setup
    /// away on a device that has none.
    func testAnUnreadLibraryIsNotALibrary() {
        let (flow, charts, links) = models()
        charts.scanning = true
        flow.noteLibrary(charts)
        charts.scanning = false
        flow.finish()

        XCTAssertFalse(flow.shouldRun(charts: charts, links: links))
    }

    /// A linked chart is a chart, so setup stays down over one.
    func testALinkedChartKeepsSetupDown() {
        let (flow, charts, links) = models()
        links.active = "https://example.test/style.json"
        XCTAssertFalse(flow.shouldRun(charts: charts, links: links))
    }
}

/// The steps' own ways out.
@MainActor
final class FirstRunStepTests: ShellTestCase {

    /// A flow on the importing step with a NOAA order out.
    private func importing() -> FirstRunModel {
        let flow = FirstRunModel()
        flow.step = .importing
        flow.noaaOrder = .init(regions: "Chesapeake", charts: 12, bytes: 1_000)
        return flow
    }

    private func state(_ phase: NoaaState.Phase, done: UInt32 = 0, total: UInt32 = 12,
                       error: String = "") -> NoaaState {
        var s = NoaaState()
        s.phase = phase
        s.done = done
        s.total = total
        s.error = error
        return s
    }

    func testTheImportHoldsWhileChartsArrive() {
        let flow = importing()
        flow.noteImport(state(.downloading), bakeRunning: false)
        XCTAssertFalse(flow.importEnded)
        XCTAssertFalse(flow.canGoBack)
        flow.back()
        XCTAssertEqual(flow.step, .importing)
    }

    /// The defect: a download that ended with no cell landed never started a
    /// bake, and the step waited on one with no control left alive.
    func testAnOrderThatLandedNothingOffersTheWayBack() {
        let flow = importing()
        flow.noteImport(state(.ready, error: "no network provider"), bakeRunning: false)
        XCTAssertTrue(flow.importEnded)
        XCTAssertTrue(flow.canGoBack)

        flow.back()
        XCTAssertEqual(flow.step, .coverage)
        XCTAssertNil(flow.noaaOrder)
        XCTAssertFalse(flow.importEnded)
    }

    /// A transfer that landed a cell is about to bake, so the step waits.
    func testAnOrderThatLandedChartsWaitsForTheBake() {
        let flow = importing()
        flow.noteImport(state(.ready, done: 3), bakeRunning: false)
        XCTAssertFalse(flow.importEnded)
        flow.noteImport(state(.ready, done: 3), bakeRunning: true)
        XCTAssertFalse(flow.importEnded)
    }

    /// Once a bake has run the step finishes through Continue, not Back.
    func testASeenBakeIsNotAnEndedOrder() {
        let flow = importing()
        flow.sawBake = true
        flow.noteImport(state(.ready), bakeRunning: false)
        XCTAssertFalse(flow.importEnded)
    }

    /// Setup begun again forgets the last run's bake.
    func testBeginForgetsTheLastImport() {
        let flow = importing()
        flow.sawBake = true
        flow.begin()
        XCTAssertFalse(flow.sawBake)
        XCTAssertNil(flow.noaaOrder)
    }

    /// The defect: Continue on the online step with no card picked finished
    /// setup over the basemap and put it away for the run.
    func testTheOnlineStepNeedsAPickedChart() {
        let flow = FirstRunModel()
        let links = ChartLinksModel()
        flow.step = .onlineChart
        XCTAssertFalse(flow.canUseOnlineChart(links))
        XCTAssertEqual(flow.primaryTitle(flow.chosenChartName(links)), "Continue")

        links.list = [.init(url: "https://example.test/style.json", name: "Harbour")]
        links.active = "https://example.test/style.json"
        XCTAssertTrue(flow.canUseOnlineChart(links))
        XCTAssertEqual(flow.primaryTitle(flow.chosenChartName(links)), "Use Harbour")
    }
}
