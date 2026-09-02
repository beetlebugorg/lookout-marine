//  StoreTests.swift — the seam every persistence test stands on.
//
//  Store is lookout_store, so these also check the C ABI: a value written here
//  goes through the core's ini and comes back through it.

import XCTest
@testable import LookoutMarine

final class StoreTests: ShellTestCase {
    private let group = Store.Group.chartsets

    func testAStoreIsEmptyAtTheStartOfATest() {
        XCTAssertTrue(Store.shared.strings(group, "paths").isEmpty)
        XCTAssertNil(Store.shared.number(Store.Group.mariner, "scheme"))
        XCTAssertNil(Store.shared.bool(Store.Group.raster, "chart_hidden"))
        XCTAssertNil(Store.shared.string(Store.Group.chartlinks, "active"))
        XCTAssertFalse(Store.shared.has(group, "paths"))
    }

    func testWhatIsWrittenComesBack() {
        Store.shared.set(["/a", "/b"], group, "paths")
        Store.shared.set(true, Store.Group.raster, "chart_hidden")
        Store.shared.set(2, Store.Group.mariner, "scheme")
        Store.shared.set("https://h/style.json", Store.Group.chartlinks, "active")
        XCTAssertEqual(Store.shared.strings(group, "paths"), ["/a", "/b"])
        XCTAssertEqual(Store.shared.bool(Store.Group.raster, "chart_hidden"), true)
        XCTAssertEqual(Store.shared.number(Store.Group.mariner, "scheme"), 2)
        XCTAssertEqual(Store.shared.string(Store.Group.chartlinks, "active"),
                       "https://h/style.json")
    }

    /// The fallback applies to an unset key. A set one reads its value.
    func testAFallbackIsForAnUnsetKey() {
        XCTAssertNil(Store.shared.bool(Store.Group.raster, "chart_hidden", true))
        Store.shared.set(false, Store.Group.raster, "chart_hidden")
        XCTAssertEqual(Store.shared.bool(Store.Group.raster, "chart_hidden", true), false)
    }

    func testRemoveTakesOneKeyAway() {
        Store.shared.set(["/a"], group, "paths")
        Store.shared.set(["/b"], group, "off")
        Store.shared.remove(group, "paths")
        XCTAssertTrue(Store.shared.strings(group, "paths").isEmpty)
        XCTAssertEqual(Store.shared.strings(group, "off"), ["/b"])
    }

    /// An empty list clears the key, so a read of it comes back empty.
    func testAnEmptyListClearsTheKey() {
        Store.shared.set(["/a"], group, "paths")
        Store.shared.set([], group, "paths")
        XCTAssertFalse(Store.shared.has(group, "paths"))
    }

    /// A path holding the list separator stays one entry.
    func testASeparatorInAValueSurvives() {
        Store.shared.set(["/a;b/charts", "/c/charts"], group, "paths")
        XCTAssertEqual(Store.shared.strings(group, "paths"), ["/a;b/charts", "/c/charts"])
    }

    /// This is how the plugin ids a config was saved for are read back.
    func testTheKeysOfAGroupComeBackInOrder() {
        Store.shared.set("{}", Store.Group.plugins, "org.beetlebug.ais")
        Store.shared.set("{}", Store.Group.plugins, "org.beetlebug.ownship")
        XCTAssertEqual(Store.shared.keys(Store.Group.plugins),
                       ["org.beetlebug.ais", "org.beetlebug.ownship"])
    }

    /// A store closed and opened on the same directory says the same thing.
    func testWhatIsWrittenSurvivesAClose() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-store-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let s = Store(directory: dir.path)
            s.set(["/a", "/b"], group, "paths")
            s.set(-76.482, Store.Group.view, "lon")
        }
        let s = Store(directory: dir.path)
        XCTAssertEqual(s.strings(group, "paths"), ["/a", "/b"])
        XCTAssertEqual(try XCTUnwrap(s.number(Store.Group.view, "lon")), -76.482, accuracy: 1e-12)
    }

    /// The directory from the previous test must not be the one in this test.
    func testTestsDoNotSeeEachOther() {
        XCTAssertTrue(Store.shared.strings(group, "paths").isEmpty)
    }
}
