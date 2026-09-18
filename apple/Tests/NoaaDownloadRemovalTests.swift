//  NoaaDownloadRemovalTests.swift — giving the whole NOAA download back.
//
//  A removal that names cells from the catalog leaves any cell no picked
//  district claims. These cover the disk read that replaces it, and the guard
//  that keeps a whole-folder delete inside the app's own downloads.

import XCTest
@testable import LookoutMarine

final class NoaaDownloadRemovalTests: XCTestCase {

    private var dir: URL!
    /// A charts root of the test's own. preparedDirectory keys off the last
    /// path component, so a test folder named NOAA reads the real prepared
    /// NOAA charts under the mariner's charts root.
    private var prepared: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-dl-" + UUID().uuidString, isDirectory: true)
        prepared = dir.appendingPathComponent("prepared", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prepared, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
        prepared = nil
        try super.tearDownWithError()
    }

    private func makeCell(_ parent: URL, _ name: String) throws {
        let d = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try Data().write(to: d.appendingPathComponent("\(name).000"))
    }

    /// An exchange set unpacks under its own ENC_ROOT, so the cells are a level
    /// down from the folder the downloader was given.
    func testCellsHeldReadsAnExchangeSet() throws {
        let root = dir.appendingPathComponent("ENC_ROOT", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeCell(root, "US5MA1BO")
        try makeCell(root, "US4NC1FK")
        try Data().write(to: root.appendingPathComponent("CATALOG.031"))

        XCTAssertEqual(ChartBake.noaaCellsHeld(at: dir.path, preparedRoot: prepared.path),
                       ["US5MA1BO", "US4NC1FK"])
    }

    /// The paperwork an exchange set ships with is not a chart, and neither is
    /// the ENC_ROOT folder itself. Counting either overstates the warning.
    func testCellsHeldCountsNoPaperwork() throws {
        let root = dir.appendingPathComponent("ENC_ROOT", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("README.TXT"))
        try Data().write(to: root.appendingPathComponent("USERAGREEMENT.TXT"))

        XCTAssertEqual(ChartBake.noaaCellsHeld(at: dir.path, preparedRoot: prepared.path), [])
    }

    /// A whole-folder delete runs only on the downloader's own directory. Any
    /// other path is a folder the mariner chose, and their files stay.
    func testAFolderOutsideTheDownloadsIsRefused() throws {
        let root = dir.appendingPathComponent("ENC_ROOT", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeCell(root, "US5MA1BO")

        XCTAssertEqual(
            ChartBake.deleteNoaaDownload(from: dir.path,
                                         permitted: "/somewhere/else",
                                         preparedRoot: prepared.path), 0)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("US5MA1BO").path))
    }

    /// The whole download goes: every cell, the paperwork beside them, and the
    /// folder they are in. A cell no district claims is on the disk like any
    /// other, so reading the disk is what takes it.
    func testTheWholeDownloadGoes() throws {
        let dest = dir.appendingPathComponent("NOAA", isDirectory: true)
        let root = dest.appendingPathComponent("ENC_ROOT", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeCell(root, "US5MA1BO")
        try makeCell(root, "US4NC1FK")
        try makeCell(root, "US3DELISTED")
        try Data().write(to: root.appendingPathComponent("CATALOG.031"))

        let gone = ChartBake.deleteNoaaDownload(from: dest.path,
                                                permitted: dest.path,
                                                preparedRoot: prepared.path)

        XCTAssertEqual(gone, 3)
        // The rename is synchronous, so the folder is out of the library
        // before the call returns. The delete behind it runs off the thread.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.path))
    }
}
