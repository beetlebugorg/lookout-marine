//  ChartSetStoreTests.swift — the installed sets, across launches and across
//  versions of this app.
//
//  The CORE holds the list. Only the folder and the switch are stored: the
//  cells are scanned again at launch, because a folder changes underneath the
//  app.
//
//  What a mariner had before there was a list is carried across by
//  StoreImport.seedChartSets, which runs once, so those tests drive
//  importDefaults rather than the list.

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

    func testSwitchingASetOffKeepsItInstalled() {
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

    /// One import, on a defaults suite of its own so the mariner's own domain
    /// is never read.
    private func carryAcross(recents: [String]? = nil) {
        let suite = "org.beetlebug.lookout.sets." + UUID().uuidString
        let d = UserDefaults(suiteName: suite)!
        defer { d.removePersistentDomain(forName: suite) }
        if let recents { d.set(recents, forKey: "lookout.recents") }
        Store.shared.importDefaults(d)
        ChartSetStore.reopen()
    }

    /// A mariner who had charts open before this list existed still has them
    /// after. Without it their charts are simply gone at the next launch, with
    /// the folder still on disk.
    func testTheLastOpenedPathsAreCarriedAcrossOnce() {
        carryAcross(recents: ["/charts/old"])
        XCTAssertEqual(ChartSetStore.savedPaths(), ["/charts/old"])
        // Written through, so the next launch reads the new list.
        XCTAssertEqual(Store.shared.strings(Store.Group.chartsets, "paths"), ["/charts/old"])
    }

    /// The paths are not filtered on the way across. A scan decides what is a
    /// chart, so an entry that was never one drops out on its own.
    func testAPathThatIsNotThereIsStillCarriedAcross() {
        carryAcross(recents: ["/no/such/folder"])
        XCTAssertEqual(ChartSetStore.savedPaths(), ["/no/such/folder"])
    }

    func testNoSetsAndNoRecentsIsStillEmpty() {
        carryAcross()
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

        carryAcross()
        XCTAssertEqual(ChartSetStore.savedPaths(), ["/charts/a", dir])

        // The migration flag stops it running twice, so a folder the mariner
        // then removed does not come back at the next launch.
        ChartSetStore.remove(dir)
        carryAcross()
        XCTAssertEqual(ChartSetStore.savedPaths(), ["/charts/a"])
    }

    /// Charts this app prepared already belong to the set they were made from,
    /// and each sits in a directory of its own name: a folder of 900 sheets
    /// would otherwise arrive as 900 sets.
    func testWhatThisAppPreparedIsNotCarriedAcross() throws {
        let root = try XCTUnwrap(ChartBake.chartsRoot)
        Store.shared.set([root + "/Set/US5MD1MC/US5MD1MC.pmtiles"], RasterModel.group, RasterModel.pathsKey)
        Store.shared.set(["/charts/a"], Store.Group.chartsets, "paths")
        carryAcross()
        XCTAssertEqual(ChartSetStore.savedPaths(), ["/charts/a"])
    }

    /// A file that is no longer on the disk brings nothing across.
    func testAMissingRasterChartBringsNoFolder() {
        Store.shared.set(["/no/such/photo.mbtiles"], RasterModel.group, RasterModel.pathsKey)
        Store.shared.set(["/charts/a"], Store.Group.chartsets, "paths")
        carryAcross()
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
