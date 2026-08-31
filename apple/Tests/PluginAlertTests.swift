//  PluginAlertTests.swift — the alerts the plugins raise.
//
//  The core hands alerts over as structs, so the fixtures here are the C
//  structs a read holds. The strings live only for the call that reads them
//  out, which is what a real read gives the shell.

import XCTest
@testable import LookoutMarine

final class PluginAlertTests: XCTestCase {

    private func alert(id: UInt64,
                       plugin: String = "",
                       severity: lookout_alert_severity = LOOKOUT_ALERT_ALARM,
                       title: String,
                       body: String = "",
                       raised: Int64 = 0,
                       acknowledged: Bool = false) -> PluginAlert {
        plugin.withCString { p in
            title.withCString { t in
                body.withCString { b in
                    PluginAlert(lookout_alert(id: id, plugin: p, title: t, body: b,
                                              severity: severity,
                                              acknowledged: acknowledged ? 1 : 0,
                                              raised: raised))
                }
            }
        }
    }

    func testOneAlarmFromTheCore() {
        let a = alert(id: 3, plugin: "org.beetlebug.ais", severity: LOOKOUT_ALERT_ALARM,
                      title: "AIS CPA alarm", body: "ANNE: CPA 124 m in 585 s",
                      raised: 1_754_700_000_000)
        XCTAssertEqual(a.id, 3)
        XCTAssertEqual(a.plugin, "org.beetlebug.ais")
        XCTAssertEqual(a.severity, .alarm)
        XCTAssertEqual(a.title, "AIS CPA alarm")
        XCTAssertEqual(a.body, "ANNE: CPA 124 m in 585 s")
        XCTAssertFalse(a.acknowledged)
        XCTAssertEqual(a.raised.timeIntervalSince1970, 1_754_700_000, accuracy: 0.001)
    }

    func testEverySeverityCrossesOver() {
        XCTAssertEqual(alert(id: 1, severity: LOOKOUT_ALERT_WARNING, title: "t").severity, .warning)
        XCTAssertEqual(alert(id: 1, severity: LOOKOUT_ALERT_NOTICE, title: "t").severity, .notice)
        XCTAssertEqual(alert(id: 1, severity: LOOKOUT_ALERT_ALARM, title: "t").severity, .alarm)
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
        let s = lookout_alert_severity(rawValue: 99)
        XCTAssertEqual(alert(id: 1, severity: s, title: "t").severity, .alarm)
    }

    func testAnAlertWithNoBodyIsStillAnAlert() {
        let a = alert(id: 1, title: "Shallow water")
        XCTAssertEqual(a.title, "Shallow water")
        XCTAssertEqual(a.body, "")
    }

    /// An acknowledged alert is still listed; the banner is what drops it.
    func testAnAcknowledgedAlertCrossesOverAcknowledged() {
        XCTAssertTrue(alert(id: 1, title: "t", acknowledged: true).acknowledged)
    }
}
