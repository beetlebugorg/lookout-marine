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

/// Resuming the downloader's prepare from the core's list.
@MainActor
final class ResumePrepareTests: ShellTestCase {

    /// Spin the main run loop until `done` holds, for the bake's poll and the
    /// core's scans.
    private func wait(_ what: String, file: StaticString = #filePath, line: UInt = #line,
                      until done: () -> Bool) {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if done() { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("timed out waiting for \(what)", file: file, line: line)
    }

    /// The downloader's set, holding raw cells copied from test/cells, as the
    /// core has read it. Twelve copies keep the bake running past a cancel.
    private func managedSetOfRawCells() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("test/cells/US5OR2XF.000")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: source.path),
                          "no repository beside the test bundle")
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-resume-" + UUID().uuidString)
        for i in 10..<22 {
            let cell = dir.appendingPathComponent("US5OR2\(i)/US5OR2\(i).000")
            try FileManager.default.createDirectory(at: cell.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: cell)
        }
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            if let prepared = ChartBake.preparedDirectory(for: dir.path) {
                try? FileManager.default.removeItem(atPath: prepared)
            }
        }
        XCTAssertTrue(ChartSetStore.add(dir.path))
        XCTAssertTrue(ChartSetStore.setManaged(dir.path, true))
        wait("the scan of the set") {
            ChartSetStore.all().first { $0.path == dir.path }?.scanned == true
        }
        return dir.path
    }

    /// A prepare the mariner stopped stays stopped. The bake's own rescan and
    /// every later pull of the sets leave it alone.
    func testAStoppedPrepareIsNotRestartedByTheNextPull() throws {
        let path = try managedSetOfRawCells()
        let charts = ChartsModel(raster: RasterModel())
        let engine = FakeEngine()
        charts.engine = engine

        charts.pullChartSets()
        XCTAssertNotNil(charts.bake, "the downloader's unprepared set resumes")

        charts.cancelBake()
        // The bake's end adopts the set, which rescans it. The test host's own
        // frame loop may take the core's changed flag, so the pull after the
        // rescan is made here.
        wait("the stopped bake to end and the set to be read again") {
            charts.bake == nil && !charts.scanRequested
                && ChartSetStore.all().first { $0.path == path }?.scanned == true
        }
        charts.pullChartSets()
        XCTAssertNil(charts.bake)
        XCTAssertNil(ChartSetStore.resume())
        // The cells are still to prepare and none is refused, so the stop is
        // what holds the set.
        let row = try XCTUnwrap(ChartSetStore.all().first { $0.path == path })
        XCTAssertGreaterThan(row.toPrepare, 0)
        XCTAssertEqual(row.refused, 0)
    }
}
