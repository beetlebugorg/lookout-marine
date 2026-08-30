//  PluginPackageTests.swift — what the consent sheet is built from.
//
//  lookout_plugin_inspect reads a .lkplug and says what it is and what it asks
//  for, without touching the disk. Nothing installs before the mariner has seen
//  these sentences.

import XCTest
@testable import LookoutMarine

final class PluginPackageTests: XCTestCase {

    func testAFirstInstall() {
        let p = PluginPackage.parse("""
            {"id":"org.example.weather","name":"Weather","version":"1.2.0",
             "sentences":["Read AIS traffic.","Connect to instruments on: your own network."]}
            """, path: "/tmp/weather.lkplug")
        XCTAssertEqual(p.pkgID, "org.example.weather")
        XCTAssertEqual(p.name, "Weather")
        XCTAssertEqual(p.version, "1.2.0")
        XCTAssertEqual(p.sentences.count, 2)
        XCTAssertEqual(p.id, "/tmp/weather.lkplug")
        XCTAssertFalse(p.isReinstall)
        XCTAssertFalse(p.downgrade)
        XCTAssertNil(p.error)
    }

    /// On a reinstall the sheet names the delta, downgrades included.
    func testAReinstallWithADelta() {
        let p = PluginPackage.parse("""
            {"id":"p","name":"P","version":"1.0.0",
             "sentences":["Read AIS traffic."],
             "installed":{"version":"2.0.0","origin":"installed","downgrade":true,
                          "adds":["Read your position."],
                          "drops":["Connect to instruments on: your own network."]}}
            """, path: "/tmp/p.lkplug")
        XCTAssertTrue(p.isReinstall)
        XCTAssertEqual(p.installedVersion, "2.0.0")
        XCTAssertEqual(p.installedOrigin, "installed")
        XCTAssertTrue(p.downgrade)
        XCTAssertEqual(p.adds, ["Read your position."])
        XCTAssertEqual(p.drops, ["Connect to instruments on: your own network."])
    }

    /// A refused package is one sentence, not a sheet.
    func testARefusal() {
        let p = PluginPackage.parse(#"{"error":"That file is not a plugin package."}"#,
                                    path: "/tmp/x.lkplug")
        XCTAssertEqual(p.error, "That file is not a plugin package.")
    }

    /// A plugin that asks for nothing still installs, and the sheet says so.
    func testAPackageThatAsksForNothing() {
        let p = PluginPackage.parse(#"{"id":"p","name":"P"}"#, path: "/tmp/p.lkplug")
        XCTAssertTrue(p.sentences.isEmpty)
        XCTAssertEqual(p.version, "")
        XCTAssertNil(p.error)
    }

    func testWhatIsNotJsonIsAnEmptyPackage() {
        let p = PluginPackage.parse("<not json>", path: "/tmp/p.lkplug")
        XCTAssertEqual(p.pkgID, "")
        XCTAssertEqual(p.name, "")
        XCTAssertNil(p.error)
    }
}
