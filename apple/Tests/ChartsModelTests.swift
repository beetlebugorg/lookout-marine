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
        XCTAssertTrue(m.nothingToDraw)
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
        XCTAssertFalse(m.nothingToDraw)
        XCTAssertTrue(m.showStartupLoader)
    }

    /// A set holding a chart is not an empty library.
    func testASetHoldingAChartIsNeverAnEmptyLibrary() {
        let cell = ScannedCell(path: "/charts/a/US5MD1MC.pmtiles", name: "US5MD1MC",
                               kind: .baked, band: 5, bytes: 1)
        let m = model()
        m.sets = [ChartSet(path: "/charts/a", producer: nil, preparedPath: nil,
                           cells: [cell], rasters: [], on: true)]
        XCTAssertFalse(m.nothingToDraw)
    }

    /// An import runs for minutes over a big folder, and the first-run page is
    /// not drawn over it.
    func testABakeIsNeverAnEmptyLibrary() {
        let m = model()
        m.bake = BakeProgress(done: 3, total: 60, name: "All_ENCs.zip")
        XCTAssertFalse(m.nothingToDraw)
    }

    /// An open on its way is not an empty library either. A request raised
    /// before the chart view had a size stays in that state until the view
    /// services it.
    func testAPendingOpenIsNeverAnEmptyLibrary() {
        let m = model()
        m.openRequest = OpenRequest(id: 1, paths: ["/charts/a/US5MD1MC.pmtiles"])
        XCTAssertFalse(m.nothingToDraw)
    }

    /// A set that has been read and holds no drawable chart ends the loader.
    /// The first-run page appears instead.
    func testASetHoldingNothingToDrawEndsTheLoader() {
        let m = model()
        m.sets = [ChartSet(path: "/charts/a", producer: nil, preparedPath: nil,
                           cells: [], rasters: [], on: true)]
        XCTAssertTrue(m.nothingToDraw)
        XCTAssertFalse(m.showStartupLoader)
    }

    /// A set that holds a chart keeps the loader up while the open runs.
    func testASetHoldingAChartKeepsTheLoader() {
        let m = model()
        let cell = ScannedCell(path: "/charts/a/US5MD1MC.pmtiles", name: "US5MD1MC",
                               kind: .baked, band: 5, bytes: 1)
        m.sets = [ChartSet(path: "/charts/a", producer: nil, preparedPath: nil,
                           cells: [cell], rasters: [], on: true)]
        XCTAssertFalse(m.nothingToDraw)
        XCTAssertTrue(m.showStartupLoader)
    }

    /// A set switched off leaves the app with no chart to draw.
    func testASetSwitchedOffIsNothingToDraw() {
        let m = model()
        let cell = ScannedCell(path: "/charts/a/US5MD1MC.pmtiles", name: "US5MD1MC",
                               kind: .baked, band: 5, bytes: 1)
        m.sets = [ChartSet(path: "/charts/a", producer: nil, preparedPath: nil,
                           cells: [cell], rasters: [], on: false)]
        XCTAssertTrue(m.nothingToDraw)
        XCTAssertFalse(m.showStartupLoader)
    }

    /// A scan running means the folder's contents are not established yet.
    func testAScanRunningIsNeverNothingToDraw() {
        let m = model()
        m.scanning = true
        XCTAssertFalse(m.nothingToDraw)
    }

    /// The loader fills the gap before the first chart, and a drawing chart
    /// ends it.
    func testADrawingChartHasNoLoader() {
        let m = model()
        m.hasChart = true
        m.firstBuildDone = true
        XCTAssertFalse(m.showStartupLoader)
        XCTAssertFalse(m.nothingToDraw)
    }
}

/// Resuming a bake that a previous run left unfinished.
@MainActor
final class ResumeUnpreparedTests: ShellTestCase {

    private func set(managed: Bool, raw: Bool) -> ChartSet {
        let kind: ScannedCell.Kind = raw ? .source : .baked
        let ext = raw ? "000" : "pmtiles"
        return ChartSet(path: "/charts/NOAA",
                        producer: "US",
                        preparedPath: nil,
                        cells: [ScannedCell(path: "/charts/NOAA/US5MA1BO.\(ext)",
                                            name: "US5MA1BO",
                                            kind: kind,
                                            band: 5,
                                            bytes: 1)],
                        rasters: [],
                        on: true,
                        managed: managed)
    }

    func testTheManagedSetWithRawCellsResumes() {
        let charts = ChartsModel(raster: RasterModel())
        charts.sets = [set(managed: true, raw: true)]
        XCTAssertEqual(charts.unpreparedSetToResume?.path, "/charts/NOAA")
    }

    func testAFolderTheMarinerAddedDoesNotResume() {
        let charts = ChartsModel(raster: RasterModel())
        charts.sets = [set(managed: false, raw: true)]
        XCTAssertNil(charts.unpreparedSetToResume)
    }

    func testAPreparedSetDoesNotResume() {
        let charts = ChartsModel(raster: RasterModel())
        charts.sets = [set(managed: true, raw: false)]
        XCTAssertNil(charts.unpreparedSetToResume)
    }

    func testTheResumeWaitsForTheScan() {
        let charts = ChartsModel(raster: RasterModel())
        charts.sets = [set(managed: true, raw: true)]
        charts.scanning = true
        XCTAssertNil(charts.unpreparedSetToResume)
    }
}
