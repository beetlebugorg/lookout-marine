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

    /// A read as the core hands it over.
    private let snapshot = ChartLinkSnapshot(
        links: [ChartLinksModel.ChartLink(url: "https://a/style.json", name: "A"),
                ChartLinksModel.ChartLink(url: "https://b/style.json", name: "B")],
        active: "https://b/style.json",
        attribution: "© A publisher",
        error: "",
        busy: false)

    func testPollRendersTheSnapshot() {
        let m = model()
        engine.links = snapshot
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
        engine.links = ChartLinkSnapshot(links: [], active: nil, attribution: "",
                                         error: "", busy: false)
        m.attribution = "stale"
        m.error = "stale"
        m.poll()
        XCTAssertNil(m.attribution)
        XCTAssertNil(m.error)
    }

    /// The changed flag has one consumer, so a poll with no change returns
    /// nil and the list stands.
    func testNothingNewLeavesTheListAlone() {
        let m = model()
        engine.links = snapshot
        m.poll()
        engine.links = nil
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
    /// It reads UserDefaults directly, so the test does too.
    func testTheOldStoreIsHandedOverAndForgotten() {
        let m = model()
        let d = UserDefaults.standard
        let old = try! JSONSerialization.data(withJSONObject: [["url": "https://a", "name": "A"]])
        d.set(old, forKey: "lookout.chartlinks")
        d.set("https://a", forKey: "lookout.chartlinks.active")
        defer {
            d.removeObject(forKey: "lookout.chartlinks")
            d.removeObject(forKey: "lookout.chartlinks.active")
        }
        m.migrate()
        XCTAssertTrue(engine.calls.contains("importChartLinks"))
        XCTAssertNil(d.data(forKey: "lookout.chartlinks"))
        XCTAssertNil(d.string(forKey: "lookout.chartlinks.active"))
    }

    func testNothingToMigrateAsksNothing() {
        let m = model()
        m.migrate()
        XCTAssertTrue(engine.calls.isEmpty)
    }

    // MARK: With no chart open
    //
    // Every call here goes through a lookout handle, which exists only while a
    // chart is open. Without one the call was discarded, and add() left `busy`
    // set forever.

    /// A pick with no chart open asks for one and runs when it opens.
    func testAPickWithNoChartAsksForOneAndRunsWhenItOpens() {
        let m = model()
        engine.hasChartHandle = false
        var asked = 0
        m.openChartForLink = { asked += 1 }
        m.select("https://a/style.json")
        XCTAssertEqual(asked, 1)

        engine.hasChartHandle = true
        m.chartDidOpen()
        XCTAssertEqual(engine.calls.filter { $0 == "selectChartLink(https://a/style.json)" }.count, 2,
                       "asked once with no chart, and again once there was one")
    }

    /// Adding one with no chart open holds the request the same way.
    func testAddingWithNoChartWaitsForOne() {
        let m = model()
        engine.hasChartHandle = false
        var asked = 0
        m.openChartForLink = { asked += 1 }
        m.add(" https://a/style.json ")
        XCTAssertEqual(asked, 1)
        XCTAssertTrue(m.busy)

        engine.hasChartHandle = true
        m.chartDidOpen()
        XCTAssertEqual(engine.calls.filter { $0 == "addChartLink(https://a/style.json)" }.count, 2)
    }

    /// The requests are replayed in the order they were made.
    func testHeldRequestsRunInOrder() {
        let m = model()
        engine.hasChartHandle = false
        m.openChartForLink = {}
        m.add("https://a/style.json")
        m.select("https://b/style.json")
        engine.hasChartHandle = true
        engine.calls = []
        m.chartDidOpen()
        XCTAssertEqual(engine.calls,
                       ["addChartLink(https://a/style.json)",
                        "selectChartLink(https://b/style.json)"])
    }

    /// A second open has no held request left to run.
    func testTheHeldRequestsRunOnce() {
        let m = model()
        engine.hasChartHandle = false
        m.openChartForLink = {}
        m.select("https://a/style.json")
        engine.hasChartHandle = true
        m.chartDidOpen()
        engine.calls = []
        m.chartDidOpen()
        XCTAssertTrue(engine.calls.isEmpty)
    }

    /// A call that goes through does not ask for a chart.
    func testAPickThatGoesThroughAsksForNothing() {
        let m = model()
        var asked = 0
        m.openChartForLink = { asked += 1 }
        m.select("https://a/style.json")
        XCTAssertEqual(asked, 0)
    }

    /// Picking Lookout's own chart calls the seam that closes a chart opened
    /// only for a link.
    func testPickingLookoutsOwnChartSaysSo() {
        let m = model()
        var told = 0
        m.lookoutChartPicked = { told += 1 }
        m.select(nil)
        XCTAssertEqual(told, 1)
        m.select("https://a/style.json")
        XCTAssertEqual(told, 1)
    }
}
