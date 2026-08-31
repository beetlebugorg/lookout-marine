//  PluginConfigTests.swift — what the shell sends back to a plugin.

import XCTest
@testable import LookoutMarine

final class PluginConfigTests: XCTestCase {

    /// A toggle crosses as a JSON bool, which is the only shape the core takes.
    func testAToggleCrossesAsABool() {
        let fields = [
            PluginFixture.toggle("cpa_alarm", "Collision alarm", tab: "alarms", true),
            PluginFixture.number("cpa_limit", "CPA", tab: "alarms", min: 0, max: 9260, 926),
        ]
        XCTAssertEqual(PluginSettings.configJSON(fields),
                       #"{"cpa_alarm":true,"cpa_limit":926}"#)
    }

    /// A number has no trailing ".0". The core accepts either; a settings
    /// line in a log reads better without it.
    func testANumberIsTrimmed() {
        XCTAssertEqual(PluginSettings.trimmed(926), "926")
        XCTAssertEqual(PluginSettings.trimmed(926.0), "926")
        XCTAssertEqual(PluginSettings.trimmed(6.5), "6.5")
        XCTAssertEqual(PluginSettings.trimmed(-0.25), "-0.25")
        XCTAssertEqual(PluginSettings.trimmed(0), "0")
    }

    /// A host name is whatever was typed.
    func testAStringIsEscaped() {
        XCTAssertEqual(PluginSettings.jsonString("gateway"), "\"gateway\"")
        XCTAssertEqual(PluginSettings.jsonString("a\"b"), "\"a\\\"b\"")
        XCTAssertEqual(PluginSettings.jsonString("a\\b"), "\"a\\\\b\"")
        XCTAssertEqual(PluginSettings.jsonString("a\nb"), "\"a\\nb\"")
        XCTAssertEqual(PluginSettings.jsonString("a\u{01}b"), "\"a\\u0001b\"")
        XCTAssertEqual(PluginSettings.jsonString("naïve"), "\"naïve\"")
    }

    /// A list crosses as its WHOLE array of rows, every column the schema
    /// declares, and the row id the shell assigned.
    func testAListCrossesWholeWithItsRowIds() {
        let list = PluginFixture.list("p", "connections", group: "Connections", fields: [
            PluginFixture.text("host", "Address"),
            PluginFixture.number("port", "Port", tab: "connections", min: 1, max: 65535, 10110),
            PluginFixture.toggle("enabled", "On", tab: "connections", true),
        ], addLabel: "Add Connection")
        let p = PluginFixture.plugin("p", "P", lists: [list], rows: ["connections": [
            PluginFixture.item("r1", ["host": .text("gw.local"), "port": .number(10110),
                                      "enabled": .toggle(true)]),
            PluginFixture.item("r2", ["host": .text(""), "port": .number(2000),
                                      "enabled": .toggle(false)]),
        ]])
        XCTAssertEqual(
            PluginSettings.configJSON(p.fields, p.lists, p.rows),
            #"{"connections":[{"id":"r1","host":"gw.local","port":10110,"enabled":true},"#
            + #"{"id":"r2","host":"","port":2000,"enabled":false}]}"#)
    }

    /// A cell the row does not hold is written from the schema default, so the
    /// plugin never gets a short row.
    func testAMissingCellIsWrittenFromTheDefault() {
        let list = PluginFixture.list("p", "k", group: "K", fields: [
            PluginFixture.number("port", "Port", tab: "connections", min: 0, max: 65535, 10110),
        ], addLabel: "Add")
        let p = PluginFixture.plugin("p", "P", lists: [list],
                                     rows: ["k": [PluginFixture.item("r", [:])]])
        XCTAssertEqual(PluginSettings.rowsJSON(p.lists[0], p.rows["k"] ?? []),
                       #"[{"id":"r","port":10110}]"#)
    }

    func testAnEmptyListIsAnEmptyArray() {
        let p = PluginFixture.plugin("p", "P", lists: [
            PluginFixture.list("p", "k", group: "K", fields: [], addLabel: "Add"),
        ])
        XCTAssertEqual(PluginSettings.configJSON(p.fields, p.lists, p.rows), #"{"k":[]}"#)
    }
}
