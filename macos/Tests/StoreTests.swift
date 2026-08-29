//  StoreTests.swift — the seam every persistence test stands on.

import XCTest
@testable import LookoutMarine

final class StoreTests: ShellTestCase {
    func testASuiteIsEmptyAtTheStartOfATest() {
        XCTAssertNil(Store.shared.strings("lookout.chartsets"))
        XCTAssertNil(Store.shared.dictionary("mariner.v1"))
        XCTAssertFalse(Store.shared.bool("lookout.chart.hidden"))
    }

    func testWhatIsWrittenComesBack() {
        Store.shared.set(["/a", "/b"], "lookout.chartsets")
        Store.shared.set(true, "lookout.chart.hidden")
        Store.shared.set(["scheme": 2], "mariner.v1")
        XCTAssertEqual(Store.shared.strings("lookout.chartsets"), ["/a", "/b"])
        XCTAssertTrue(Store.shared.bool("lookout.chart.hidden"))
        XCTAssertEqual(Store.shared.dictionary("mariner.v1")?["scheme"] as? Int, 2)
    }

    func testRemoveTakesOneKeyAway() {
        Store.shared.set(["/a"], "lookout.chartsets")
        Store.shared.remove("lookout.chartsets")
        XCTAssertNil(Store.shared.strings("lookout.chartsets"))
    }

    /// The suite from the previous test must not be the suite in this one.
    func testTestsDoNotSeeEachOther() {
        XCTAssertNil(Store.shared.strings("lookout.chartsets"))
    }
}
