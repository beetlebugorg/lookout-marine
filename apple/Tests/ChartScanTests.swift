//  ChartScanTests.swift — what the core reports about a folder.
//
//  lookout_scan_read needs no chart open, so these run against the live core
//  over the baked cell this repository carries for the Android build. When the
//  repository is not beside the test bundle they skip rather than assert
//  against nothing.

import XCTest
@testable import LookoutMarine

final class ChartScanTests: XCTestCase {

    /// The repository, from this source file's own path.
    private var repo: URL {
        URL(fileURLWithPath: #filePath)          // apple/Tests/ChartScanTests.swift
            .deletingLastPathComponent()         // apple/Tests
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
        XCTAssertEqual(cell.kind, .baked)
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
        let dir = try bakedChartDirectory()
        let set = try XCTUnwrap(ChartScan.scan(dir))
        XCTAssertEqual(set.openablePaths.count, 1)
        XCTAssertFalse(set.isDerived)
    }

    /// The producer code comes from the cell names in the folder.
    func testTheProducerComesFromTheCharts() throws {
        let dir = try bakedChartDirectory()
        let set = try XCTUnwrap(ChartScan.scan(dir))
        XCTAssertEqual(set.producer, "US")
        XCTAssertEqual(set.name, "charts")
    }

    func testASummaryOfWhatIsInstalled() throws {
        let dir = try bakedChartDirectory()
        let set = try XCTUnwrap(ChartScan.scan(dir))
        XCTAssertTrue(set.summary.hasPrefix("1 chart · Harbor · "), set.summary)
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

    private func cell(_ name: String, band: Int = 5, kind: ScannedCell.Kind = .baked,
                      bytes: Int64 = 1_000_000, archived: Bool = false) -> ScannedCell {
        ScannedCell(path: "/charts/\(name)/\(name).pmtiles", name: name, kind: kind,
                    band: band, bytes: bytes, archived: archived)
    }

    /// The core names the set. A set read without the core keeps its folder
    /// name.
    func testTheTitleIsTheCoresElseTheFolderName() {
        var s = set(producer: "US")
        XCTAssertEqual(s.title, "ENC_ROOT")
        s.coreTitle = "NOAA"
        XCTAssertEqual(s.title, "NOAA")
    }

    /// The ramp reads the core's counts, coarse to fine, and skips an empty
    /// band.
    func testTheBandCountsAreTheCores() {
        var s = set()
        s.bandCount = [0, 2, 0, 0, 7, 0]
        XCTAssertEqual(s.bandCounts.map(\.band), [2, 5])
        XCTAssertEqual(s.bandCounts.map(\.name), ["General", "Harbor"])
        XCTAssertEqual(s.bandCounts.map(\.count), [2, 7])
    }

    func testTheSummaryCountsBothKindsAndTheBandRange() {
        let s = set(cells: [cell("US1AA", band: 2), cell("US5BB", band: 5)],
                    rasters: [cell("photo", band: 0, kind: .raster)])
        XCTAssertTrue(s.summary.hasPrefix("2 charts · 1 picture · General to Harbor · "),
                      s.summary)
    }

    func testTheSummaryOfOneChart() {
        XCTAssertTrue(set(cells: [cell("US5BB")]).summary.hasPrefix("1 chart · Harbor · "))
    }

    func testEveryBandName() {
        XCTAssertEqual((1...6).map(TextFormat.usageBand),
                       ["Overview", "General", "Coastal", "Approach", "Harbor", "Berthing"])
        XCTAssertEqual(TextFormat.usageBand(0), "Unknown")
    }

    /// The band ramp reads the core's palette, in every scheme.
    func testEveryBandHasAPaletteColour() {
        for band in 1...6 {
            for scheme: UInt32 in 0...2 {
                XCTAssertNotNil(Chrome.s52("BAND\(band)", scheme: scheme), "BAND\(band) in \(scheme)")
            }
        }
        XCTAssertNil(Chrome.s52("BAND7", scheme: 0))
    }

    /// A chart still inside an archive is not a path the engine can open.
    func testAnArchivedCellIsNotOpenable() {
        let s = set(cells: [cell("a"), cell("b", archived: true)])
        XCTAssertEqual(s.openablePaths.count, 1)
    }

    /// A raw S-57 cell and a BSB sheet both prepare first.
    func testWhatHasToBePreparedFirst() {
        XCTAssertTrue(cell("a", kind: .source).needsBake)
        XCTAssertTrue(cell("a", kind: .rasterSource).needsBake)
        XCTAssertFalse(cell("a", kind: .baked).needsBake)
        XCTAssertFalse(cell("a", kind: .raster).needsBake)
        XCTAssertTrue(cell("a", kind: .raster).isRaster)
        XCTAssertTrue(cell("a", kind: .rasterSource).isRaster)
        XCTAssertFalse(cell("a", kind: .baked).isRaster)
    }

    /// A set Lookout prepared charts for is derived, and removing it deletes
    /// them.
    func testASetWithAPreparedDirectoryIsDerived() {
        let cells = [cell("a"), cell("b", kind: .source)]
        XCTAssertTrue(set(cells: cells, prepared: "/prepared").isDerived)
        XCTAssertFalse(set(cells: cells).isDerived)
    }

    /// A folder can hold hundreds of tiles from one survey. One switch per
    /// provider is the decision a mariner makes; two hundred is not.
    func testPicturesAreGroupedByProvider() {
        let rasters = [
            ScannedCell(path: "/a/ArcGIS-1.mbtiles", name: "ArcGIS-1.mbtiles", kind: .raster,
                        band: 0, bytes: 1),
            ScannedCell(path: "/a/ArcGIS-2.mbtiles", name: "ArcGIS-2.mbtiles", kind: .raster,
                        band: 0, bytes: 1),
            ScannedCell(path: "/a/Bing-1.mbtiles", name: "Bing-1.mbtiles", kind: .raster,
                        band: 0, bytes: 1),
        ]
        let groups = set(rasters: rasters).rasterGroups(label: RasterModel.providerLabel)
        XCTAssertEqual(groups.map(\.name), ["ArcGIS", "Bing"])
        XCTAssertEqual(groups.map { $0.paths.count }, [2, 1])
    }

    /// A picture still inside an archive is not drawable yet.
    func testAnUnpreparedPictureIsNotOffered() {
        let s = set(rasters: [ScannedCell(path: "/a/x.kap", name: "x.kap",
                                          kind: .rasterSource, band: 0, bytes: 1)])
        XCTAssertTrue(s.rasterPaths.isEmpty)
        XCTAssertTrue(s.rasterGroups(label: RasterModel.providerLabel).isEmpty)
    }

    /// A set holding one prepared chart draws.
    func testAPreparedCellIsSomethingToDraw() {
        let s = set(cells: [
            cell("US5MD1MC", kind: .baked),
            cell("US5VA22M", kind: .source),
        ], prepared: "/prepared/ENC_ROOT")
        XCTAssertTrue(s.hasSomethingToDraw)
    }

    /// A set of raw cells has no chart to draw until they are prepared.
    func testAnUnpreparedSetHasNothingToDraw() {
        let s = set(cells: [
            cell("US5MD1MC", kind: .source),
            cell("US5VA22M", kind: .source),
        ])
        XCTAssertFalse(s.hasSomethingToDraw)
    }
}
