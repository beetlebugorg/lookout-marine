//  ShellTestCase.swift — the base every test that persists anything uses.
//
//  The shell reads and writes one defaults domain through `Store.shared`. A
//  test puts a suite of its own there, so nothing it writes reaches the
//  developer's own settings and nothing they have set can change what a test
//  sees.

import XCTest
@testable import LookoutMarine

class ShellTestCase: XCTestCase {
    /// One suite per test, so two tests in the same run cannot see each other.
    private var suiteName = ""
    private var previous: Store?

    override func setUp() {
        super.setUp()
        suiteName = "org.beetlebug.lookout.tests." + UUID().uuidString
        previous = Store.shared
        guard let store = Store.suite(suiteName) else {
            XCTFail("UserDefaults refused the suite \(suiteName)")
            return
        }
        Store.shared = store
    }

    override func tearDown() {
        Store.shared.removeAll(suite: suiteName)
        if let previous { Store.shared = previous }
        previous = nil
        super.tearDown()
    }
}
