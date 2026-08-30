//  ChartScanTests.swift — what the core reports about a folder.
//
//  lookout_scan_charts needs no chart open, so these run against the live core
//  over the baked cell this repository carries for the Android build. When the
//  repository is not beside the test bundle they skip rather than assert
//  against nothing.

import XCTest
@testable import LookoutMarine

final class ChartScanTests: XCTestCase {

    /// The repository, from this source file's own path.
    private var repo: URL {
        URL(fileURLWithPath: #filePath)          // macos/Tests/ChartScanTests.swift
            .deletingLastPathComponent()         // macos/Tests
            .deletingLastPathComponent()         // macos
            .deletingLastPathComponent()         // the repository
    }

    private func bakedChartDirectory() throws -> String {
        let dir = repo.appendingPathComponent("android/app/src/main/assets/charts")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path),
                          "no repository beside the test bundle")
        return dir.path
    }

    func testAFolderOfBakedCells() throws {
        let dir = try bakedChartDirectory()
        let set = try XCTUnwrap(ChartScan.scan(dir), "the core read nothing in \(dir)")
        XCTAssertEqual(set.cells.count, 1)
        XCTAssertTrue(set.rasters.isEmpty)
        let cell = try XCTUnwrap(set.cells.first)
        XCTAssertEqual(cell.name, "US5MD1MC")
        XCTAssertEqual(cell.kind, "baked")
        XCTAssertEqual(cell.band, 5)
        XCTAssertEqual(cell.stem, "US5MD1MC")
        XCTAssertGreaterThan(cell.bytes, 0)
        XCTAssertFalse(cell.archived)
        XCTAssertFalse(cell.needsBake)
        XCTAssertFalse(cell.needsPrepare)
        XCTAssertFalse(cell.isRaster)
    }

    /// A baked cell is ready to hand to the engine.
    func testABakedCellIsOpenable() throws {
        let set = try XCTUnwrap(ChartScan.scan(try bakedChartDirectory()))
        XCTAssertEqual(set.openablePaths.count, 1)
        XCTAssertEqual(set.needsBake, 0)
        XCTAssertFalse(set.isDerived)
    }

    /// The producer code comes from the charts, not the folder name, and names
    /// the office in the row.
    func testTheProducerNamesTheOffice() throws {
        let set = try XCTUnwrap(ChartScan.scan(try bakedChartDirectory()))
        XCTAssertEqual(set.producer, "US")
        XCTAssertEqual(set.title, "NOAA")
        XCTAssertEqual(set.name, "charts")
    }

    func testASummaryOfWhatIsAboard() throws {
        let set = try XCTUnwrap(ChartScan.scan(try bakedChartDirectory()))
        XCTAssertTrue(set.summary.hasPrefix("1 chart · Harbor · "), set.summary)
        XCTAssertEqual(set.bandCounts.map(\.band), [5])
        XCTAssertEqual(set.bandCounts.map(\.name), ["Harbor"])
        XCTAssertEqual(set.bandCounts.map(\.count), [1])
    }

    func testAFolderWithNoChartsIsNotASet() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-scan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "not a chart".write(to: dir.appendingPathComponent("readme.txt"),
                                atomically: true, encoding: .utf8)
        let set = ChartScan.scan(dir.path)
        XCTAssertTrue(set == nil || (set!.cells.isEmpty && set!.rasters.isEmpty))
    }

    /// The core answers for a path that is not there rather than refusing, so
    /// the shell's own test is whether the folder holds anything to draw. That
    /// is what AppModel.addChartSet checks before putting a set on the list.
    func testAPathThatIsNotThereHoldsNoCharts() {
        let set = ChartScan.scan("/no/such/folder")
        XCTAssertTrue(set?.cells.isEmpty ?? true)
        XCTAssertTrue(set?.rasters.isEmpty ?? true)
    }

    /// A chart set may arrive as one archive, which is how an agency publishes.
    func testWhichPathsAreArchives() {
        XCTAssertTrue(ChartScan.isArchive("/a/All_ENCs.zip"))
        XCTAssertTrue(ChartScan.isArchive("/a/All_ENCs.ZIP"))
        XCTAssertFalse(ChartScan.isArchive("/a/US5MD1MC.pmtiles"))
        XCTAssertFalse(ChartScan.isArchive("/a/ENC_ROOT"))
    }
}

final class ChartSetTests: XCTestCase {

    private func set(cells: [ScannedCell] = [], rasters: [ScannedCell] = [],
                     producer: String? = nil, prepared: String? = nil,
                     path: String = "/charts/ENC_ROOT") -> ChartSet {
        ChartSet(path: path, producer: producer, preparedPath: prepared,
                 cells: cells, rasters: rasters, on: true)
    }

    private func cell(_ name: String, band: Int = 5, kind: String = "baked",
                      bytes: Int64 = 1_000_000, archived: Bool = false) -> ScannedCell {
        ScannedCell(path: "/charts/\(name)/\(name).pmtiles", name: name, kind: kind,
                    band: band, bytes: bytes, archived: archived)
    }

