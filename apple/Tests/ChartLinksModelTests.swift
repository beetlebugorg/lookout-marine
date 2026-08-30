//  ChartLinksModelTests.swift — an online map AS the chart.
//
//  The core owns the list, resolves the styles and persists them, so what this
//  checks is the reading back and the asking: the snapshot it renders, and the
//  calls it declines to make.

import XCTest
@testable import LookoutMarine

@MainActor
final class ChartLinksModelTests: ShellTestCase {
    private var engine = FakeEngine()

    private func model() -> ChartLinksModel {
        engine = FakeEngine()
        let m = ChartLinksModel()
        m.engine = engine
        return m
    }

    private let snapshot = """
    {"links":[{"url":"https://a/style.json","name":"A"},
              {"url":"https://b/style.json","name":"B"}],
     "active":"https://b/style.json",
     "attribution":"© A publisher","error":"","busy":false}
    """

    func testPollRendersTheSnapshot() {
        let m = model()
        engine.linksJSON = snapshot
        m.poll()
        XCTAssertEqual(m.list.map(\.name), ["A", "B"])
        XCTAssertEqual(m.active, "https://b/style.json")
        XCTAssertEqual(m.attribution, "© A publisher")
        XCTAssertNil(m.error)
        XCTAssertFalse(m.busy)
    }

    /// An empty error and an empty credit are "none", not the empty string:
    /// the chrome tests for nil.
    func testEmptyStringsBecomeNothing() {
        let m = model()
        engine.linksJSON = #"{"links":[],"active":null,"attribution":"","error":"","busy":false}"#
        m.attribution = "stale"
        m.error = "stale"
        m.poll()
        XCTAssertNil(m.attribution)
        XCTAssertNil(m.error)
    }

    func testNothingReadableLeavesTheListAlone() {
        let m = model()
        engine.linksJSON = snapshot
        m.poll()
        engine.linksJSON = nil
        m.poll()
        XCTAssertEqual(m.list.count, 2)
    }

    /// Adding is the request to sail on it, so it goes busy and clears the
    /// last failure.
    func testAddClearsTheErrorAndGoesBusy() {
        let m = model()
        m.error = "the last one did not answer"
        m.add("  https://a/style.json  ")
        XCTAssertNil(m.error)
        XCTAssertTrue(m.busy)
        XCTAssertTrue(engine.calls.contains("addChartLink(https://a/style.json)"))
    }

    func testAnEmptyLinkAsksNothing() {
        let m = model()
        m.add("   ")
        XCTAssertTrue(engine.calls.isEmpty)
        XCTAssertFalse(m.busy)
    }

    /// A file the mariner picked takes the same call: the core tells a path
    /// from a url, and a path is the one thing it may read off disk.
    func testAFileStyleGoesInAsAPath() {
        let m = model()
        m.importStyle(URL(fileURLWithPath: "/a/style.json"))
        XCTAssertTrue(engine.calls.contains("addChartLink(/a/style.json)"))
    }

    /// The settings row fires on every click. Re-selecting the drawn chart
    /// would re-resolve the style and every sprite pack for nothing.
    func testSelectingTheDrawnChartAsksNothing() {
        let m = model()
        m.active = "https://b/style.json"
        m.select("https://b/style.json")
        XCTAssertTrue(engine.calls.isEmpty)
    }

    /// Unless its last resolve failed, which is a retry.
    func testSelectingRetriesAfterAFailure() {
        let m = model()
        m.active = "https://b/style.json"
        m.error = "did not answer"
        m.select("https://b/style.json")
        XCTAssertTrue(engine.calls.contains("selectChartLink(https://b/style.json)"))
    }

    /// Back to the built-in chart always goes through, and does not go busy:
    /// there is nothing to resolve.
    func testSelectingNoneAlwaysGoesThrough() {
        let m = model()
        m.select(nil)
        XCTAssertTrue(engine.calls.contains("selectChartLink(nil)"))
        XCTAssertFalse(m.busy)
    }

    /// The old UserDefaults list is handed to the core once and then dropped.
    func testTheOldStoreIsHandedOverAndForgotten() {
        let m = model()
        let old = try! JSONSerialization.data(withJSONObject: [["url": "https://a", "name": "A"]])
        Store.shared.set(old, "lookout.chartlinks")
        Store.shared.set("https://a", "lookout.chartlinks.active")
        m.migrate()
        XCTAssertTrue(engine.calls.contains("importChartLinks"))
        XCTAssertNil(Store.shared.data("lookout.chartlinks"))
        XCTAssertNil(Store.shared.string("lookout.chartlinks.active"))
    }

    func testNothingToMigrateAsksNothing() {
        let m = model()
        m.migrate()
        XCTAssertTrue(engine.calls.isEmpty)
    }
}
