//  PluginFixture.swift — the shipped plugin set, as values.
//
//  The core hands the registry over as structs, so a unit test has no core to
//  read one from. These are the same five plugins Fixtures/plugins.json was
//  captured from, built directly. What the CORE puts in a read is checked in
//  Zig, over the shipped manifests; what the SHELL does with one is checked
//  here.

import Foundation
@testable import LookoutMarine

enum PluginFixture {

    // MARK: Builders

    static func number(_ key: String, _ label: String, unit: String = "",
                       group: String = "", tab: String,
                       min: Double, max: Double, _ value: Double) -> PluginField {
        PluginField(key: key, label: label, desc: "", kind: .number, unit: unit,
                    group: group, tab: tab, min: min, max: max, defaultValue: value,
                    defaultText: "", optional: false, placeholder: "", value: value)
    }

    static func toggle(_ key: String, _ label: String, group: String = "", tab: String,
                       _ on: Bool) -> PluginField {
        PluginField(key: key, label: label, desc: "", kind: .toggle, unit: "",
                    group: group, tab: tab, min: 0, max: 0, defaultValue: on ? 1 : 0,
                    defaultText: "", optional: false, placeholder: "", value: on ? 1 : 0)
    }

    static func text(_ key: String, _ label: String, optional: Bool = false,
                     default def: String = "") -> PluginField {
        PluginField(key: key, label: label, desc: "", kind: .text, unit: "",
                    group: "", tab: "connections", min: 0, max: 0, defaultValue: 0,
                    defaultText: def, optional: optional, placeholder: "", value: 0)
    }

    static func list(_ pluginID: String, _ key: String, group: String,
                     tab: String = "connections", fields: [PluginField],
                     footer: String = "", empty: String = "", addLabel: String,
                     switchKey: String = "enabled", services: [String] = [],
                     maxRows: Int = 8) -> PluginListSchema {
        PluginListSchema(pluginID: pluginID, key: key, group: group, tab: tab,
                         itemFields: fields, footer: footer, empty: empty,
                         addLabel: addLabel, switchKey: switchKey,
                         discover: services.map { PluginDiscover(service: $0, set: [:]) },
                         maxRows: maxRows)
    }

    static func item(_ id: String, _ cells: [String: PluginValue]) -> PluginRow {
        PluginRow(id: id, cells: cells)
    }

    static func plugin(_ id: String, _ name: String, status: String = "",
                       live: Bool = true, origin: String = "bundled",
                       capabilities: [PluginCapability] = [],
                       fields: [PluginField] = [], lists: [PluginListSchema] = [],
                       rows: [String: [PluginRow]] = [:],
                       fileTypes: [String] = []) -> PluginInfo {
        PluginInfo(id: id, name: name, version: "", origin: origin, live: live,
                   status: PluginStatus(status), capabilities: capabilities,
                   fields: fields, lists: lists, rows: rows, fileTypes: fileTypes)
    }

    static func cap(_ name: String, _ sentence: String, hosts: [String] = [],
                    granted: Bool = true) -> PluginCapability {
        PluginCapability(cap: name, sentence: sentence, hosts: hosts, granted: granted)
    }

    // MARK: The shipped set

    static let ais = plugin(
        "org.beetlebug.ais", "AIS targets",
        status: #"{"state":"degraded","detail":"0 targets, no own position: no CPA"}"#,
        capabilities: [
            cap("vessel.read", "Read your instruments: position, heading, depth, wind."),
            cap("ais.read", "Read AIS traffic."),
            cap("overlay.draw", "Draw on the chart."),
            cap("alerts.raise", "Raise alarms."),
        ],
        fields: [
            number("cpa_limit", "Closest approach (CPA)", unit: "m",
                   group: "Collision alarm", tab: "alarms", min: 93, max: 9260, 926),
            number("tcpa_limit", "Time to closest approach (TCPA)", unit: "min",
                   group: "Collision alarm", tab: "alarms", min: 1, max: 60, 10),
            toggle("cpa_alarm", "Collision alarm", group: "Collision alarm",
                   tab: "alarms", true),
            number("vector_min", "Course vectors", unit: "min",
                   group: "AIS targets", tab: "vessels", min: 1, max: 24, 6),
            number("min_sog", "Hide targets under", unit: "kn",
                   group: "AIS targets", tab: "vessels", min: 0, max: 5, 0),
        ])

