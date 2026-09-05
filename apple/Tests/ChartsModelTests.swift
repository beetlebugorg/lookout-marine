//  ChartsModelTests.swift — the state the first-run page is drawn from.
//
//  The first-run page is drawn from one test: has the app established that
//  there is nothing to draw. Reading `hasChart` alone told a mariner with a
//  full library that they had no charts, for as long as it took to read the
//  folders, and until they picked the folder again when the open that followed
//  a scan or an import went unserviced.

import XCTest
@testable import LookoutMarine

@MainActor
final class ChartsModelTests: ShellTestCase {

    private var engine = FakeEngine()

    private func model() -> ChartsModel {
        engine = FakeEngine()
        let m = ChartsModel(raster: RasterModel())
        m.engine = engine
        return m
    }

    /// Nothing installed and nothing running is the only empty library.
    func testNothingInstalledIsAnEmptyLibrary() {
        let m = model()
        XCTAssertTrue(m.libraryIsEmpty)
        XCTAssertFalse(m.showStartupLoader)
    }

    /// A scan is running, so what the installed sets hold is not established
    /// yet. The loader is drawn for that second, in place of the first-run
    /// page.
    ///
    /// The state is set here rather than driven through `loadChartSets`, which
    /// starts a scan on a worker. `pullChartSets` reads `scanning` back off the
    /// rows, so a scan that finishes first clears the flag before the assertion
    /// runs.
    func testAScanRunningIsNeverAnEmptyLibrary() {
        let m = model()
        m.scanning = true
        XCTAssertFalse(m.libraryIsEmpty)
        XCTAssertTrue(m.showStartupLoader)
    }

    /// A set on the list is not an empty library either.
    func testAListedSetIsNeverAnEmptyLibrary() {
        let m = model()
        m.sets = [ChartSet(path: "/charts/a", producer: nil, preparedPath: nil,
                           cells: [], rasters: [], on: true)]
        XCTAssertFalse(m.libraryIsEmpty)
    }

    /// An import runs for minutes over a big folder, and the first-run page is
    /// not drawn over it.
    func testABakeIsNeverAnEmptyLibrary() {
        let m = model()
        m.bake = BakeProgress(done: 3, total: 60, name: "All_ENCs.zip")
        XCTAssertFalse(m.libraryIsEmpty)
    }

    /// An open on its way is not an empty library either. A request raised
    /// before the chart view had a size stays in that state until the view
    /// services it.
    func testAPendingOpenIsNeverAnEmptyLibrary() {
        let m = model()
        m.openRequest = OpenRequest(id: 1, paths: ["/charts/a/US5MD1MC.pmtiles"])
        XCTAssertFalse(m.libraryIsEmpty)
    }

    /// The loader fills the gap before the first chart, and a drawing chart
    /// ends it.
    func testADrawingChartHasNoLoader() {
        let m = model()
        m.hasChart = true
        m.firstBuildDone = true
        XCTAssertFalse(m.showStartupLoader)
        XCTAssertFalse(m.libraryIsEmpty)
    }
}
