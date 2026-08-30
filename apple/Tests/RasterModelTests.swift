//  RasterModelTests.swift — the picture charts under the survey.
//
//  The engine owns the election: showing one set turns off the sets covering
//  the same water. What the model must get right is what it installs, what it
//  writes down, and what it reads back afterwards.

import XCTest
@testable import LookoutMarine

@MainActor
final class RasterModelTests: ShellTestCase {

    /// The engine is held by the test, not by the model: the model's
    /// reference is weak, as the controller's real owner is the chart view.
    private var engine = FakeEngine()

    private func model() -> (RasterModel, FakeEngine) {
        engine = FakeEngine()
        let m = RasterModel()
        m.engine = engine
        return (m, engine)
    }

    func testAddInstallsAndSaves() {
        let (m, _) = model()
        XCTAssertNil(m.add(["/a/ArcGIS.mbtiles", "/a/Bing.mbtiles"]))
        XCTAssertEqual(m.paths, ["/a/ArcGIS.mbtiles", "/a/Bing.mbtiles"])
        XCTAssertEqual(Store.shared.strings(RasterModel.pathsKey),
                       ["/a/ArcGIS.mbtiles", "/a/Bing.mbtiles"])
    }

    /// A file already aboard is not installed twice.
    func testAddIsIdempotent() {
        let (m, e) = model()
        m.add(["/a/one.mbtiles"])
        m.add(["/a/one.mbtiles"])
        XCTAssertEqual(m.paths, ["/a/one.mbtiles"])
        XCTAssertEqual(e.calls.filter { $0 == "addRaster(/a/one.mbtiles)" }.count, 1)
    }

    /// What would not open is named once, not once per file.
    func testOneSentenceForEveryRefusal() {
        let (m, e) = model()
        e.rasterRefuses = ["/a/bad1.mbtiles", "/a/bad2.mbtiles"]
        let err = m.add(["/a/bad1.mbtiles", "/a/bad2.mbtiles", "/a/good.mbtiles"])
        XCTAssertEqual(m.paths, ["/a/good.mbtiles"])
        guard let err else { return XCTFail("no sentence for two refused files") }
        XCTAssertTrue(err.contains("2 of 3"), err)
    }

    func testOneRefusalNamesTheFile() {
        let (m, e) = model()
        e.rasterRefuses = ["/a/bad.mbtiles"]
        let err = m.add(["/a/bad.mbtiles"])
        XCTAssertEqual(err?.contains("bad.mbtiles"), true, err ?? "nil")
    }

    /// A chart added over the water in view is drawn: the mariner picked it
    /// while looking at this water.
    func testAddingOverThisWaterDrawsIt() {
        let (m, e) = model()
        e.rasterSetList = [RasterSet(id: 3, name: "ArcGIS", inView: true, shown: false)]
        m.add(["/a/ArcGIS.mbtiles"])
        XCTAssertTrue(e.calls.contains("rasterSelect(3)"))
    }

    /// A chart that does not cover this view is installed and left alone.
    func testAddingElsewhereDrawsNothing() {
        let (m, e) = model()
        e.rasterSetList = [RasterSet(id: 3, name: "ArcGIS", inView: false, shown: false)]
        m.add(["/a/ArcGIS.mbtiles"])
        XCTAssertFalse(e.calls.contains { $0.hasPrefix("rasterSelect") })
    }

    /// Which sets are drawn is read back from the engine and written down, so
    /// a set switched off at the pill is still off next launch.
    func testTheDrawnSetsAreSaved() {
        let (m, e) = model()
        e.rasterSetList = [RasterSet(id: 0, name: "ArcGIS", inView: true, shown: false),
                           RasterSet(id: 1, name: "Bing", inView: true, shown: true)]
        m.refresh()
        XCTAssertEqual(m.hidden, ["ArcGIS"])
        XCTAssertEqual(Store.shared.strings(RasterModel.hiddenKey), ["ArcGIS"])
    }