    static let laylines = plugin(
        "org.beetlebug.laylines", "Laylines",
        status: #"{"state":"degraded","detail":"no position, no wind"}"#,
        capabilities: [
            cap("vessel.read", "Read your instruments: position, heading, depth, wind."),
            cap("overlay.draw", "Draw on the chart."),
        ],
        fields: [
            number("upwind_deg", "Upwind angle", unit: "deg", group: "Laylines",
                   tab: "display", min: 25, max: 60, 45),
            number("downwind_deg", "Downwind angle", unit: "deg", group: "Laylines",
                   tab: "display", min: 120, max: 180, 170),
        ])

    static let nmeaConnections = list(
        "org.beetlebug.nmea0183", "connections", group: "Connections",
        fields: [
            text("name", "Name", optional: true),
            text("host", "Address"),
            number("port", "Port", tab: "connections", min: 1, max: 65535, 10110),
            toggle("enabled", "On", tab: "connections", true),
        ],
        addLabel: "Add Connection", services: ["_nmea-0183._tcp"])

    static let nmea0183 = plugin(
        "org.beetlebug.nmea0183", "NMEA 0183",
        status: #"{"state":"degraded","detail":"0 of 1 connected","items":"#
            + #"[{"id":"lookout-nmea","state":"unreachable","detail":"check the address"}]}"#,
        capabilities: [
            cap("vessel.publish", "Provide instrument values to the chart."),
            cap("ais.publish", "Provide AIS targets to the chart."),
            cap("bus.publish", "Share data with other plugins: nmea0183.",
                hosts: ["nmea0183"]),
            cap("net.tcp-client", "Connect to instruments on: your own network.",
                hosts: ["local"]),
        ],
        lists: [nmeaConnections],
        rows: ["connections": [item("lookout-nmea", [
            "name": .text(""), "host": .text("127.0.0.1"),
            "port": .number(10110), "enabled": .toggle(true),
        ])]])

    static let ownship = plugin(
        "org.beetlebug.ownship", "Own ship",
        status: #"{"state":"degraded","detail":"no position"}"#,
        capabilities: [
            cap("vessel.read", "Read your instruments: position, heading, depth, wind."),
            cap("overlay.draw", "Draw on the chart."),
        ],
        fields: [
            number("vector_min", "Course vector", unit: "min", group: "Own ship",
                   tab: "vessels", min: 1, max: 24, 6),
        ])

    static let signalk = plugin(
        "org.beetlebug.signalk", "Signal K",
        status: #"{"state":"degraded","detail":"no servers","items":[]}"#,
        capabilities: [
            cap("vessel.publish", "Provide instrument values to the chart."),
            cap("ais.publish", "Provide AIS targets to the chart."),
            cap("net.tcp-client", "Connect to instruments on: your own network.",
                hosts: ["local"]),
            cap("net.ws", "Stream data from: your own network.", hosts: ["local"]),
        ],
        lists: [list("org.beetlebug.signalk", "servers", group: "Signal K servers",
                     fields: [
                        text("name", "Name", optional: true),
                        text("host", "Address"),
                        number("port", "Port", tab: "connections", min: 1, max: 65535, 8375),
                        toggle("websocket", "WebSocket", tab: "connections", false),
                        toggle("enabled", "On", tab: "connections", true),
                     ],
                     addLabel: "Add Server", services: ["_signalk-ws._tcp"])],
        rows: ["servers": []])

    /// The five bundled plugins, in load order.
    static let shipped: [PluginInfo] = [ais, laylines, nmea0183, ownship, signalk]
}
