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

    /// An exchange set as an agency publishes it: one cell under ENC_ROOT. The
    /// name is unique so two runs use different prepared directories, which are
    /// under this machine's application support.
    private func archive(in dir: String) throws -> String {
        let zip = (dir as NSString).appendingPathComponent("ENCs-\(UUID().uuidString).zip")
        try MiniZip.write([("ENC_ROOT/US5MD1MC/US5MD1MC.000", Data("x".utf8))], to: zip)
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

    /// A folder holding one chart archive holds charts. A double click on the
    /// archive in the open panel also arrives as the folder.
    func testAFolderOfArchivesOffersTheArchive() throws {
        let dir = try temporaryDirectory()
        let zip = try archive(in: dir)
        FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent("readme.txt"),
                                       contents: Data("hi".utf8))
        // The folder itself holds no chart file.
        let asFolder = ChartScan.scan(dir)
        XCTAssertTrue(asFolder?.cells.isEmpty ?? true)
        XCTAssertEqual(ChartScan.archivesHoldingCharts(in: dir), [zip])
    }

    /// An archive holding no charts is not offered.
    func testAnArchiveWithNoChartsIsNotOffered() throws {
        let dir = try temporaryDirectory()
        try MiniZip.write([("notes.txt", Data("hi".utf8))],
                          to: (dir as NSString).appendingPathComponent("notes.zip"))
        XCTAssertTrue(ChartScan.archivesHoldingCharts(in: dir).isEmpty)
    }

    func testAFileIsNotAFolderOfArchives() throws {
        let dir = try temporaryDirectory()
        let zip = try archive(in: dir)
        XCTAssertTrue(ChartScan.archivesHoldingCharts(in: zip).isEmpty)
        XCTAssertTrue(ChartScan.archivesHoldingCharts(in: "/no/such/folder").isEmpty)
    }
}


/// A .zip written here, with every entry stored rather than deflated.
///
/// The fixture is a listing: the core reads an archive's central directory and
/// names each entry, and it inflates nothing. Writing the file in Swift keeps
/// the test off /usr/bin/zip, which the iOS target has no Process to run.
enum MiniZip {
    static func write(_ entries: [(name: String, data: Data)], to path: String) throws {
        try archive(entries).write(to: URL(fileURLWithPath: path))
    }

    static func archive(_ entries: [(name: String, data: Data)]) -> Data {
        var out = Data()
        var central = Data()
        for e in entries {
            let name = Data(e.name.utf8)
            let crc = crc32(e.data)
            let size = UInt32(e.data.count)
            let offset = UInt32(out.count)
            // Local header: version 2.0, no flags, stored, no timestamp.
            out += le32(0x0403_4b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0)
            out += le32(crc) + le32(size) + le32(size)
            out += le16(UInt16(name.count)) + le16(0)
            out += name + e.data
            central += le32(0x0201_4b50) + le16(20) + le16(20)
            central += le16(0) + le16(0) + le16(0) + le16(0)
            central += le32(crc) + le32(size) + le32(size)
            // Name, extra, comment, disk, internal attributes.
            central += le16(UInt16(name.count)) + le16(0) + le16(0) + le16(0) + le16(0)
            central += le32(0) + le32(offset) + name
        }
        let directory = UInt32(central.count)
        let start = UInt32(out.count)
        out += central
        out += le32(0x0605_4b50) + le16(0) + le16(0)
        out += le16(UInt16(entries.count)) + le16(UInt16(entries.count))
        out += le32(directory) + le32(start) + le16(0)
        return out
    }

    private static func le16(_ v: UInt16) -> Data {
        Data([UInt8(v & 0xFF), UInt8(v >> 8)])
    }

    private static func le32(_ v: UInt32) -> Data {
        Data([UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
              UInt8((v >> 16) & 0xFF), UInt8(v >> 24)])
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data {
            c ^= UInt32(byte)
            for _ in 0..<8 {
                c = (c & 1) != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1
            }
        }
        return c ^ 0xFFFF_FFFF
    }
}
