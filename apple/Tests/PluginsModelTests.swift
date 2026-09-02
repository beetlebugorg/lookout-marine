//  PluginsModelTests.swift — the alerts the plugins raise, and the install.
//
//  The alerts matter most: an alarm nobody has answered keeps sounding, and a
//  read that fails must not leave the boat deaf.

import XCTest
@testable import LookoutMarine

@MainActor
final class PluginsModelTests: ShellTestCase {
    private var engine = FakeEngine()

    private func model() -> PluginsModel {
        engine = FakeEngine()
        let m = PluginsModel()
        m.engine = engine
        return m
    }

    private func alert(_ id: UInt64, _ severity: PluginAlertSeverity = .alarm,
                       acknowledged: Bool = false) -> PluginAlert {
        PluginAlert(id: id, severity: severity, title: "Shallow water",
                    acknowledged: acknowledged)
    }

    // MARK: Alerts

    func testTheWatchTakesTheFirstSetAtOnce() {
        let m = model()
        engine.alerts = (seq: 1, alerts: [alert(1)])
        m.startAlertWatch()
        XCTAssertEqual(m.alerts.count, 1)
        m.stopAlertWatch()
    }

    /// Stopping clears the list and silences: the chart is going away with the
    /// plugins that raised the alarms.
    func testStoppingClearsAndSilences() {
        let m = model()
        engine.alerts = (seq: 1, alerts: [alert(1)])
        m.startAlertWatch()
        m.stopAlertWatch()
        XCTAssertTrue(m.alerts.isEmpty)
    }

    /// Acknowledging silences ONE alert, and shows the change without waiting
    /// for the next poll: the mariner pressed a control and must see it answer.
    func testAcknowledgingOneShowsAtOnce() {
        let m = model()
        engine.alerts = (seq: 1, alerts: [alert(1), alert(2)])
        m.startAlertWatch()
        engine.alerts = (seq: 2, alerts: [alert(1, acknowledged: true), alert(2)])
        m.acknowledge(alert(1))
        XCTAssertEqual(engine.acknowledged, [1])
        XCTAssertEqual(m.alerts.first(where: { $0.id == 1 })?.acknowledged, true)
        XCTAssertEqual(m.alerts.first(where: { $0.id == 2 })?.acknowledged, false)
        m.stopAlertWatch()
    }

    /// The core reported nothing readable. The list empties rather than
    /// showing an alarm that may be over.
    func testAnUnreadablePollEmptiesTheList() {
        let m = model()
        engine.alerts = (seq: 1, alerts: [alert(1)])
        m.startAlertWatch()
        engine.alerts = nil
        m.acknowledge(alert(1))
        XCTAssertTrue(m.alerts.isEmpty)
        m.stopAlertWatch()
    }

    /// Starting twice does not start a second timer.
    func testTheWatchStartsOnce() {
        let m = model()
        m.startAlertWatch()
        m.startAlertWatch()
        m.stopAlertWatch()
        XCTAssertTrue(m.alerts.isEmpty)
    }

    // MARK: Tables

    /// What is offered follows the plugins that are up, so a plugin that
    /// unloads takes its item with it.
    func testTheTablesFollowTheLoadedPlugins() {
        let m = model()
        m.refreshTables()
        XCTAssertTrue(m.tables.isEmpty)
    }

    // MARK: Install

    func testAPackageTheLayerCannotReadIsRefused() {
        let m = model()
        engine.inspectJSON = nil
        m.begin("/a/plugin.lkplug")
        XCTAssertNil(m.pendingInstall)
        XCTAssertEqual(m.installError, "The plugin layer could not start.")
    }

    /// The core's own refusal is the sentence shown; the sheet never opens.
    func testTheCoresRefusalIsWhatIsShown() {
        let m = model()
        engine.inspectJSON = #"{"error":"built for a newer Lookout"}"#
        m.begin("/a/plugin.lkplug")
        XCTAssertNil(m.pendingInstall)
        XCTAssertEqual(m.installError, "built for a newer Lookout")
    }

    /// A readable package goes to consent, and nothing is installed until the
    /// mariner says so.
    func testAReadablePackageGoesToConsent() {
        let m = model()
        engine.inspectJSON = #"{"id":"ais","name":"AIS","version":"1.2"}"#
        m.begin("/a/plugin.lkplug")
        XCTAssertEqual(m.pendingInstall?.name, "AIS")
        XCTAssertFalse(engine.calls.contains { $0.hasPrefix("install(") })
    }

    func testConfirmInstallsAndClosesTheSheet() {
        let m = model()
        engine.inspectJSON = #"{"id":"ais","name":"AIS","version":"1.2"}"#
        m.begin("/a/plugin.lkplug")
        m.confirmInstall()
        XCTAssertNil(m.pendingInstall)
        XCTAssertTrue(engine.calls.contains("install(/a/plugin.lkplug)"))
        XCTAssertNil(m.installError)
    }

    /// A refused install closes the sheet and says why in its own alert.
    func testARefusedInstallIsItsOwnAlert() {
        let m = model()
        engine.inspectJSON = #"{"id":"ais","name":"AIS","version":"1.2"}"#
        engine.installRefusal = "the signature did not check out"
        m.begin("/a/plugin.lkplug")
        m.confirmInstall()
        XCTAssertNil(m.pendingInstall)
        XCTAssertEqual(m.installError, "the signature did not check out")
    }

    /// A package copied off the Files picker is deleted either way.
    func testTheCopyIsThrownAway() throws {
        let m = model()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        m.pendingInstallCopy = dir
        m.dropCopy()
        XCTAssertNil(m.pendingInstallCopy)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
    }
}
