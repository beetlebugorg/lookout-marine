//  PluginAlertTests.swift — the alerts the plugins raise.

import XCTest
@testable import LookoutMarine

final class PluginAlertTests: XCTestCase {

    private func alerts(_ text: String) -> [PluginAlert] {
        guard let data = text.data(using: .utf8),
              let top = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = top["alerts"] as? [[String: Any]] else { return [] }
        return list.compactMap { PluginAlert($0) }
    }

    func testOneAlarmFromTheCore() {
        guard let a = alerts(Fixture.text("alerts")).first else { return XCTFail("no alert") }
        XCTAssertEqual(a.id, 3)
        XCTAssertEqual(a.plugin, "org.beetlebug.ais")
        XCTAssertEqual(a.severity, .alarm)
        XCTAssertEqual(a.title, "AIS CPA alarm")
        XCTAssertEqual(a.body, "ANNE: CPA 124 m in 585 s")
        XCTAssertFalse(a.acknowledged)
        XCTAssertEqual(a.raised.timeIntervalSince1970, 1_754_700_000, accuracy: 0.001)
    }

    func testAnEmptySetIsEmpty() {
        XCTAssertTrue(alerts(Fixture.text("alerts-empty")).isEmpty)
    }

    /// An alarm sounds; a warning and a notice do not.
    func testOnlyAnAlarmIsAudible() {
        XCTAssertTrue(PluginAlertSeverity.alarm.audible)
        XCTAssertFalse(PluginAlertSeverity.warning.audible)
        XCTAssertFalse(PluginAlertSeverity.notice.audible)
    }

    /// A severity this build does not know sounds. Silence is never the
    /// fallback for something the core thought worth raising.
    func testAnUnknownSeveritySounds() {
        XCTAssertEqual(alerts(#"{"alerts":[{"id":1,"title":"t","severity":"critical"}]}"#)
                        .first?.severity, .alarm)
        XCTAssertEqual(alerts(#"{"alerts":[{"id":1,"title":"t"}]}"#).first?.severity, .alarm)
    }

    func testAnAlertWithNoIdOrNoTitleIsDropped() {
        XCTAssertTrue(alerts(#"{"alerts":[{"title":"t"}]}"#).isEmpty)
        XCTAssertTrue(alerts(#"{"alerts":[{"id":1}]}"#).isEmpty)
    }

    func testAnAlertWithNoBodyIsStillAnAlert() {
        let a = alerts(#"{"alerts":[{"id":1,"title":"Shallow water"}]}"#).first
        XCTAssertEqual(a?.title, "Shallow water")
        XCTAssertEqual(a?.body, "")
    }
}
