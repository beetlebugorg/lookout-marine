//  PluginStatusTests.swift — what a plugin says about itself, and about each
//  row of its lists.

import XCTest
@testable import LookoutMarine

final class PluginStatusTests: XCTestCase {
    private var plugins: [PluginInfo] = []

    override func setUp() {
        super.setUp()
        plugins = PluginSettings.registry(Fixture.text("plugins")) ?? []
    }

    private func plugin(_ id: String) -> PluginInfo? { plugins.first { $0.id == id } }

    private func info(status: String, live: Bool = true) -> PluginInfo {
        PluginSettings.registry("""
            {"plugins":[{"id":"p","live":\(live),"status":\(PluginSettings.jsonString(status))}]}
            """)!.first!
    }

    func testTheStateWordAndTheDetailAreJoined() {
        XCTAssertEqual(plugin("org.beetlebug.ais")?.statusLine,
                       "Degraded · 0 targets, no own position: no CPA")
        XCTAssertEqual(plugin("org.beetlebug.nmea0183")?.statusLine,
                       "Degraded · 0 of 1 connected")
    }

    func testEveryStateWord() {
        XCTAssertEqual(info(status: #"{"state":"running"}"#).statusLine, "Running")
        XCTAssertEqual(info(status: #"{"state":"starting"}"#).statusLine, "Starting")
        XCTAssertEqual(info(status: #"{"state":"degraded"}"#).statusLine, "Degraded")
        XCTAssertEqual(info(status: #"{"state":"disabled"}"#).statusLine, "Disabled")
        XCTAssertEqual(info(status: #"{"state":"stopped"}"#).statusLine, "Stopped")
    }

    /// A state this build has no word for passes through rather than vanishing.
    func testAnUnknownStateIsShownUnchanged() {
        XCTAssertEqual(info(status: #"{"state":"throttled","detail":"3 s"}"#).statusLine,
                       "throttled · 3 s")
    }

    /// A plugin that will not parse is still running, and says so.
    func testAStatusThatIsNotJsonShowsRunning() {
        XCTAssertEqual(info(status: "listening on 10110").statusLine, "Running")
        XCTAssertEqual(info(status: "").statusLine, "Running")
    }

    /// A dead plugin says so whatever its last words were.
    func testADeadPluginIsStoppedWhateverItLastSaid() {
        XCTAssertEqual(info(status: #"{"state":"running"}"#, live: false).statusLine, "Stopped")
    }

    // MARK: The rows of a list

    func testARowsLineJoinsItsStateAndDetail() {
        guard let item = plugin("org.beetlebug.nmea0183")?.statusItems["lookout-nmea"]
        else { return XCTFail("no status item") }
        XCTAssertEqual(item.state, "unreachable")
        XCTAssertEqual(item.line, "Unreachable · check the address")
    }

    func testEveryRowStateWord() {
        let line = { (state: String) -> String in
            PluginStatusItem(id: "r", state: state, detail: "").line
        }
        XCTAssertEqual(line("connected"), "Connected")
        XCTAssertEqual(line("paused"), "Paused")
        XCTAssertEqual(line("reconnecting"), "Reconnecting")
        XCTAssertEqual(line("unreachable"), "Unreachable")
        XCTAssertEqual(line("no_address"), "No address")
        XCTAssertEqual(line("wedged"), "wedged")
    }

    /// A status document with no items answers no rows rather than throwing.
    func testAStatusWithNoItemsHasNoRows() {
        XCTAssertTrue(info(status: #"{"state":"running"}"#).statusItems.isEmpty)
        XCTAssertTrue(info(status: "not json").statusItems.isEmpty)
    }

    func testAnItemWithNoIdIsDropped() {
        let items = info(status: #"{"items":[{"state":"connected"},{"id":"r"}]}"#).statusItems
        XCTAssertEqual(Array(items.keys), ["r"])
    }
}
