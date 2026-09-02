//  PluginRegistryTests.swift — the registry the settings window is built from.
//
//  What the CORE puts in a read is checked in Zig, over the shipped manifests.
//  What the SHELL does with one is checked here, over PluginFixture.

import XCTest
@testable import LookoutMarine

final class PluginRegistryTests: XCTestCase {
    private var plugins: [PluginInfo] = []

    override func setUp() {
        super.setUp()
        plugins = PluginFixture.shipped
    }

    private func plugin(_ id: String) -> PluginInfo? { plugins.first { $0.id == id } }


    // MARK: The shipped set

    func testTheFixtureHasTheFiveBundledPlugins() {
        XCTAssertEqual(plugins.map(\.id), [
            "org.beetlebug.ais",
            "org.beetlebug.laylines",
            "org.beetlebug.nmea0183",
            "org.beetlebug.ownship",
            "org.beetlebug.signalk",
        ])
        XCTAssertTrue(plugins.allSatisfy { $0.origin == "bundled" && $0.live })
    }

    // MARK: Fields

    func testANumberFieldHasItsRangeUnitAndSection() {
        guard let f = plugin("org.beetlebug.ais")?.fields.first(where: { $0.key == "cpa_limit" })
        else { return XCTFail("no cpa_limit") }
        XCTAssertEqual(f.kind, .number)
        XCTAssertEqual(f.label, "Closest approach (CPA)")
        XCTAssertEqual(f.unit, "m")
        XCTAssertEqual(f.min, 93)
        XCTAssertEqual(f.max, 9260)
        XCTAssertEqual(f.defaultValue, 926)
        XCTAssertEqual(f.value, 926)
        XCTAssertEqual(f.group, "Collision alarm")
        XCTAssertEqual(f.tab, "alarms")
        XCTAssertEqual(f.rangeText, "93–9260 m")
    }

    /// A toggle crosses as a JSON bool and lands as 0 or 1.
    func testAToggleIsZeroOrOne() {
        guard let f = plugin("org.beetlebug.ais")?.fields.first(where: { $0.key == "cpa_alarm" })
        else { return XCTFail("no cpa_alarm") }
        XCTAssertEqual(f.kind, .toggle)
        XCTAssertTrue(f.isOn)
        XCTAssertEqual(f.value, 1)
        XCTAssertEqual(f.defaultValue, 1)
    }


    /// The increment follows the range: metres of CPA move in tens, minutes and
    /// knots one at a time.
    func testTheStepSuitsTheRange() {
        let step = { (lo: Double, hi: Double) -> Double in
            PluginFixture.number("k", "K", tab: "advanced", min: lo, max: hi, lo).step
        }
        XCTAssertEqual(step(93, 9260), 10)
        XCTAssertEqual(step(1, 60), 1)
        XCTAssertEqual(step(0, 5), 0.5)
    }

    // MARK: Groups, sections and lists

    /// Groups arrive in declaration order, one per heading, and a plugin whose
    /// schema spans sections contributes one to each.
    @MainActor func testGroupsAreInDeclarationOrder() {
        let p = PluginSettings()
        p.plugins = plugins
        XCTAssertEqual(p.groups(tab: "alarms").map(\.title), ["Collision alarm"])
        XCTAssertEqual(p.groups(tab: "display").map(\.title), ["Laylines"])
        // Two plugins in one section, in load order, each with its own heading.
        XCTAssertEqual(p.groups(tab: "vessels").map(\.title), ["AIS targets", "Own ship"])
        XCTAssertEqual(p.groups(tab: "vessels").map(\.pluginID),
                       ["org.beetlebug.ais", "org.beetlebug.ownship"])
        XCTAssertEqual(p.groups(tab: "alarms").first?.fields.map(\.key),
                       ["cpa_limit", "tcpa_limit", "cpa_alarm"])
    }

    /// A section is shown while something is in it. The shipped set fills four.
    @MainActor func testThePopulatedSections() {
        let p = PluginSettings()
        p.plugins = plugins
        XCTAssertEqual(p.populatedTabs, ["alarms", "vessels", "display", "connections"])
        // A list fills a section as surely as a group of controls does.
        XCTAssertTrue(p.populatedTabs.contains("connections"))
        XCTAssertFalse(p.populatedTabs.contains("depths"))
    }

    func testAListParsesItsSchemaAndRows() {
        guard let list = plugin("org.beetlebug.nmea0183")?.lists.first
        else { return XCTFail("no connections list") }
        XCTAssertEqual(list.key, "connections")
        XCTAssertEqual(list.group, "Connections")
        XCTAssertEqual(list.tab, "connections")
        XCTAssertEqual(list.addLabel, "Add Connection")
        XCTAssertEqual(list.switchKey, "enabled")
        XCTAssertEqual(list.maxRows, 8)
        XCTAssertEqual(list.discover.map(\.service), ["_nmea-0183._tcp"])
        XCTAssertEqual(list.itemFields.map(\.key), ["name", "host", "port", "enabled"])
        XCTAssertTrue(list.itemFields.first { $0.key == "name" }?.optional == true)
        XCTAssertTrue(list.itemFields.first { $0.key == "host" }?.optional == false)

        let rows = plugin("org.beetlebug.nmea0183")?.rows["connections"] ?? []
        XCTAssertEqual(rows.map(\.id), ["lookout-nmea"])
        XCTAssertEqual(rows.first?.text("host"), "127.0.0.1")
        XCTAssertEqual(rows.first?.number("port"), 10110)
        XCTAssertTrue(rows.first?.isOn("enabled") == true)
    }

    /// The list's own word for one of its rows, taken from the Add label. The
    /// window used to say "connection" for every list, and a Signal K row that
    /// read "Remove Connection" contradicted the button above it.
    func testAListNamesItsOwnRows() {
        guard let nmea = plugin("org.beetlebug.nmea0183")?.lists.first
        else { return XCTFail("no list") }
        XCTAssertEqual(nmea.itemNoun, "Connection")
        XCTAssertEqual(nmea.newLabel, "New Connection")
        XCTAssertEqual(nmea.removeLabel, "Remove Connection")
    }

    /// A list that declared no Add label gets the generic wording rather than a
    /// noun invented for it.
    func testAListWithNoAddLabelUsesGenericWording() {
        let list = PluginFixture.list("p", "k", group: "", tab: "advanced",
                                      fields: [], addLabel: "")
        XCTAssertEqual(list.itemNoun, "")
        XCTAssertEqual(list.newLabel, "New item")
        XCTAssertEqual(list.removeLabel, "Remove")
    }


    // MARK: Capabilities

    func testCapabilitiesUseTheCoresWording() {
        guard let caps = plugin("org.beetlebug.nmea0183")?.capabilities
        else { return XCTFail("no capabilities") }
        XCTAssertEqual(caps.map(\.cap),
                       ["vessel.publish", "ais.publish", "bus.publish", "net.tcp-client"])
        XCTAssertEqual(caps.first?.sentence, "Provide instrument values to the chart.")
        XCTAssertTrue(caps.allSatisfy(\.granted))
        // The allowlist the mariner consented to. Shown nowhere on any shell;
        // kept so the decision to show it is one somebody makes.
        XCTAssertEqual(caps.first { $0.cap == "net.tcp-client" }?.hosts, ["local"])
    }

}
