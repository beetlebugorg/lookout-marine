//  SmokeTests.swift
//
//  Proves the runner before anything depends on it: that both test bundles
//  build, that they load their host app, and that `@testable import` reaches
//  the shell's own types on either platform.

import XCTest
@testable import LookoutMarine

final class SmokeTests: XCTestCase {
    /// One value through the formatter every shell shares. The full contract is
    /// checked in CoordFormatTests; this only shows the bundle is wired.
    func testTheShellIsReachableFromATest() {
        XCTAssertEqual(CoordFormat.dm(38.9763, isLat: true), "38°58.578'N")
    }
}
