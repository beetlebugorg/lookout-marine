//  ViewStateTests.swift — whether there is a camera pose to reopen on.
//
//  The pose itself is the engine's: it restores, writes and re-writes it out of
//  the store the shell hands over, and src/root.zig asserts that. What is left
//  here is the one question the shell asks, because the answer decides whether
//  it asks the core for an opening view instead.

import XCTest
@testable import LookoutMarine

final class ViewStateTests: ShellTestCase {

    func testNothingSavedIsNoPose() {
        XCTAssertFalse(ViewState.hasSaved())
    }

    /// Half a pose is no pose: the opening view then comes from the core, which
    /// is the same policy every host gets, and the same rule the engine reads
    /// the store by.
    func testHalfAPoseIsNoPose() {
        let s = Store.shared
        s.set(-76.0, Store.Group.view, "lon")
        s.set(38.0, Store.Group.view, "lat")
        XCTAssertFalse(ViewState.hasSaved())
        s.set(12.0, Store.Group.view, "zoom")
        XCTAssertTrue(ViewState.hasSaved())
    }

    /// A pose saved before rotation existed is still a pose. The engine opens
    /// it north up.
    func testAPoseWithNoRotationIsStillAPose() {
        let s = Store.shared
        s.set(-76.0, Store.Group.view, "lon")
        s.set(38.0, Store.Group.view, "lat")
        s.set(12.0, Store.Group.view, "zoom")
        XCTAssertTrue(ViewState.hasSaved())
        XCTAssertNil(s.number(Store.Group.view, "rotation_deg"))
    }
}