    /// An office not listed keeps the folder name. A wrong agency on a chart
    /// set is worse than a dull one.
    func testTheOfficeForEachProducerCode() {
        XCTAssertEqual(ChartSet.agency("US"), "NOAA")
        XCTAssertEqual(ChartSet.agency("us"), "NOAA")
        XCTAssertEqual(ChartSet.agency("GB"), "UKHO")
        XCTAssertEqual(ChartSet.agency("NZ"), "LINZ")
        XCTAssertNil(ChartSet.agency("XX"))
        XCTAssertNil(ChartSet.agency(nil))
    }

    func testAnUnlistedProducerKeepsTheFolderName() {
        XCTAssertEqual(set(producer: "XX").title, "ENC_ROOT")
        XCTAssertEqual(set(producer: nil).title, "ENC_ROOT")
        XCTAssertEqual(set(producer: "US").title, "NOAA")
    }

    func testTheSummaryCountsBothKindsAndTheBandRange() {
        let s = set(cells: [cell("US1AA", band: 2), cell("US5BB", band: 5)],
                    rasters: [cell("photo", band: 0, kind: "raster")])
        XCTAssertTrue(s.summary.hasPrefix("2 charts · 1 picture · General to Harbor · "),
                      s.summary)
    }

    func testTheSummaryOfOneChart() {
        XCTAssertTrue(set(cells: [cell("US5BB")]).summary.hasPrefix("1 chart · Harbor · "))
    }

    /// The ladder says whether a set reaches the harbour a passage ends in.
    func testTheBandLadderIsCoarseToFine() {
        let s = set(cells: [cell("a", band: 5), cell("b", band: 2), cell("c", band: 5)])
        XCTAssertEqual(s.bandCounts.map(\.band), [2, 5])
        XCTAssertEqual(s.bandCounts.map(\.count), [1, 2])
        XCTAssertEqual(s.bandCounts.map(\.name), ["General", "Harbor"])
    }

    func testEveryBandName() {
        XCTAssertEqual((1...6).map(ChartSet.bandName),
                       ["Overview", "General", "Coastal", "Approach", "Harbor", "Berthing"])
        XCTAssertEqual(ChartSet.bandName(0), "Unknown")
    }

    /// A chart still inside an archive is not a path the engine can open.
    func testAnArchivedCellIsNotOpenable() {
        let s = set(cells: [cell("a"), cell("b", archived: true)])
        XCTAssertEqual(s.openablePaths.count, 1)
        XCTAssertEqual(s.needsBake, 1)
    }

    /// A raw S-57 cell and a BSB sheet both prepare first.
    func testWhatHasToBePreparedFirst() {
        XCTAssertTrue(cell("a", kind: "source").needsBake)
        XCTAssertTrue(cell("a", kind: "raster_source").needsBake)
        XCTAssertFalse(cell("a", kind: "baked").needsBake)
        XCTAssertFalse(cell("a", kind: "raster").needsBake)
        XCTAssertTrue(cell("a", kind: "raster").isRaster)
        XCTAssertTrue(cell("a", kind: "raster_source").isRaster)
        XCTAssertFalse(cell("a", kind: "baked").isRaster)
    }

    /// Offering to prepare them again would say the work is unfinished when it
    /// is as finished as it will get.
    func testWhatIsLeftAfterAPrepareIsCountedAsRefused() {
        let cells = [cell("a"), cell("b", kind: "source")]
        XCTAssertEqual(set(cells: cells, prepared: nil).refusedCount, 0)
        XCTAssertEqual(set(cells: cells, prepared: "/prepared").refusedCount, 1)
        XCTAssertTrue(set(cells: cells, prepared: "/prepared").isDerived)
        XCTAssertFalse(set(cells: cells).isDerived)
    }

    /// A folder can hold hundreds of tiles from one survey. One switch per
    /// provider is the decision a mariner makes; two hundred is not.
    func testPicturesAreGroupedByProvider() {
        let rasters = [
            ScannedCell(path: "/a/ArcGIS-1.mbtiles", name: "ArcGIS-1.mbtiles", kind: "raster",
                        band: 0, bytes: 1),
            ScannedCell(path: "/a/ArcGIS-2.mbtiles", name: "ArcGIS-2.mbtiles", kind: "raster",
                        band: 0, bytes: 1),
            ScannedCell(path: "/a/Bing-1.mbtiles", name: "Bing-1.mbtiles", kind: "raster",
                        band: 0, bytes: 1),
        ]
        let groups = set(rasters: rasters).rasterGroups(label: RasterModel.providerLabel)
        XCTAssertEqual(groups.map(\.name), ["ArcGIS", "Bing"])
        XCTAssertEqual(groups.map { $0.paths.count }, [2, 1])
    }

    /// A picture still inside an archive is not drawable yet.
    func testAnUnpreparedPictureIsNotOffered() {
        let s = set(rasters: [ScannedCell(path: "/a/x.kap", name: "x.kap",
                                          kind: "raster_source", band: 0, bytes: 1)])
        XCTAssertTrue(s.rasterPaths.isEmpty)
        XCTAssertTrue(s.rasterGroups(label: RasterModel.providerLabel).isEmpty)
    }
}
