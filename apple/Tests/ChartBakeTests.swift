//  ChartBakeTests.swift — where prepared charts live, and what the panel says
//  about the work.

import XCTest
@testable import LookoutMarine

final class ChartBakeBoundaryTests: XCTestCase {

    /// The boundary matters beyond tidiness: what is under here was made from
    /// the mariner's cells and can be made again, so removing a set may delete
    /// it. What is outside is the mariner's own and is never touched.
    func testOnlyWhatThisAppPreparedIsDerived() throws {
        let root = try XCTUnwrap(ChartBake.chartsRoot)
        XCTAssertTrue(ChartBake.isDerived(root))
        XCTAssertTrue(ChartBake.isDerived(root + "/ENC_ROOT/US5MD1MC/US5MD1MC.pmtiles"))
        XCTAssertFalse(ChartBake.isDerived(NSHomeDirectory() + "/Charts/ENC_ROOT"))
        XCTAssertFalse(ChartBake.isDerived("/"))
        XCTAssertFalse(ChartBake.isDerived(""))
    }

    /// A sibling directory whose name only starts the same is not inside.
    func testANeighbourWithASimilarNameIsNotInside() throws {
        let root = try XCTUnwrap(ChartBake.chartsRoot)
        XCTAssertFalse(ChartBake.isDerived(root + "-old"))
    }

    /// One directory per source folder, named after it, under the app's own
    /// support directory. The source folder is never written to.
    func testWherePreparedChartsLive() throws {
        let root = try XCTUnwrap(ChartBake.chartsRoot)
        XCTAssertEqual(ChartBake.preparedDirectory(for: "/charts/ENC_ROOT"),
                       root + "/ENC_ROOT")
        XCTAssertTrue(ChartBake.isDerived(try XCTUnwrap(
            ChartBake.preparedDirectory(for: "/charts/ENC_ROOT"))))
    }

    /// An archive names its directory without the .zip: what comes out of
    /// All_ENCs.zip is charts, and "All_ENCs.zip/" reads like a mistake.
    func testAnArchiveLosesItsExtension() throws {
        let root = try XCTUnwrap(ChartBake.chartsRoot)
        XCTAssertEqual(ChartBake.preparedDirectory(for: "/d/All_ENCs.zip"),
                       root + "/All_ENCs")
    }

    /// Refuses any path it did not make, so removing a set can never delete a
    /// mariner's own folder.
    func testDeletingRefusesAnythingItDidNotMake() throws {
        let root = try XCTUnwrap(ChartBake.chartsRoot)
        XCTAssertFalse(ChartBake.deleteDerived(NSHomeDirectory() + "/Charts"))
        XCTAssertFalse(ChartBake.deleteDerived(root))
        XCTAssertFalse(ChartBake.deleteDerived("/"))
    }
}

final class BakeProgressTests: XCTestCase {

    /// One definition of what the work is called: the chart window's pill and
    /// the Charts panel both read it. When they each had their own, a removal
    /// was still headed "Importing".
    func testWhatEachKindOfWorkIsCalled() {
        XCTAssertEqual(BakeProgress(kind: .removing, name: "NOAA").title, "Removing NOAA")
        XCTAssertEqual(BakeProgress(kind: .finding, name: "NOAA").title,
                       "Finding charts in NOAA")
        // A count means the charts have been found and are being converted.
        XCTAssertEqual(BakeProgress(kind: .importing, total: 0, name: "NOAA").title,
                       "Finding charts in NOAA")
        XCTAssertEqual(BakeProgress(kind: .importing, done: 1, total: 62, name: "NOAA").title,
                       "Importing NOAA")
    }

    func testTheFraction() {
        XCTAssertEqual(BakeProgress(done: 0, total: 0).fraction, 0)
        XCTAssertEqual(BakeProgress(done: 3, total: 6).fraction, 0.5)
        XCTAssertEqual(BakeProgress(done: 6, total: 6).fraction, 1)
    }

    /// Nothing is said until there is enough to say it from.
    func testTheEstimateWaitsForThreeCharts() {
        XCTAssertNil(BakeProgress(done: 0, total: 100, elapsed: 10).remaining)
        XCTAssertNil(BakeProgress(done: 2, total: 100, elapsed: 10).remaining)
        XCTAssertNil(BakeProgress(done: 3, total: 100, elapsed: 0.5).remaining)
        XCTAssertNil(BakeProgress(done: 100, total: 100, elapsed: 10).remaining)
    }

    func testTheEstimateInEachUnit() {
        XCTAssertEqual(BakeProgress(done: 3, total: 6, elapsed: 3).remaining,
                       "under a minute left")
        XCTAssertEqual(BakeProgress(done: 3, total: 203, elapsed: 3).remaining,
                       "about 3 min left")
        XCTAssertEqual(BakeProgress(done: 3, total: 10_803, elapsed: 3).remaining,
                       "about 3.0 h left")
    }

    /// A removal is seconds of disk work. A countdown on something already over
    /// by the time it is read is noise.
    func testARemovalIsNotTimed() {
        XCTAssertNil(BakeProgress(kind: .removing, done: 3, total: 100, elapsed: 3).remaining)
    }
}

final class ProviderLabelTests: XCTestCase {

    /// A community MBTiles names its provider, and that is what a mariner
    /// chooses between.
    func testAProviderInTheFileName() {
        XCTAssertEqual(RasterModel.providerLabel("/a/ArcGIS-Chesapeake.mbtiles"), "ArcGIS")
        XCTAssertEqual(RasterModel.providerLabel("/a/bing_z16.mbtiles"), "Bing")
        XCTAssertEqual(RasterModel.providerLabel("/a/NAVIONICS.mbtiles"), "Navionics")
        XCTAssertEqual(RasterModel.providerLabel("/a/sentinel2.mbtiles"), "Sentinel")
    }

    /// ESRI and Esri are both listed and the match ignores case, so the first
    /// entry answers for either spelling.
    func testTheCaseInsensitiveMatchAnswersOnce() {
        XCTAssertEqual(RasterModel.providerLabel("/a/Esri-World.mbtiles"), "ESRI")
        XCTAssertEqual(RasterModel.providerLabel("/a/ESRI-World.mbtiles"), "ESRI")
    }

    /// A baked sheet does not name a provider: tile57 writes one directory per
    /// sheet under a bake root, so they belong to the bake they came from.
    func testABakedSheetBelongsToItsBake() {
        XCTAssertEqual(RasterModel.providerLabel("/bakes/Chesapeake/US5MD1MC/US5MD1MC.pmtiles"),
                       "Chesapeake")
    }

    /// Anything else is its own file name.
    func testOtherwiseTheFileNamesItself() {
        XCTAssertEqual(RasterModel.providerLabel("/a/photo.mbtiles"), "photo")
        XCTAssertEqual(RasterModel.providerLabel("/a/US5MD1MC.pmtiles"), "US5MD1MC")
        XCTAssertEqual(RasterModel.providerLabel("photo.mbtiles"), "photo")
    }
}