    /// A set not installed this launch keeps its entry: a mariner who unplugs
    /// the drive holding one has not changed their mind about it.
    func testAnAbsentSetKeepsItsEntry() {
        Store.shared.set(["Navionics"], RasterModel.hiddenKey)
        let (m, e) = model()
        e.rasterSetList = [RasterSet(id: 0, name: "ArcGIS", inView: true, shown: true)]
        m.refresh()
        XCTAssertTrue(m.hidden.contains("Navionics"))
    }

    func testSwitchingOffKeepsItInstalled() {
        let (m, _) = model()
        m.add(["/a/one.mbtiles"])
        m.setEnabled("/a/one.mbtiles", false)
        XCTAssertEqual(m.paths, ["/a/one.mbtiles"])
        XCTAssertEqual(m.off, ["/a/one.mbtiles"])
        XCTAssertFalse(m.groupOn(["/a/one.mbtiles"]))
    }

    /// A group is on while any one of its files is.
    func testAGroupIsOnWhileAnyFileIs() {
        let (m, _) = model()
        m.setEnabled("/a/one.mbtiles", false)
        XCTAssertTrue(m.groupOn(["/a/one.mbtiles", "/a/two.mbtiles"]))
        m.setEnabled("/a/two.mbtiles", false)
        XCTAssertFalse(m.groupOn(["/a/one.mbtiles", "/a/two.mbtiles"]))
    }

    func testRemoveForgetsThePathAndItsOffState() {
        let (m, _) = model()
        m.add(["/a/one.mbtiles"])
        m.setEnabled("/a/one.mbtiles", false)
        m.remove("/a/one.mbtiles")
        XCTAssertTrue(m.paths.isEmpty)
        XCTAssertTrue(m.off.isEmpty)
        XCTAssertEqual(Store.shared.strings(RasterModel.pathsKey), [])
    }

    /// The three lists describe the same charts, so clearing drops all three.
    /// Leaving one behind means the same file added again months later comes
    /// back switched off with nothing on screen to say why.
    func testClearDropsAllThreeLists() {
        let (m, e) = model()
        e.rasterSetList = [RasterSet(id: 0, name: "ArcGIS", inView: true, shown: false)]
        m.add(["/a/ArcGIS.mbtiles"])
        m.setEnabled("/a/ArcGIS.mbtiles", false)
        m.clear()
        XCTAssertTrue(m.paths.isEmpty)
        XCTAssertTrue(m.off.isEmpty)
        XCTAssertTrue(m.hidden.isEmpty)
        XCTAssertEqual(Store.shared.strings(RasterModel.hiddenKey), [])
    }

    /// Nothing installed: the caller is told, so it can offer the picker
    /// rather than letting the key press do nothing at all.
    func testCycleSaysWhenThereIsNowhereToGo() {
        let (m, e) = model()
        XCTAssertFalse(m.cycle())
        XCTAssertFalse(e.calls.contains("cycleRaster"))
        m.add(["/a/one.mbtiles"])
        XCTAssertTrue(m.cycle())
        XCTAssertTrue(e.calls.contains("cycleRaster"))
    }

    func testHidingTheEncIsSaved() {
        let (m, _) = model()
        m.toggleChart()
        XCTAssertTrue(m.chartHidden)
        XCTAssertTrue(m.chartHiddenSaved)
        XCTAssertTrue(Store.shared.bool(RasterModel.chartHiddenKey))
    }

    /// What is aboard is read at init, and anything since deleted is dropped:
    /// a stale entry must not become an error dismissed at every launch.
    func testInitDropsPathsThatAreGone() {
        let here = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".mbtiles")
        FileManager.default.createFile(atPath: here.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: here) }
        Store.shared.set([here.path, "/no/such/photo.mbtiles"], RasterModel.pathsKey)
        XCTAssertEqual(RasterModel().paths, [here.path])
    }
}
