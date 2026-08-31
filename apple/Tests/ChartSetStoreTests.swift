//  ChartSetStoreTests.swift — the sets aboard, across launches and across
//  versions of this app.
//
//  Only the folder and the switch are stored. The cells are scanned again at
//  launch, because a folder changes underneath the app.

import XCTest
@testable import LookoutMarine

final class ChartSetStoreTests: ShellTestCase {

    func testNothingSavedIsNoSets() {
        XCTAssertTrue(ChartSetStore.savedPaths().isEmpty)
        XCTAssertTrue(ChartSetStore.savedOff().isEmpty)
    }

    func testAddingAndRemoving() {
        ChartSetStore.add("/charts/a")
        ChartSetStore.add("/charts/b")
        XCTAssertEqual(ChartSetStore.savedPaths(), ["/charts/a", "/charts/b"])
        ChartSetStore.remove("/charts/a")
        XCTAssertEqual(ChartSetStore.savedPaths(), ["/charts/b"])
    }

    func testAddingTheSameFolderTwiceChangesNothing() {
        ChartSetStore.add("/charts/a")
        ChartSetStore.add("/charts/a")
        XCTAssertEqual(ChartSetStore.savedPaths(), ["/charts/a"])
    }

    func testSwitchingASetOffKeepsItAboard() {
        ChartSetStore.add("/charts/a")
        ChartSetStore.setOff("/charts/a", true)
        XCTAssertEqual(ChartSetStore.savedPaths(), ["/charts/a"])
        XCTAssertEqual(ChartSetStore.savedOff(), ["/charts/a"])
        ChartSetStore.setOff("/charts/a", false)
        XCTAssertTrue(ChartSetStore.savedOff().isEmpty)
    }

    /// Removing a set takes its switch with it, so the same folder added again
    /// months later does not come back switched off with nothing to say why.
    func testRemovingASetTakesItsSwitch() {
        ChartSetStore.add("/charts/a")
        ChartSetStore.setOff("/charts/a", true)
        ChartSetStore.remove("/charts/a")
        XCTAssertTrue(ChartSetStore.savedOff().isEmpty)
    }

    // MARK: What the sets replaced

    /// A mariner who had charts open before this list existed still has them
    /// after. Without it their charts are simply gone at the next launch, with
    /// the folder still on disk.
    func testTheLastOpenedPathsAreCarriedAcrossOnce() {
        Store.shared.set(["/charts/old"], Store.Group.recents, "paths")
        XCTAssertEqual(ChartSetStore.savedPaths(), ["/charts/old"])
        // Written through, so the next launch reads the new list.
        Store.shared.remove(Store.Group.recents, "paths")
        XCTAssertEqual(ChartSetStore.savedPaths(), ["/charts/old"])
    }

    /// The paths are not filtered on the way across. A scan decides what is a
    /// chart, so an entry that was never one drops out on its own.
    func testAPathThatIsNotThereIsStillCarriedAcross() {
        Store.shared.set(["/no/such/folder"], Store.Group.recents, "paths")
        XCTAssertEqual(ChartSetStore.savedPaths(), ["/no/such/folder"])
    }

    func testNoSetsAndNoRecentsIsStillEmpty() {
        XCTAssertTrue(ChartSetStore.savedPaths().isEmpty)
        XCTAssertTrue(Store.shared.strings(Store.Group.chartsets, "paths").isEmpty)
    }

    /// A raster chart added before sets existed arrives as the folder it lives
    /// in, once. One list means one list.
    func testRasterChartsArriveAsSetsOnce() throws {
        let dir = try temporaryDirectory()
        let file = (dir as NSString).appendingPathComponent("photo.mbtiles")
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        Store.shared.set([file], RasterModel.group, RasterModel.pathsKey)
        Store.shared.set(["/charts/a"], Store.Group.chartsets, "paths")

        XCTAssertEqual(ChartSetStore.savedPaths(), ["/charts/a", dir])
        // The migration flag stops it running twice, so a folder the mariner
        // then removed does not come back at the next launch.
        ChartSetStore.remove(dir)
        XCTAssertEqual(ChartSetStore.savedPaths(), ["/charts/a"])
    }

    /// Charts this app prepared already belong to the set they were made from,
    /// and each sits in a directory of its own name: a folder of 900 sheets
    /// would otherwise arrive as 900 sets.
    func testWhatThisAppPreparedIsNotCarriedAcross() throws {
        let root = try XCTUnwrap(ChartBake.chartsRoot)
        Store.shared.set([root + "/Set/US5MD1MC/US5MD1MC.pmtiles"], RasterModel.group, RasterModel.pathsKey)
        Store.shared.set(["/charts/a"], Store.Group.chartsets, "paths")
        XCTAssertEqual(ChartSetStore.savedPaths(), ["/charts/a"])
    }

    /// A file that is no longer on the disk brings nothing across.
    func testAMissingRasterChartBringsNoFolder() {
        Store.shared.set(["/no/such/photo.mbtiles"], RasterModel.group, RasterModel.pathsKey)
        Store.shared.set(["/charts/a"], Store.Group.chartsets, "paths")
        XCTAssertEqual(ChartSetStore.savedPaths(), ["/charts/a"])
    }

    private func temporaryDirectory() throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-sets-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.path
    }
}
