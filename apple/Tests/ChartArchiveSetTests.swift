//  ChartArchiveSetTests.swift — a chart set that arrives as one .zip.
//
//  An agency publishes an exchange set as one archive. A chart inside it draws
//  only after a bake extracts it, so an archive set has one list of installed
//  charts and a different list of openable ones.
//
//  These run against the live core over a real archive and the baked cell in
//  this repository for the Android build.

import XCTest
@testable import LookoutMarine

final class ChartArchiveSetTests: ShellTestCase {

    /// The repository, from this source file's own path.
    private var repo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func bakedCell() throws -> String {
        let p = repo.appendingPathComponent("android/app/src/main/assets/charts/US5MD1MC.pmtiles")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: p.path),
                          "no repository beside the test bundle")
        return p.path
    }

    /// A folder of its own, cleaned up with the test.
    private func temporaryDirectory() throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-archive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.path
    }

    /// An exchange set as an agency publishes it: cells under ENC_ROOT, zipped.
    /// The name is unique so two runs use different prepared directories, which
    /// are under this machine's application support.
    private func archive(in dir: String) throws -> String {
        let root = URL(fileURLWithPath: dir).appendingPathComponent("ENC_ROOT/US5MD1MC")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("US5MD1MC.000"))
        let zip = (dir as NSString).appendingPathComponent("ENCs-\(UUID().uuidString).zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", "-r", zip, "ENC_ROOT"]
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        try p.run()
        p.waitUntilExit()
        try XCTSkipUnless(p.terminationStatus == 0, "could not write the test archive")
        try FileManager.default.removeItem(at: URL(fileURLWithPath: dir)
            .appendingPathComponent("ENC_ROOT"))
        return zip
    }

    /// What a finished import leaves behind: a baked cell in the directory
    /// Lookout prepares into for this set.
    @discardableResult
    private func prepare(_ set: String) throws -> String {
        let dir = try XCTUnwrap(ChartBake.preparedDirectory(for: set))
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(atPath: dir) }
        try FileManager.default.copyItem(
            atPath: try bakedCell(),
            toPath: (dir as NSString).appendingPathComponent("US5MD1MC.pmtiles"))
        return dir
    }

    /// Wait for the core's background scan of `path` to finish.
    private func waitForScan(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if ChartSetStore.all().first(where: { $0.path == path })?.scanned == true { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        XCTFail("the scan of \(path) did not finish", file: file, line: line)
    }

    /// An import writes files into the prepared directory. Only the entries
    /// still inside the archive are names with no file at them.
    ///
    /// Marking every file in a .zip set as an entry reported an imported
    /// library's own charts as unreadable.
    func testAPreparedChartIsNotAnArchiveEntry() throws {
        let dir = try temporaryDirectory()
        let zip = try archive(in: dir)
        try prepare(zip)
        ChartSetStore.add(zip)
        waitForScan(zip)

        let files = ChartSetStore.files(of: zip)
        let prepared = files.filter { $0.path.hasSuffix(".pmtiles") }
        XCTAssertEqual(prepared.count, 1, "the prepared chart belongs to the set")
        XCTAssertFalse(prepared[0].archived)
        XCTAssertFalse(prepared[0].needsPrepare)
    }

    /// The row then counts the set as ready.
    func testAnImportedArchiveHasNoUnreadableFiles() throws {
        let dir = try temporaryDirectory()
        let zip = try archive(in: dir)
        try prepare(zip)
        ChartSetStore.add(zip)
        waitForScan(zip)

        let files = ChartSetStore.files(of: zip)
        let set = ChartSet(path: zip, producer: "US",
                           preparedPath: ChartBake.preparedDirectory(for: zip),
                           cells: files.filter { !$0.isRaster },
                           rasters: files.filter(\.isRaster), on: true)
        XCTAssertEqual(set.refusedCount, 0)
        XCTAssertEqual(set.needsBake, 0)
        XCTAssertEqual(set.openablePaths.count, 1)
    }

    /// The core holds the list. Until it reads the folder again after a bake,
    /// the set composes no openable path and the chart never opens.
    func testASetIsReadAgainAfterABake() throws {
        let dir = try temporaryDirectory()
        let zip = try archive(in: dir)
        ChartSetStore.add(zip)
        waitForScan(zip)
        XCTAssertTrue(ChartSetStore.compose().isEmpty, "no entry inside an archive is openable")

        try prepare(zip)
        // The path is already on the list, so add queues no scan.
        XCTAssertFalse(ChartSetStore.add(zip))
        XCTAssertTrue(ChartSetStore.compose().isEmpty)

        XCTAssertTrue(ChartSetStore.rescan(zip))
        waitForScan(zip)
        XCTAssertEqual(ChartSetStore.compose().count, 1)
        XCTAssertTrue(ChartSetStore.compose()[0].hasSuffix("US5MD1MC.pmtiles"))
    }

    func testAFolderThatIsNotOnTheListIsNotReadAgain() {
        XCTAssertFalse(ChartSetStore.rescan("/no/such/folder"))
    }
}
