//  ChartsModelTests.swift — what the app believes about the charts it holds.
//
//  The first-run page is drawn from one answer: does this app know there is
//  nothing to draw. Getting that answer from `hasChart` alone told a mariner
//  with a full library that they had no charts, for as long as it took to read
//  the folders, and for good when the open that followed a scan or an import
//  was never serviced.

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

    /// A set installed, the scan still reading it: the mariner HAS charts, and
    /// must not be told otherwise for the second that takes.
    func testASetInstalledIsNeverAnEmptyLibrary() {
        ChartSetStore.add("/charts/a")
        let m = model()
        m.loadChartSets()
        XCTAssertTrue(m.scanning, "the launch scan should be running")
        XCTAssertFalse(m.libraryIsEmpty)
        XCTAssertTrue(m.showStartupLoader, "something has to stand in the gap")
    }

    /// The import runs for minutes over a big folder. The page that says there
    /// are no charts is not what stands over it.
    func testABakeIsNeverAnEmptyLibrary() {
        let m = model()
        m.bake = BakeProgress(done: 3, total: 60, name: "All_ENCs.zip")
        XCTAssertFalse(m.libraryIsEmpty)
    }

    /// An open on its way is not an empty library either, and it is the state
    /// a request raised before the chart view had a size sits in.
    func testAPendingOpenIsNeverAnEmptyLibrary() {
        let m = model()
        m.openRequest = OpenRequest(id: 1, paths: ["/charts/a/US5MD1MC.pmtiles"])
        XCTAssertFalse(m.libraryIsEmpty)
    }

    /// And the loader comes down when the chart is up. The gap it fills is
    /// before the first chart, not after it.
    func testADrawingChartKeepsNoLoaderUp() {
        let m = model()
        m.hasChart = true
        m.firstBuildDone = true
        XCTAssertFalse(m.showStartupLoader)
        XCTAssertFalse(m.libraryIsEmpty)
    }
}
