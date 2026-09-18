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
    /// builds one.
    func testSetupComesBackWhenTheLibraryGoesEmpty() {
        let (flow, charts, links) = models()
        charts.sets = [drawableSet()]
        flow.noteLibrary(charts)
        flow.finish()

        // Every chart removed.
        charts.sets = []
        flow.noteLibrary(charts)

        XCTAssertTrue(flow.shouldRun(charts: charts, links: links))
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
