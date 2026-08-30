//  PluginPollTests.swift — the poll and the browse only run while something is
//  watching.
//
//  Discovery's own rule: a browse nobody is watching is a radio left on. On
//  macOS the window controller stops it from windowWillClose as well as the
//  view's onDisappear, so stopping has to be safe to call twice.

import XCTest
@testable import LookoutMarine

@MainActor
final class PluginPollTests: XCTestCase {

    func testItIsNotPollingUntilItIsStarted() {
        XCTAssertFalse(PluginSettings().isPolling)
    }

    func testStartingAndStopping() {
        let p = PluginSettings()
        p.startPolling()
        XCTAssertTrue(p.isPolling)
        p.stopPolling()
        XCTAssertFalse(p.isPolling)
    }

    /// Two stops, because two things stop it.
    func testStoppingTwiceIsHarmless() {
        let p = PluginSettings()
        p.startPolling()
        p.stopPolling()
        p.stopPolling()
        XCTAssertFalse(p.isPolling)
    }

    /// Opening the window again starts it again.
    func testStartingAfterAStopPollsAgain() {
        let p = PluginSettings()
        p.startPolling()
        p.stopPolling()
        p.startPolling()
        XCTAssertTrue(p.isPolling)
        p.stopPolling()
    }

    /// A second start does not stack a second timer.
    func testStartingTwiceIsOnePoll() {
        let p = PluginSettings()
        p.startPolling()
        p.startPolling()
        p.stopPolling()
        XCTAssertFalse(p.isPolling)
    }
}
