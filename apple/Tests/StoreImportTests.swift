//  StoreImportTests.swift — the one-time move out of UserDefaults.
//
//  A mariner who already had settings must not lose them to the change of
//  store. The copy runs once, on the first launch after it, and never again.

import XCTest
@testable import LookoutMarine

final class StoreImportTests: ShellTestCase {
    private var defaults: UserDefaults!
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "org.beetlebug.lookout.import." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testThePoseComesAcrossUnderTheCoresKeyNames() {
        defaults.set(["lon": -76.482, "lat": 38.9763, "zoom": 14.5, "rotationDeg": 37.0],
                     forKey: "chart.view")
        Store.shared.importDefaults(defaults)
        let v = ViewState.load()
        XCTAssertEqual(v?.lon, -76.482)
        XCTAssertEqual(v?.lat, 38.9763)
        XCTAssertEqual(v?.zoom, 14.5)
        // The key was rotationDeg and is rotation_deg, which is what every
        // other shell writes.
        XCTAssertEqual(v?.rotation_deg, 37)
    }

    func testTheMarinerSettingsComeAcrossFieldForField() {
        defaults.set(["scheme": 2, "safety_contour": 5.5, "text_names": false,
                      "date_view": "20260401"] as [String: Any], forKey: "mariner.v1")
        Store.shared.importDefaults(defaults)
        var m = tile57_mariner()
        lookout_mariner_defaults(&m)
        m.text_names = true
        MarinerSettings.applySavedOverlay(&m)
        XCTAssertEqual(m.scheme.rawValue, 2)
        XCTAssertEqual(m.safety_contour, 5.5)
        XCTAssertFalse(m.text_names)
        XCTAssertEqual(m.dateViewString, "20260401")
    }

    func testTheListsComeAcross() {
        defaults.set(["/charts/a", "/charts/b"], forKey: "lookout.chartsets")
        defaults.set(["/charts/b"], forKey: "lookout.chartsets.off")
        defaults.set(["/a/photo.mbtiles"], forKey: "lookout.rastercharts")
        defaults.set(["/a/photo.mbtiles"], forKey: "lookout.rastercharts.off")
        defaults.set(["survey"], forKey: "lookout.rastercharts.hidden")
        defaults.set(["/charts/old"], forKey: "lookout.recents")
        defaults.set(true, forKey: "lookout.chart.hidden")
        Store.shared.importDefaults(defaults)

        let s = Store.shared
        XCTAssertEqual(s.strings(Store.Group.chartsets, "paths"), ["/charts/a", "/charts/b"])
        XCTAssertEqual(s.strings(Store.Group.chartsets, "off"), ["/charts/b"])
        XCTAssertEqual(s.strings(Store.Group.raster, "paths"), ["/a/photo.mbtiles"])
        XCTAssertEqual(s.strings(Store.Group.raster, "off"), ["/a/photo.mbtiles"])
        XCTAssertEqual(s.strings(Store.Group.raster, "hidden"), ["survey"])
        XCTAssertEqual(s.strings(Store.Group.recents, "paths"), ["/charts/old"])
        XCTAssertEqual(s.bool(Store.Group.raster, "chart_hidden"), true)
    }

    /// The plugin settings were two dictionaries and are one config object per
    /// plugin, which is the object the plugin was handed.
    func testThePluginSettingsAreJoinedBackIntoOneObject() {
        defaults.set(["org.beetlebug.ais": ["cpa_limit": 926.0]], forKey: "plugins.v1")
        defaults.set(["org.beetlebug.nmea0183":
                        ["connections": "[{\"id\":\"a\",\"host\":\"h\"}]"]],
                     forKey: "plugins.lists.v1")
        Store.shared.importDefaults(defaults)

        let s = Store.shared
        XCTAssertEqual(s.keys(Store.Group.plugins),
                       ["org.beetlebug.ais", "org.beetlebug.nmea0183"])
        XCTAssertEqual(s.string(Store.Group.plugins, "org.beetlebug.ais"),
                       "{\"cpa_limit\":926.0}")
        XCTAssertEqual(s.string(Store.Group.plugins, "org.beetlebug.nmea0183"),
                       "{\"connections\":[{\"id\":\"a\",\"host\":\"h\"}]}")
    }

    /// A second launch must not undo an edit the mariner made after the first.
    func testTheCopyRunsOnce() {
        defaults.set(["/charts/a"], forKey: "lookout.chartsets")
        Store.shared.importDefaults(defaults)
        Store.shared.set(["/charts/b"], Store.Group.chartsets, "paths")
        Store.shared.importDefaults(defaults)
        XCTAssertEqual(Store.shared.strings(Store.Group.chartsets, "paths"), ["/charts/b"])
    }

    /// A first launch on a machine with nothing saved copies nothing and is
    /// still stamped, so it does not look again.
    func testNothingToCopyIsStillDone() {
        Store.shared.importDefaults(defaults)
        XCTAssertTrue(Store.shared.strings(Store.Group.chartsets, "paths").isEmpty)
        defaults.set(["/charts/a"], forKey: "lookout.chartsets")
        Store.shared.importDefaults(defaults)
        XCTAssertTrue(Store.shared.strings(Store.Group.chartsets, "paths").isEmpty)
    }
}
