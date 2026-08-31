//  ShellTestCase.swift — the base every test that persists anything uses.
//
//  The shell reads and writes one settings file through `Store.shared`. A test
//  puts a store in a temp directory of its own there, so nothing it writes
//  reaches the mariner's own settings and nothing they have set can change what
//  a test sees.
//
//  A directory the test names also ends the redirected-HOME problem the old
//  defaults store had: a file has no login session behind it.

import XCTest
@testable import LookoutMarine

class ShellTestCase: XCTestCase {
    /// One directory per test, so two tests in the same run cannot see each
    /// other.
    private var dir: URL?
    private var previous: Store?

    override func setUp() {
        super.setUp()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lookout-tests-" + UUID().uuidString, isDirectory: true)
        dir = url
        previous = Store.shared
        Store.shared = Store(directory: url.path)
    }

    override func tearDown() {
        if let previous { Store.shared = previous }
        previous = nil
        if let dir { try? FileManager.default.removeItem(at: dir) }
        dir = nil
        super.tearDown()
    }
}
